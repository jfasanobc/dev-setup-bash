#!/usr/bin/env zsh
set -euo pipefail
if [ -z "${ZSH_VERSION:-}" ]; then exec zsh "$0" "$@"; fi

###############
# Flags & env #
###############
DO_INSTALL=false
VERBOSE=false
INCLUDE_OPTIONAL=false
DEBUG_UI=false

# Parse flags (supports -i -o -v in any combination: -io, -ov, -iov, etc.)
for arg in "$@"; do
  case "$arg" in
    --install)            DO_INSTALL=true ;;
    --verbose)            VERBOSE=true ;;
    --optional-software)  INCLUDE_OPTIONAL=true ;;
    --debug-ui)           DEBUG_UI=true ;;
    --help|-h)
      cat <<USAGE
Usage: $0 [--install|-i] [--verbose|-v] [--optional-software|-o] [--debug-ui]
USAGE
      exit 0 ;;
    --*) echo "Unknown flag: $arg" >&2; exit 2 ;;
    -*)
      typeset ch
      for ch in ${(s::)arg#-}; do
        case "$ch" in
          i) DO_INSTALL=true ;;
          v) VERBOSE=true ;;
          o) INCLUDE_OPTIONAL=true ;;
          *) echo "Unknown flag: -$ch" >&2; exit 2 ;;
        esac
      done
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

####################
# Pretty printing  #
####################
autoload -Uz colors; colors
BOLD=$'%B'; DIM=$'%F{245}'; RED=$'%F{196}'; GREEN=$'%F{70}'; YELLOW=$'%F{178}'; BLUE=$'%F{39}'; RESET=$'%f%b'
note() { print -P "${BLUE}${RESET} $*"; }
ok()   { print -P "${GREEN}✔${RESET} $*"; }
warn() { print -P "${YELLOW}▲${RESET} $*"; }
fail() { print -P "${RED}✘${RESET} $*"; }
title(){ print -P "\n${BOLD}$*${RESET}"; }
section(){ print -P "\n${BOLD}=== $* ===${RESET}"; }

########################
# Verbose runner       #
########################
vrun() {
  if $VERBOSE; then
    print -P "${DIM}$ ${(j: :)@}${RESET}"
    eval "$@"
  else
    eval "$@" 1>/dev/null 2>/dev/null
  fi
}

#########################
# Terminal helpers      #
#########################
zmodload zsh/terminfo 2>/dev/null || true
: ${terminfo[smcup]:=$'\e[?1049h'}
: ${terminfo[rmcup]:=$'\e[?1049l'}
enter_alt_screen() { print -n -- "${terminfo[smcup]}"; }
leave_alt_screen() { print -n -- "${terminfo[rmcup]}"; }
hide_cursor() { tput civis 2>/dev/null || print -n $'\e[?25l'; }
show_cursor() { tput cnorm 2>/dev/null || print -n $'\e[?25h'; }

# Read a single key; normalize to: up | down | space | enter | other
get_keypress() {
  typeset -g REPLY
  local k rest seq
  IFS= read -rsk1 k || return 1

  [[ $k == $'\n' || $k == $'\r' ]] && { REPLY="enter"; return 0; }
  [[ $k == " " ]]                    && { REPLY="space"; return 0; }

  if [[ $k == $'\x1b' ]]; then
    local b; local -i i=0
    while IFS= read -rsk1 -t 0.01 b; do
      rest+="$b"; (( ++i > 4 )) && break
    done
    seq="$k$rest"
    case "$seq" in
      $'\e[A'|$'\eOA'|${terminfo[kcuu1]:-}) REPLY="up";   return 0 ;;
      $'\e[B'|$'\eOB'|${terminfo[kcud1]:-}) REPLY="down"; return 0 ;;
    esac
    REPLY=""; return 0
  fi

  REPLY="$k"; return 0
}

