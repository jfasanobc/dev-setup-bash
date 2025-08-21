#!/usr/bin/env zsh
# mac_dev_setup.zsh
# Interactive section selector; check-only by default, install with -i/--install.

set -euo pipefail

# -----------------------
# Flags & globals
# -----------------------
DO_INSTALL=false
case "${1:-}" in
  -i|--install)
    DO_INSTALL=true
    ;;
  -v|--version)
    VERSION_FILE="$(dirname "$0")/../VERSION"
    if [[ -f "$VERSION_FILE" ]]; then
      cat "$VERSION_FILE"
    else
      echo "unknown"
    fi
    exit 0
    ;;
  "" )
    # no args: just continue into interactive checks
    ;;
  *  )
    echo "Usage: $0 [--install|-i|--version|-v]"
    exit 2
    ;;
esac


BOLD=$'\033[1m'; RESET=$'\033[0m'
GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; BLUE=$'\033[34m'
tag(){ [[ $DO_INSTALL == true ]] && printf "${BLUE}[INSTALL]${RESET} %s\n" "$1" || printf "${BLUE}[CHECK]${RESET} %s\n" "$1"; }
ok(){  printf "   ${GREEN}✔${RESET} %s\n" "$1"; }
warn(){printf "   ${YELLOW}▲${RESET} %s\n" "$1"; }
err(){ printf "   ${RED}✘%s${RESET}\n" "${1:+ }$1"; MISSING=$((MISSING+1)); }
die(){ printf "${RED}%s${RESET}\n" "$1"; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only."

MISSING=0
REQUIRED_RUBY="3.2.6"
ARCH="$(uname -m)" # arm64 or x86_64

# Parse first.last from /Users/first.last
USER_BASENAME="${HOME:t}" # zsh basename
EMAIL_BC="${USER_BASENAME}@bigcommerce.com"

# Ask GitHub username up-front
read -r "?GitHub username: " GITHUB_USER

# --- Terminal detection ---
TERM_APP="${TERM_PROGRAM:-}"
IS_ITERM=false
IS_TERMINAL=false
case "$TERM_APP" in
  iTerm.app|iTerm2|iTerm) IS_ITERM=true ;;
  Apple_Terminal|Apple\ Terminal) IS_TERMINAL=true ;;
esac

# we’ll set this later in the iTerm2 section if we want to print a note at the end
NOTE_ITERM_HANDOFF=false

