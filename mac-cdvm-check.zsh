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
typeset -gA TASK_FN TASK_LABEL   # <— ensure truly global associative arrays
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
# Tasks
############################
task_brew() { … }         # (unchanged; omitted here for brevity in this block)
task_optional_software() { … }
task_ssh() { … }
task_xcode() { … }
task_rbenv_ruby() { … }
task_github() { … }

# ——— NOTE ———
# I left the big task bodies exactly as in your last working version.
# Keep them in the file (above), unchanged. I only shortened here to highlight where the fix is.
# —————————

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
  print "Choose what to do:"; menu_single_select top_choices
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

# Summary
title "Selections"
MODE_LABEL=$($DO_INSTALL && echo "Checks & Install" || echo "Checks only")
print "Mode:          $MODE_LABEL"
(( ${#SELECTED_INDEXES[@]} )) || { warn "No tasks selected—exiting."; exit 0; }
print "Tasks chosen:"; for idx in "${SELECTED_INDEXES[@]}"; do print " - ${menu_items[$idx]}"; done

#########################
# Execute selected tasks#
#########################
# Build ordered list; run Optional Software first if chosen
typeset -a ordered_task_ids=()
typeset idx tid have_optional=false
for idx in "${SELECTED_INDEXES[@]}"; do [[ "${menu_to_task[$idx]}" == "optional_first" ]] && have_optional=true; done
$have_optional && ordered_task_ids+=("optional_first")
for idx in "${SELECTED_INDEXES[@]}"; do
  tid="${menu_to_task[$idx]}"; [[ "$tid" == "optional_first" ]] || ordered_task_ids+=("$tid")
done

# Only initialize brew env if needed (brew or ruby selected)
needs_brew=false
for tid in "${ordered_task_ids[@]}"; do [[ "$tid" == "brew" || "$tid" == "ruby" ]] && needs_brew=true; done
if $needs_brew && vrun "command -v brew"; then vrun 'eval "$(/usr/bin/env brew shellenv)"'; fi

# Run each selected task
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
if (( ${#RUN_LOG[@]} )); then for line in "${RUN_LOG[@]}"; do print " - $line"; done
else print " - No changes were necessary."; fi

if (( ${#TODO_ITEMS_MSGS[@]} )); then
  print ""; warn "Items to fix (not resolved during this run):"
  for msg in "${TODO_ITEMS_MSGS[@]}"; do print " - $msg"; done
  print ""; print "Would you like to try to resolve any of these now?"
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
    print ""; print -n "Open iTerm2 now? (y/N): "; read -r openit
    if [[ "$openit" == [yY]* ]]; then open -a "iTerm" && ok "iTerm2 launching…" || warn "Could not open iTerm2."; fi
    note "Consider closing Terminal and using iTerm2 going forward."
  fi
fi

ok "All done."