#########################
# Menu (single/multi)   #
#########################
fallback_single_select() {
  local -a items; items=("$@"); local i
  for i in {1..${#items[@]}}; do print "$i) ${items[$i]}"; done
  print -n "Choose [1-${#items[@]}]: "; read -r i
  [[ $i == <-> && $i -ge 1 && $i -le ${#items[@]} ]] || { echo "Invalid choice"; return 1; }
  REPLY=$i
}
fallback_multi_select() {
  local -a items; items=("$@"); local i sel
  for i in {1..${#items[@]}}; do print "$i) ${items[$i]}"; done
  print -n "Enter numbers to select (space/comma separated), or empty for none: "
  IFS=', ' read -r sel
  typeset -g -a SELECTED_INDEXES=()
  for i in ${(s: :)sel}; do [[ $i == <-> && $i -ge 1 && $i -le ${#items[@]} ]] && SELECTED_INDEXES+=("$i"); done
}
menu_single_select() {
  local arr="$1"; local -a items; items=("${(@P)arr}")
  [[ -t 0 && -t 1 ]] || { fallback_single_select "${items[@]}" || return 1; return 0; }
  enter_alt_screen; hide_cursor
  local index=1 i
  while true; do
    tput clear; tput cup 0 0
    print -P "${BOLD}Choose what to do:${RESET}\n"
    for (( i=1; i<=${#items[@]}; i++ )); do
      if [[ $i -eq $index ]]; then print -P "  ${BOLD}> ${items[$i]}${RESET}"; else print -P "    ${items[$i]}"; fi
    done
    get_keypress || { leave_alt_screen; show_cursor; fallback_single_select "${items[@]}" || return 1; return 0; }
    case "$REPLY" in
      up)   (( index = index > 1 ? index-1 : ${#items[@]} )) ;;
      down) (( index = index < ${#items[@]} ? index+1 : 1 )) ;;
      enter) leave_alt_screen; show_cursor; REPLY=$index; return 0 ;;
    esac
  done
}
menu_multi_select() {
  typeset -g -a SELECTED_INDEXES=()
  local arr="$1"; local -a items; items=("${(@P)arr}")
  [[ -t 0 && -t 1 ]] || { fallback_multi_select "${items[@]}"; return 0; }
  enter_alt_screen; hide_cursor
  local index=1 i checked; local -A selected_map
  while true; do
    tput clear; tput cup 0 0
    print -P "${BOLD}Pick tasks to run (space to toggle, move to 'Proceed' and press Enter)${RESET}\n"
    for (( i=1; i<=${#items[@]}; i++ )); do
      [[ -n ${selected_map[$i]-} ]] && checked="${GREEN}●${RESET}" || checked="○"
      if [[ $i -eq $index ]]; then print -P "  ${BOLD}> $checked ${items[$i]}${RESET}"; else print -P "    $checked ${items[$i]}"; fi
    done
    local proceed_row=$(( ${#items[@]} + 1 ))
    if [[ $index -eq $proceed_row ]]; then print -P "  ${BOLD}> Proceed${RESET}"; else print -P "    Proceed"; fi
    get_keypress || { leave_alt_screen; show_cursor; fallback_multi_select "${items[@]}"; return 0; }
    case "$REPLY" in
      up)   (( index = index > 1 ? index-1 : proceed_row )) ;;
      down) (( index = index < proceed_row ? index+1 : 1 )) ;;
      space) (( index <= ${#items[@]} )) && { [[ -n ${selected_map[$index]-} ]] && unset "selected_map[$index]" || selected_map[$index]=1; } ;;
      enter) if (( index == proceed_row )); then
               leave_alt_screen; show_cursor
               SELECTED_INDEXES=("${(@k)selected_map}")
               IFS=$'\n' SELECTED_INDEXES=($(sort -n <<< "${(F)SELECTED_INDEXES}"))
               return 0
             fi ;;
    esac
  done
}

#################
# OS detection  #
#################
ARCH="$(uname -m)"; APPLE_SILICON=false; [[ "$ARCH" == "arm64" ]] && APPLE_SILICON=true
HOMEDIR="$HOME"; USER_SHORT="$(basename "$HOMEDIR")"; COMPANY_DOMAIN="bigcommerce.com"

typeset -a TODO_ITEMS_TASKS=() TODO_ITEMS_MSGS=() RUN_LOG=()
queue_issue(){ TODO_ITEMS_TASKS+=("$1"); TODO_ITEMS_MSGS+=("$2"); warn "$2"; RUN_LOG+=("! $2"); }

############################
# Task registry & helpers  #
############################
typeset -A TASK_FN TASK_LABEL
register_task(){ TASK_LABEL["$1"]="$2"; TASK_FN["$1"]="$3"; }

append_unique_line_to_file(){
  local file="$1" line="$2"; touch "$file"; chmod 600 "$file"
  grep -qxF "$line" "$file" || print -- "$line" >> "$file"
}
ensure_ssh_agent_zshrc_lines() {
  local zrc="$HOME/.zshrc"
  append_unique_line_to_file "$zrc" ''
  append_unique_line_to_file "$zrc" '# --- ssh-agent autostart ---'
  append_unique_line_to_file "$zrc" 'if ! pgrep -x ssh-agent >/dev/null; then'
  append_unique_line_to_file "$zrc" '  eval "$(ssh-agent -s)" >/dev/null'
  append_unique_line_to_file "$zrc" 'fi'
  append_unique_line_to_file "$zrc" '# Load common keys quietly if present'
  append_unique_line_to_file "$zrc" '[ -f ~/.ssh/id_ed25519 ]     && ssh-add -q ~/.ssh/id_ed25519     2>/dev/null'
  append_unique_line_to_file "$zrc" '[ -f ~/.ssh/gh_ed25519 ]     && ssh-add -q ~/.ssh/gh_ed25519     2>/dev/null'
  append_unique_line_to_file "$zrc" '[ -f ~/.ssh/gcloud_ed25519 ] && ssh-add -q ~/.ssh/gcloud_ed25519 2>/dev/null'
}

############################
# 1) Homebrew
############################
task_brew() {
  section "Homebrew"
  local expected_prefix actual_prefix
  expected_prefix=$($APPLE_SILICON && echo /opt/homebrew || echo /usr/local)
  if vrun "command -v brew"; then
    actual_prefix="$(brew --prefix 2>/dev/null || true)"
    print "brew --prefix -> ${actual_prefix:-<none>}"
    if [[ "$actual_prefix" == "$expected_prefix" ]]; then
      ok "Homebrew installed at ${actual_prefix} (correct for ${ARCH})."
      RUN_LOG+=("✓ Homebrew OK (${actual_prefix})")
    else
      queue_issue "brew_fix" "Homebrew at ${actual_prefix}, expected ${expected_prefix}."
      $DO_INSTALL && note "Recommend reinstalling at ${expected_prefix}."
    fi
  else
    queue_issue "brew_install" "Homebrew not installed."
    if $DO_INSTALL; then
      note "Installing Homebrew…"
      vrun '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
      if vrun "command -v brew"; then ok "Homebrew installed."; RUN_LOG+=("✓ Homebrew installed")
      else fail "Homebrew install did not complete."; fi
    fi
  fi
}

############################################
# 2) Optional software (if chosen) first
############################################
install_brew_pkg_if_needed() {
  local pkg="$1"
  if vrun "brew list --cask $pkg" || vrun "brew list $pkg"; then
    ok "$pkg already installed."; RUN_LOG+=("• $pkg already installed"); return 0
  fi
  if $DO_INSTALL; then
    note "Installing $pkg…"
    if vrun "brew info --cask $pkg"; then vrun "brew install --cask $pkg"; else vrun "brew install $pkg"; fi
    ok "$pkg installed."; RUN_LOG+=("✓ Installed $pkg")
  else
    queue_issue "install_$pkg" "$pkg not installed."
  fi
}
task_optional_software() {
  section "Optional Software"
  if vrun "command -v gh"; then ok "GitHub CLI present."; RUN_LOG+=("• gh present")
  else if $DO_INSTALL; then install_brew_pkg_if_needed "gh"; else queue_issue "install_gh" "GitHub CLI not installed."; fi; fi
  if [[ -d "/Applications/iTerm.app" ]] || vrun "brew list --cask iterm2"; then ok "iTerm2 present."; RUN_LOG+=("• iTerm2 present")
  else if $DO_INSTALL; then install_brew_pkg_if_needed "iterm2"; else queue_issue "install_iterm2" "iTerm2 not installed."; fi; fi
  if [[ -d "/Applications/DBeaver.app" ]] || vrun "brew list --cask dbeaver-community"; then ok "DBeaver Community present."; RUN_LOG+=("• DBeaver Community present")
  else if $DO_INSTALL; then install_brew_pkg_if_needed "dbeaver-community"; else queue_issue "install_dbeaver" "DBeaver Community not installed."; fi; fi
}

########################
# 3) SSH Configuration #
########################
generate_ssh_key(){
  local file="$HOME/.ssh/$1" comment="${2:-$USER_SHORT@$COMPANY_DOMAIN}"
  if [[ -f "$file" ]]; then warn "Key $file exists; skipping."; RUN_LOG+=("• $1 exists")
  else note "Generating $file…"; vrun "ssh-keygen -t ed25519 -C \"$comment\" -f \"$file\" -N ''"; ok "Generated $file"; RUN_LOG+=("✓ Generated $1"); fi
}
task_ssh() {
  section "SSH Configuration"
  vrun "mkdir -p \"$HOME/.ssh\""
  vrun "chmod 700 \"$HOME/.ssh\""

  local keys; keys=("$HOME"/.ssh/*.pub(N))
  if (( ${#keys[@]} )); then ok "Found SSH public keys:"; for k in "${keys[@]}"; do print " - $k"; done; RUN_LOG+=("• SSH keys present")
  else warn "No SSH public keys found"; queue_issue "ssh_no_keys" "No SSH keys found."; fi

  if vrun "pgrep -u \"$USER\" ssh-agent"; then ok "ssh-agent is running."; RUN_LOG+=("• ssh-agent running")
  else warn "ssh-agent is not running."; queue_issue "ssh_agent" "ssh-agent not running."
       if $DO_INSTALL; then vrun 'eval "$(ssh-agent -s)"'; ok "Started ssh-agent."; RUN_LOG+=("✓ started ssh-agent"); fi
  fi

  if [[ -f "$HOME/.ssh/config" ]]; then ok "~/.ssh/config exists."
  else
    warn "~/.ssh/config missing."
    if $DO_INSTALL; then vrun ": > \"$HOME/.ssh/config\""; vrun "chmod 600 \"$HOME/.ssh/config\""; ok "Created ~/.ssh/config"; RUN_LOG+=("✓ created ssh config")
    else queue_issue "ssh_config" "~/.ssh/config missing."; fi
  fi

  if vrun "ssh-add -l"; then ok "Keys present in ssh-agent."
  else warn "No keys in ssh-agent."; queue_issue "ssh_agent_add" "No keys in ssh-agent."; fi

  if $DO_INSTALL; then
    print -n "Generate SSH keys now? (y/N): "; read -r ans
    if [[ "$ans" == [yY]* ]]; then
      local choices=("Single common key (id_ed25519)" "Separate: gh_ed25519 + gcloud_ed25519")
      menu_single_select choices
      if [[ "$REPLY" -eq 1 ]]; then
        generate_ssh_key "id_ed25519" "$USER_SHORT@$COMPANY_DOMAIN"; vrun "ssh-add \"$HOME/.ssh/id_ed25519\""
      else
        generate_ssh_key "gh_ed25519" "$USER_SHORT@$COMPANY_DOMAIN"; vrun "ssh-add \"$HOME/.ssh/gh_ed25519\""
        generate_ssh_key "gcloud_ed25519" "$USER_SHORT@$COMPANY_DOMAIN"; vrun "ssh-add \"$HOME/.ssh/gcloud_ed25519\""
      fi
      ok "SSH keys generated/added." ; RUN_LOG+=("✓ keys generated/added")
    fi
    ensure_ssh_agent_zshrc_lines; ok "Configured ssh-agent autostart in ~/.zshrc"; RUN_LOG+=("✓ zshrc autostart for ssh-agent")
  fi
}

##############
# 4) Xcode   #
##############
task_xcode() {
  section "Xcode / Command Line Tools"
  local have_clt=false have_xcode=false license_ok=false
  if vrun "xcode-select -p"; then have_clt=true; ok "Command Line Tools installed."; RUN_LOG+=("• CLT installed")
  else warn "CLT not installed."; queue_issue "clt_install" "Xcode CLT not installed."; fi

  [[ -d /Applications/Xcode.app ]] && { have_xcode=true; ok "Xcode app installed."; } || warn "Xcode app not found."

  if vrun "xcodebuild -license status"; then license_ok=true; ok "Xcode license accepted."
  else warn "Xcode license not accepted."; queue_issue "xcode_license" "License not accepted."; fi

  if $DO_INSTALL; then
    $have_clt || { note "Triggering CLT installer (GUI)…"; vrun "xcode-select --install || true"; }
    $license_ok || $have_xcode && { note "Opening Xcode license…"; vrun "sudo xcodebuild -license || true"; }
  fi
}

#########################
# 5) Ruby via rbenv     #
#########################
task_rbenv_ruby(){
  section "Ruby Environment (rbenv)"
  local want_ver="3.2.6" have_rbenv=false installed_v="" rbv=""
  if vrun "command -v rbenv"; then
    have_rbenv=true; installed_v="$(rbenv --version 2>/dev/null || true)"
    print "rbenv --version -> ${installed_v:-<none>}"
    ok "rbenv present."; RUN_LOG+=("• rbenv present")
  else
    warn "rbenv not installed."; queue_issue "rbenv_install" "rbenv not installed."
  fi

  local deps=(libyaml readline openssl@3 gmp zlib)
  for d in "${deps[@]}"; do
    if vrun "brew list $d"; then ok "$d installed (brew)."
    else
      warn "$d missing."; queue_issue "dep_$d" "$d not installed."
      $DO_INSTALL && vrun "brew install $d" && ok "Installed $d" && RUN_LOG+=("✓ $d installed")
    fi
  done

  $have_rbenv || { $DO_INSTALL && vrun "brew install rbenv" && ok "Installed rbenv." && RUN_LOG+=("✓ rbenv installed"); }

  if ! grep -q 'rbenv init' "$HOME/.zshrc" 2>/dev/null; then
    note "Adding rbenv init to ~/.zshrc"
    {
      echo ''
      echo '# rbenv init'
      echo 'export PATH="$HOME/.rbenv/bin:$PATH"'
      echo 'eval "$(rbenv init - zsh)"'
    } >> "$HOME/.zshrc"
    ok "Added rbenv init lines."; RUN_LOG+=("✓ rbenv init added to zshrc")
  else
    ok "~/.zshrc already initializes rbenv."
  fi

  if vrun "command -v ruby"; then
    rbv="$(ruby -v 2>/dev/null || true)"; print "ruby -v -> ${rbv:-<none>}"
    if [[ "$rbv" != *"$want_ver"* ]]; then
      warn "Ruby is not $want_ver (Cloud Dev Env may require $want_ver)."
      if $DO_INSTALL; then
        print -n "Install Ruby $want_ver with rbenv now? (y/N): "; read -r a
        if [[ "$a" == [yY]* ]]; then
          vrun "rbenv install -s $want_ver"
          vrun "rbenv global $want_ver"
          vrun "rbenv rehash"
          ok "Ruby $want_ver installed & set."; RUN_LOG+=("✓ Ruby $want_ver set")
          vrun "ruby -v"
        else
          queue_issue "ruby_version" "Ruby not set to $want_ver."
        fi
      else
        queue_issue "ruby_version" "Ruby not set to $want_ver."
      fi
    else
      ok "Ruby version is $want_ver."
    fi
  else
    warn "ruby not found in PATH."; queue_issue "ruby_missing" "Ruby binary not found."
  fi
}

#############
# 6) GitHub #
#############
ensure_github_host_config(){
  local cfg="$HOME/.ssh/config"; touch "$cfg"; chmod 600 "$cfg"
  if ! grep -q '^Host github.com' "$cfg"; then
    print -P "${DIM}Adding Host github.com stanza to ~/.ssh/config${RESET}"
    local ident="~/.ssh/gh_ed25519"; [[ -f "$HOME/.ssh/gh_ed25519" ]] || ident="~/.ssh/id_ed25519"
    cat >> "$cfg" <<EOF

Host github.com
  HostName github.com
  User git
  AddKeysToAgent yes
  IdentityFile $ident
  IdentitiesOnly yes
EOF
    ok "Wrote github.com host block."; RUN_LOG+=("✓ ssh config: github.com block")
  else
    ok "github.com host block exists."
  fi
}
task_github(){
  section "GitHub"
  if vrun "ssh -T git@github.com -o StrictHostKeyChecking=no -o BatchMode=yes"; then
    ok "SSH to GitHub works."; RUN_LOG+=("• SSH to GitHub OK")
  else
    warn "SSH to GitHub failed."; queue_issue "gh_ssh" "SSH to GitHub not working."
  fi
  local gname gemail; gname="$(git config --global user.name || true)"; gemail="$(git config --global user.email || true)"
  [[ -n "$gname"  ]] && ok "git user.name: $gname"  || { warn "git user.name not set";  queue_issue "git_name"  "git user.name not set"; }
  [[ -n "$gemail" ]] && ok "git user.email: $gemail" || { warn "git user.email not set"; queue_issue "git_email" "git user.email not set"; }
  if [[ -f "$HOME/.ssh/config" ]] && grep -q '^Host github.com' "$HOME/.ssh/config"; then ok "~/.ssh/config has Host github.com"
  else warn "~/.ssh/config missing Host github.com"; queue_issue "ssh_host_github" "Add Host github.com to ssh config."; fi

  if $DO_INSTALL; then
    local ghuser; print -n "Enter your GitHub username: "; read -r ghuser
    [[ -n "$ghuser" ]] && { vrun "git config --global user.name \"$ghuser\""; ok "Set git user.name to $ghuser"; RUN_LOG+=("✓ git user.name set"); }
    local email="$USER_SHORT@$COMPANY_DOMAIN"; vrun "git config --global user.email \"$email\""; ok "Set git user.email to $email"; RUN_LOG+=("✓ git user.email set")
    [[ -f "$HOME/.ssh/gh_ed25519" ]] && vrun "ssh-add \"$HOME/.ssh/gh_ed25519\"" || { [[ -f "$HOME/.ssh/id_ed25519" ]] && vrun "ssh-add \"$HOME/.ssh/id_ed25519\"" || true; }
    ensure_github_host_config
    if vrun "ssh -T git@github.com -o StrictHostKeyChecking=no -o BatchMode=yes"; then ok "SSH to GitHub now working."
    else
      warn "Still cannot SSH to GitHub."
      if vrun "command -v gh"; then note "Launching 'gh auth login'…"; vrun "gh auth login || true"; fi
      note "Docs: https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account"
      local keypath=""; [[ -f "$HOME/.ssh/gh_ed25519.pub" ]] && keypath="$HOME/.ssh/gh_ed25519.pub" || [[ -f "$HOME/.ssh/id_ed25519.pub" ]] && keypath="$HOME/.ssh/id_ed25519.pub"
      [[ -n "$keypath" ]] && note "Public key to add: $keypath"
    fi
  fi
}

########################################
# Register tasks (before execution!)
########################################
register_task "brew"            "Homebrew"                    "task_brew"
register_task "optional_first"  "Optional Software (run first if selected)" "task_optional_software"
register_task "ssh"             "SSH Configuration"           "task_ssh"
register_task "xcode"           "Xcode & Command Line Tools"  "task_xcode"
register_task "ruby"            "Ruby (rbenv) & 3.2.6"        "task_rbenv_ruby"
register_task "github"          "GitHub Setup & SSH"          "task_github"

########################
# First selection flow #
########################
title "Mode Selection"
if $DO_INSTALL; then
  ok "Install flag detected: proceeding with Checks & Install."
else
  local top_choices=("Checks only" "Checks & Install")
  print "Choose what to do:"
  menu_single_select top_choices
  case "$REPLY" in 1) DO_INSTALL=false ;; 2) DO_INSTALL=true ;; esac
fi

#########################
# Which tasks to run    #
#########################
typeset -a menu_to_task menu_items; menu_items=(); menu_to_task=()
if $INCLUDE_OPTIONAL; then
  menu_items=("Homebrew" "Optional Software" "SSH" "Xcode" "Ruby (rbenv)" "GitHub")
  menu_to_task=("brew" "optional_first" "ssh" "xcode" "ruby" "github")
else
  menu_items=("Homebrew" "SSH" "Xcode" "Ruby (rbenv)" "GitHub")
  menu_to_task=("brew" "ssh" "xcode" "ruby" "github")
fi

menu_multi_select menu_items

# Visible summary of choices
title "Selections"
MODE_LABEL=$($DO_INSTALL && echo "Checks & Install" || echo "Checks only")
print "Mode:          $MODE_LABEL"
if (( ${#SELECTED_INDEXES[@]} )); then
  print "Tasks chosen:"; for idx in "${SELECTED_INDEXES[@]}"; do print " - ${menu_items[$idx]}"; done
else
  warn "No tasks selected—exiting."; exit 0
fi

#########################
# Execute selected tasks#
#########################
# Build ordered list of task IDs to run
typeset -a ordered_task_ids=()
typeset idx tid have_optional=false
for idx in "${SELECTED_INDEXES[@]}"; do
  tid="${menu_to_task[$idx]}"
  [[ "$tid" == "optional_first" ]] && have_optional=true
done
$have_optional && ordered_task_ids+=("optional_first")
for idx in "${SELECTED_INDEXES[@]}"; do
  tid="${menu_to_task[$idx]}"
  [[ "$tid" == "optional_first" ]] && continue
  ordered_task_ids+=("$tid")
done

# Only initialize brew env if needed (brew or ruby selected)
needs_brew=false
for tid in "${ordered_task_ids[@]}"; do
  [[ "$tid" == "brew" || "$tid" == "ruby" ]] && needs_brew=true
done
if $needs_brew && vrun "command -v brew"; then
  vrun 'eval "$(/usr/bin/env brew shellenv)"'
fi

# Run each selected task in order
for tid in "${ordered_task_ids[@]}"; do
  fn="${TASK_FN[$tid]-}"
  if [[ -n "$fn" ]]; then
    "$fn"
  else
    warn "No handler registered for task id: $tid"
  fi
done

#######################################
# Summary / outstanding items         #
#######################################
title "Summary"
if (( ${#RUN_LOG[@]} )); then
  for line in "${RUN_LOG[@]}"; do print " - $line"; done
else
  print " - No changes were necessary."
fi

if (( ${#TODO_ITEMS_MSGS[@]} )); then
  print ""
  warn "Items to fix (not resolved during this run):"
  for msg in "${TODO_ITEMS_MSGS[@]}"; do print " - $msg"; done
  print ""
  print "Would you like to try to resolve any of these now?"
  local again=("No (finish)" "Yes (select issues)"); menu_single_select again
  if [[ "$REPLY" -eq 2 ]]; then
    typeset -A dedup; for id in "${TODO_ITEMS_TASKS[@]}"; do dedup["$id"]=1; done
    typeset -a issue_ids issue_labels
    for id _ in "${(@kv)dedup}"; do issue_ids+=("$id"); issue_labels+=("${TASK_LABEL[$id]:-$id}"); done
    if (( ${#issue_ids[@]} )); then
      menu_multi_select issue_labels
      if (( ${#SELECTED_INDEXES[@]} )); then
        for idx in "${SELECTED_INDEXES[@]}"; do
          id="${issue_ids[$idx]}"; fn2="${TASK_FN[$id]-}"
          [[ -z "$fn2" ]] && { warn "No direct handler for: $id"; continue; }
          section "Attempting: ${TASK_LABEL[$id]:-$id}"
          "$fn2"
        done
      fi
    fi
  fi
fi

##############################################
# Final: Suggest iTerm2 if not currently in  #
##############################################
if $INCLUDE_OPTIONAL; then
  if [[ "${TERM_PROGRAM:-}" != "iTerm.app" ]]; then
    print ""
    print -n "Open iTerm2 now? (y/N): "; read -r openit
    if [[ "$openit" == [yY]* ]]; then open -a "iTerm" && ok "iTerm2 launching…" || warn "Could not open iTerm2."; fi
    note "Consider closing Terminal and using iTerm2 going forward."
  fi
fi

ok "All done."