# -----------------------
# Helpers
# -----------------------
brew_shellenv() {
  if [[ -d /opt/homebrew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -d /usr/local/Homebrew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

confirm() {
  local q="${1:-Proceed?} [y/N]: "
  read -r "?$q" ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

cols() { echo ${COLUMNS:-$(tput cols 2>/dev/null || echo 120)}; }

truncate_to() { # usage: truncate_to width "text"
  local w="$1" s="$2"
  (( ${#s} <= w )) && { print -r -- "$s"; return; }
  print -r -- "${s:0:$((w-1))}…"
}

print_ssh_table() {
  tag "SSH public keys"

  local c1=20   # .pub file name
  local c2=60   # absolute path (.pub file)

  printf "%-${c1}s | %-${c2}s | %s\n" "Public Key File" "Absolute Path (.pub)" "Contents"
  printf "%-${c1}s-+-%-${c2}s-+-%s\n" "" "" "" | tr ' ' '-'

  local found=false
  local pub name abspath pk
  for pub in "$HOME/.ssh"/*.pub(N); do
    found=true
    name="${pub:t}"         # e.g., id_ed25519.pub
    abspath="${pub:a}"      # full path to .pub file
    pk="$(<"$pub")"         # full key contents

    printf "%-${c1}s | %-${c2}s | %s\n" "$name" "$abspath" "$pk"
  done

  $found || warn "No public keys (*.pub) found in ~/.ssh"
}

ensure_ssh_agent_autostart() {
  local cfg="$HOME/.zshrc"
  local marker="# >>> ssh-agent autostart >>>"
  if ! grep -q "$marker" "$cfg" 2>/dev/null; then
    tag "Adding ssh-agent autostart to ~/.zshrc"
    cat >> "$cfg" <<'EOF'

# >>> ssh-agent autostart >>>
if ! pgrep -qx ssh-agent >/dev/null; then
  eval "$(ssh-agent -s)" >/dev/null
fi
# <<< ssh-agent autostart <<<
EOF
    ok "Updated ~/.zshrc with ssh-agent autostart"
  else
    ok "ssh-agent autostart already present in ~/.zshrc"
  fi
}

ssh_start_agent() {
  if pgrep -qx ssh-agent >/dev/null 2>&1; then
    ok "ssh-agent already running"
  else
    eval "$(ssh-agent -s)" >/dev/null
    ok "ssh-agent started"
  fi
}

ssh_add_if_exists() {
  local key="$1"
  [[ -f "$key" ]] || return 0
  if ssh-add -l 2>/dev/null | grep -q " ${key}$"; then
    ok "Key already added: $key"
  else
    ssh-add --apple-use-keychain "$key" 2>/dev/null || ssh-add "$key"
    ok "Added key: $key"
  fi
}

github_ssh_ok() {
  # Capture both stdout/stderr; don’t fail function on non-zero exit
  local out rc
  out="$(ssh -T git@github.com \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=7 2>&1 || true)"
  rc=$?

  # Treat these as success (GitHub prints them on successful auth)
  if print -r -- "$out" | grep -qiE 'successfully authenticated|does not provide shell access|^hi .*!$'; then
    return 0
  fi

  # Uncomment if you want to debug:
  # warn "GitHub SSH output (rc=$rc):\n$out"

  return 1
}

# -----------------------
# Section selector
# -----------------------
print_menu() {
  cat <<MENU
${BOLD}Choose sections (comma-separated) or 'all':${RESET}
  1) SSH
  2) Homebrew
  3) iTerm2
  4) Xcode / Command Line Tools
  5) Ruby Environment (rbenv/Ruby $REQUIRED_RUBY)
  6) GitHub / GitHub CLI
MENU
}
print_menu
read -r "?Selection: " SEL
[[ "$SEL" == "all" ]] && SEL="1,2,3,4,5,6"
typeset -A RUN; for n in ${(s:,:)SEL}; do RUN[$n]=1; done

# =======================
# 1) SSH
# =======================
if [[ -n "${RUN[1]:-}" ]]; then
  tag "SSH: enumerate keys and config"
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  [[ -f "$HOME/.ssh/config" ]] || { touch "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"; ok "Created ~/.ssh/config"; }
  print_ssh_table

  if $DO_INSTALL; then
    tag "SSH: key generation (install mode)"
    echo "Use one key for everything or separate keys?"
    echo "  1) Single key (default name: id_ed25519)"
    echo "  2) Two keys (GitHub + Google Cloud)"
    read -r "?Choice [1/2]: " CH; CH="${CH:-1}"

    if [[ "$CH" == "1" ]]; then
      read -r "?Preferred key name [id_ed25519]: " KEYNAME; KEYNAME="${KEYNAME:-id_ed25519}"
      localpath="$HOME/.ssh/$KEYNAME"
      if [[ -f "$localpath" || -f "$localpath.pub" ]]; then
        warn "Key $KEYNAME already exists, skipping generation."
      else
        ssh-keygen -t ed25519 -C "$EMAIL_BC" -f "$localpath" -N ""
        ok "Generated $localpath"
      fi
      ssh_start_agent
      ensure_ssh_agent_autostart
      ssh_add_if_exists "$localpath"

    else
      read -r "?GitHub key name [gh_ed25519]: " GHKEY; GHKEY="${GHKEY:-gh_ed25519}"
      read -r "?Google Cloud key name [gcloud_ed25519]: " GCKEY; GCKEY="${GCKEY:-gcloud_ed25519}"

      for key in "$GHKEY" "$GCKEY"; do
        localpath="$HOME/.ssh/$key"
        if [[ -f "$localpath" || -f "$localpath.pub" ]]; then
          warn "Key $key already exists, skipping."
        else
          ssh-keygen -t ed25519 -C "$EMAIL_BC" -f "$localpath" -N ""
          ok "Generated $localpath"
        fi
      done

      ssh_start_agent
      ensure_ssh_agent_autostart
      ssh_add_if_exists "$HOME/.ssh/$GHKEY"
      ssh_add_if_exists "$HOME/.ssh/$GCKEY"
    fi

    print_ssh_table
  fi
fi

# =======================
# 2) Homebrew
# =======================
if [[ -n "${RUN[2]:-}" ]]; then
  tag "Homebrew"
  if have brew; then
    ok "brew at $(command -v brew)"
    brew --version | head -n1
    # Check “right” location for arch
    if [[ "$ARCH" == "arm64" && "$(command -v brew)" != /opt/homebrew/* ]]; then
      err "Apple Silicon detected but brew is not under /opt/homebrew"
    elif [[ "$ARCH" == "x86_64" && "$(command -v brew)" != /usr/local/* ]]; then
      err "Intel detected but brew is not under /usr/local"
    else
      ok "Homebrew location matches architecture ($ARCH)"
    fi
  else
    err "Homebrew not installed"
  fi

  if $DO_INSTALL; then
    brew_shellenv
    if ! have brew; then
      if [[ "$ARCH" == "arm64" ]]; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      else
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      fi
      brew_shellenv
      ok "Homebrew installed"
    else
      # Wrong location? Offer to uninstall old and reinstall.
      bad=false
      if [[ "$ARCH" == "arm64" && "$(command -v brew)" != /opt/homebrew/* ]]; then bad=true; fi
      if [[ "$ARCH" == "x86_64" && "$(command -v brew)" != /usr/local/* ]]; then bad=true; fi
      if $bad; then
        warn "Homebrew install path does not match architecture."
        if confirm "Uninstall current Homebrew and reinstall for $ARCH?"; then
          NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)"
          ok "Uninstalled old Homebrew"
          /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
          brew_shellenv
          ok "Reinstalled Homebrew for $ARCH"
        else
          warn "Skipped Homebrew reinstall"
        fi
      fi
    fi
  fi
fi

# =======================
# 3) iTerm2
# =======================
if [[ -n "${RUN[3]:-}" ]]; then
  tag "iTerm2"

  local ITERM_INSTALLED=false
  if [[ -d "/Applications/iTerm.app" ]] || mdfind "kMDItemCFBundleIdentifier == 'com.googlecode.iterm2'" | grep -q .; then
    ok "iTerm2 present"
    ITERM_INSTALLED=true
  else
    err "iTerm2 not found"
  fi

  if have brew && brew list --cask iterm2 >/dev/null 2>&1; then
    ok "Installed via Homebrew Cask"
  fi

  if $DO_INSTALL && [[ "$ITERM_INSTALLED" == "false" ]]; then
    have brew || die "Brew required to install iTerm2"
    brew install --cask iterm2
    ok "iTerm2 installed"
    ITERM_INSTALLED=true
  fi

  # Behavior differs by host terminal:
  if $IS_ITERM; then
    ok "Running inside iTerm2; no handoff actions needed."
  else
    # We are in Terminal.app or another terminal; we won’t try to switch mid-run.
    # We’ll print a helpful note at the end.
    NOTE_ITERM_HANDOFF=true
  fi
fi

# =======================
# 4) Xcode / CLT
# =======================
if [[ -n "${RUN[4]:-}" ]]; then
  tag "Xcode / Command Line Tools"
  if xcode-select -p >/dev/null 2>&1; then
    ok "Command Line Tools installed"
  else
    err "Command Line Tools not installed"
  fi

  if [[ -d "/Applications/Xcode.app" ]]; then
    ok "Xcode.app present"
  else
    warn "Xcode.app not found (IDE is optional for many workflows)"
  fi

  # License acceptance check
  if /usr/bin/xcrun clang -v >/dev/null 2>&1; then
    ok "Xcode license appears accepted"
  else
    warn "Xcode license may not be accepted (run: sudo xcodebuild -license)"
  fi

  if $DO_INSTALL; then
    echo "Open ${BOLD}Self Service${RESET}, search for ${BOLD}Xcode${RESET}, and install."
    if confirm "Open Self Service now?"; then open -a "Self Service" || warn "Self Service not found"; fi
    if confirm "After installing Xcode/CLT, re-run checks now?"; then
      if xcode-select -p >/dev/null 2>&1; then ok "CLT detected"; else err "CLT still missing"; fi
      [[ -d "/Applications/Xcode.app" ]] && ok "Xcode.app present" || warn "Xcode.app not found"
    else
      die "Paused due to Xcode/CLT requirement. Please complete install and re-run."
    fi
  fi
fi

# =======================
# 5) Ruby / rbenv
# =======================
if [[ -n "${RUN[5]:-}" ]]; then
  tag "rbenv / Ruby $REQUIRED_RUBY"
  if have rbenv; then
    ok "rbenv at $(command -v rbenv)"
    rbenv --version || true
  else
    err "rbenv not installed"
  fi

  # Dependencies (just check common ones)
  if have brew; then
    brew list --versions libyaml >/dev/null 2>&1 && ok "libyaml installed (brew)" || err "libyaml missing"
  else
    warn "Brew not present; skipping libyaml check"
  fi

  if have rbenv && rbenv prefix "$REQUIRED_RUBY" >/dev/null 2>&1; then
    ok "Ruby $REQUIRED_RUBY installed under rbenv"
  else
    err "Ruby $REQUIRED_RUBY not installed under rbenv"
  fi

  if have rbenv; then
    global_rb="$(rbenv global 2>/dev/null || true)"
    [[ "$global_rb" == "$REQUIRED_RUBY" ]] && ok "Global Ruby set to $REQUIRED_RUBY" || warn "Global Ruby is $global_rb"
    which_ruby="$(command -v ruby || true)"; [[ -n "$which_ruby" ]] && ok "ruby resolves to $which_ruby" || err "ruby not on PATH"
    ruby -v || true
  fi

  if $DO_INSTALL; then
    have brew || die "Brew required for rbenv/libyaml install"
    brew install rbenv libyaml || true
    export PATH="$HOME/.rbenv/bin:$PATH"
    eval "$(rbenv init - zsh)" || true
    if ! grep -q 'rbenv init - zsh' "$HOME/.zshrc" 2>/dev/null; then
      print >> "$HOME/.zshrc" -- '\n# rbenv\nexport PATH="$HOME/.rbenv/bin:$PATH"\neval "$(rbenv init - zsh)"'
      ok "Appended rbenv init to ~/.zshrc"
    fi
    if ! rbenv prefix "$REQUIRED_RUBY" >/dev/null 2>&1; then
      RUBY_CONFIGURE_OPTS="--with-openssl-dir=$(brew --prefix openssl@3 2>/dev/null || echo /usr)" rbenv install "$REQUIRED_RUBY"
      ok "Installed Ruby $REQUIRED_RUBY"
    fi
    rbenv global "$REQUIRED_RUBY"; rbenv rehash
    ok "Set Ruby $REQUIRED_RUBY global"
  fi
fi

# =======================
# 6) GitHub / gh
# =======================
if [[ -n "${RUN[6]:-}" ]]; then
  tag "GitHub SSH & gh CLI"
  # SSH config entry
  if grep -q '^Host github.com' "$HOME/.ssh/config" 2>/dev/null; then
    ok "ssh config has Host github.com"
  else
    warn "ssh config missing Host github.com"
  fi

 # Test SSH (robust handling of GitHub's behavior)
  if github_ssh_ok; then
    ok "SSH to GitHub works"
  else
    warn "SSH to GitHub not confirmed (keys may not be added or GitHub not configured)"
  fi

  # gh CLI
  if have gh; then
    ok "gh CLI present: $(gh --version | head -n1)"
    gh auth status || true
  else
    err "gh CLI not installed"
  fi

  if $DO_INSTALL; then
    # Add minimal ssh config for GitHub if missing
    if ! grep -q '^Host github.com' "$HOME/.ssh/config" 2>/dev/null; then
      cat >> "$HOME/.ssh/config" <<'EOF'

Host github.com
  HostName github.com
  User git
  AddKeysToAgent yes
  UseKeychain yes
  IdentityFile ~/.ssh/id_ed25519
EOF
      ok "Added basic Host github.com to ~/.ssh/config"
    fi

    have brew || die "Brew required to install gh"
    brew install gh || true
    if confirm "Start gh auth flow now?"; then
      gh auth login -h github.com
      ok "Returned from gh auth; re-testing SSH…"
      ssh -T git@github.com -o BatchMode=yes -o StrictHostKeyChecking=accept-new || true
    fi
  fi
fi

# -----------------------
# Final result
# -----------------------
# --- Friendly note if we ran in Terminal.app (or other non-iTerm terminal) ---
if $NOTE_ITERM_HANDOFF; then
  printf "\n\033[1;33mNote:\033[0m You’re running this in Terminal.app (or another terminal).\n"
  printf "      For the best experience, quit Terminal and open iTerm2:\n"
  printf "        \033[1mopen -a iTerm\033[0m\n\n"
fi

if (( MISSING > 0 )); then
  printf "\n${RED}%d critical checks failed.${RESET}\n" "$MISSING"
  exit 1
else
  printf "\n${GREEN}All selected sections completed.${RESET}\n"
fi