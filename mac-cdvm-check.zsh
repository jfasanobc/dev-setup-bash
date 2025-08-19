#!/usr/bin/env zsh
# mac_dev_setup.zsh
# Default: check only (no changes). With --install / -i: perform installs/fixes.
# Exits non-zero if any critical checks fail (in check mode) or if an install step fails (in install mode).

set -euo pipefail

# ------------------------
# Flags & environment
# ------------------------
DO_INSTALL=false
case "${1:-}" in
  -i|--install) DO_INSTALL=true ;;
  "" ) ;;
  *  ) echo "Usage: $0 [--install|-i]"; exit 2 ;;
esac

log()  { printf "\n\033[1;34m[%s]\033[0m %s\n" "$([[ $DO_INSTALL == true ]] && echo INSTALL || echo CHECK)" "$*"; }
ok()   { printf "   ✅ %s\n" "$*"; }
warn() { printf "   ⚠️  %s\n" "$*"; }
err()  { printf "   ❌ %s\n" "$*"; MISSING=$((MISSING+1)); }
die()  { printf "\n\033[1;31m✖ %s\033[0m\n" "$*"; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "This script is for macOS."

MISSING=0
REQUIRED_RUBY="3.2.6"

# Helper: run a command, but don't explode whole script in install mode; count as failure if it fails.
run_or_err() {
  if "$@"; then return 0; else err "Command failed: $*"; return 1; fi
}

# Detect Homebrew path if present/installed
brew_shellenv() {
  if [[ -d /opt/homebrew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -d /usr/local/Homebrew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

# ------------------------
# 1) Xcode / Command Line Tools
# ------------------------
log "Xcode / Command Line Tools"
if xcode-select -p >/dev/null 2>&1; then
  ok "Command Line Tools installed at $(xcode-select -p)"
else
  if $DO_INSTALL; then
    log "Triggering CLT installer (a macOS dialog may appear)."
    xcode-select --install || true
    warn "If a dialog appeared, complete it, then re-run this script."
  else
    err "Command Line Tools not installed"
  fi
fi

if [[ -d "/Applications/Xcode.app" ]]; then
  ok "Xcode app installed"
else
  warn "Xcode.app not found (often optional unless you need the IDE)."
fi

# ------------------------
# 2) Homebrew
# ------------------------
log "Homebrew"
if command -v brew >/dev/null 2>&1; then
  ok "Homebrew installed at $(command -v brew)"
  brew --version | head -n 1
else
  if $DO_INSTALL; then
    log "Installing Homebrew…"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    brew_shellenv
    # Persist path for zsh
    if ! grep -q 'brew shellenv' "${HOME}/.zprofile" 2>/dev/null; then
      log "Persisting Homebrew path in ~/.zprofile"
      if [[ -d /opt/homebrew ]]; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "${HOME}/.zprofile"
      else
        echo 'eval "$(/usr/local/bin/brew shellenv)"' >> "${HOME}/.zprofile"
      fi
    fi
  else
    err "Homebrew not installed"
  fi
fi

# Ensure brew env for remaining steps
command -v brew >/dev/null 2>&1 && brew_shellenv || true
$DO_INSTALL && brew update || true

# ------------------------
# 3) iTerm2
# ------------------------
log "iTerm2"
if [[ -d "/Applications/iTerm.app" ]] || mdfind "kMDItemCFBundleIdentifier == 'com.googlecode.iterm2'" | grep -q .; then
  ok "iTerm2 installed"
else
  if $DO_INSTALL; then
    log "Installing iTerm2 via Homebrew Cask…"
    run_or_err brew install --cask iterm2
    open -a iTerm || true
  else
    err "iTerm2 not found"
  fi
fi

# ------------------------
# 4) rbenv + libyaml
# ------------------------
log "rbenv"
if command -v rbenv >/dev/null 2>&1; then
  ok "rbenv installed at $(command -v rbenv)"
else
  if $DO_INSTALL; then
    log "Installing rbenv…"
    run_or_err brew install rbenv
  else
    err "rbenv not installed"
  fi
fi

log "libyaml"
if brew list --versions libyaml >/dev/null 2>&1; then
  ok "libyaml installed via brew"
else
  if $DO_INSTALL; then
    log "Installing libyaml…"
    run_or_err brew install libyaml
  else
    err "libyaml not installed"
  fi
fi

# rbenv init in zshrc (install mode only)
if $DO_INSTALL; then
  if ! grep -q 'rbenv init' "${HOME}/.zshrc" 2>/dev/null; then
    log "Adding rbenv init to ~/.zshrc"
    {
      echo ''
      echo '# rbenv initialization'
      echo 'export PATH="$HOME/.rbenv/bin:$PATH"'
      echo 'eval "$(rbenv init - zsh)"'
    } >> "${HOME}/.zshrc"
  else
    ok "rbenv init already present in ~/.zshrc"
  fi
  export PATH="$HOME/.rbenv/bin:$PATH"
  eval "$(rbenv init - zsh)" || true
fi

# ------------------------
# 5) Ruby via rbenv
# ------------------------
log "Ruby via rbenv (${REQUIRED_RUBY})"
if command -v rbenv >/dev/null 2>&1; then
  # Robust: succeeds only if that version is installed under rbenv
  if rbenv prefix "$REQUIRED_RUBY" >/dev/null 2>&1; then
    ok "Ruby $REQUIRED_RUBY installed in rbenv at $(rbenv prefix "$REQUIRED_RUBY")"
  else
    err "Ruby $REQUIRED_RUBY not installed in rbenv"
  fi

  current_global=$(rbenv global 2>/dev/null || true)
  if [[ "$current_global" == "$REQUIRED_RUBY" ]]; then
    ok "Ruby $REQUIRED_RUBY is set as global"
  else
    warn "Global Ruby is not $REQUIRED_RUBY (currently: ${current_global:-unset})"
  fi

  # Optional: show what ruby is resolving to (helps debug PATH/shims issues)
  which_ruby=$(command -v ruby || true)
  ok "ruby resolves to: ${which_ruby:-<not found>}"
  ruby -v || true
else
  warn "Skipping Ruby checks—rbenv not installed."
fi

# ------------------------
# 6) ~/dev folder
# ------------------------
log "~/dev folder"
if [[ -d "$HOME/dev" ]]; then
  ok "~/dev exists"
else
  if $DO_INSTALL; then
    log "Creating ~/dev"
    run_or_err mkdir -p "$HOME/dev"
  else
    warn "~/dev folder not found"
  fi
fi

# ------------------------
# 7) Git + config
# ------------------------
log "Git"
if command -v git >/dev/null 2>&1; then
  ok "git installed: $(git --version)"
else
  if $DO_INSTALL; then
    # Prefer using Xcode CLT git; brew git if desired (optional)
    warn "git CLI not found in PATH. Installing via Homebrew…"
    run_or_err brew install git
  else
    err "git not installed"
  fi
fi

if command -v git >/dev/null 2>&1; then
  NAME="$(git config --global user.name || true)"
  EMAIL="$(git config --global user.email || true)"
  if [[ -n "$NAME" ]]; then ok "git user.name = $NAME"; else
    if $DO_INSTALL && [[ -n "${GIT_NAME:-}" ]]; then
      log "Setting git user.name to '$GIT_NAME'"
      run_or_err git config --global user.name "$GIT_NAME"
    else
      err "git user.name not set (set env GIT_NAME or configure manually)"
    fi
  fi
  if [[ -n "$EMAIL" ]]; then ok "git user.email = $EMAIL"; else
    if $DO_INSTALL && [[ -n "${GIT_EMAIL:-}" ]]; then
      log "Setting git user.email to '$GIT_EMAIL'"
      run_or_err git config --global user.email "$GIT_EMAIL"
    else
      err "git user.email not set (set env GIT_EMAIL or configure manually)"
    fi
  fi
fi

# ------------------------
# 8) SSH key
# ------------------------
log "SSH key"
if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
  ok "SSH key found: ~/.ssh/id_ed25519.pub"
else
  if $DO_INSTALL; then
    if [[ -z "${GIT_EMAIL:-}" ]]; then
      warn "GIT_EMAIL not set; using 'dev@local' as SSH key comment."
    fi
    COMMENT="${GIT_EMAIL:-dev@local}"
    log "Generating new SSH key (ed25519)…"
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    run_or_err ssh-keygen -t ed25519 -C "$COMMENT" -f "$HOME/.ssh/id_ed25519" -N ""
    eval "$(ssh-agent -s)" >/dev/null
    # macOS keychain integration
    {
      echo ""
      echo "Host github.com"
      echo "  AddKeysToAgent yes"
      echo "  UseKeychain yes"
      echo "  IdentityFile ~/.ssh/id_ed25519"
    } >> "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config"
    ssh-add --apple-use-keychain "$HOME/.ssh/id_ed25519" 2>/dev/null || ssh-add "$HOME/.ssh/id_ed25519" || true
    ok "SSH key created. Add it to GitHub: https://github.com/settings/keys"
  else
    err "SSH key (~/.ssh/id_ed25519.pub) not found"
  fi
fi

# ------------------------
# 9) GitHub org invites (cannot auto-check)
# ------------------------
log "GitHub org invites"
warn "Verify you accepted invites for BigCommerce & BigCommerce Labs: https://github.com/settings/organizations"

# ------------------------
# Final result
# ------------------------
if (( MISSING > 0 )); then
  printf "\n\033[1;31m❌ %d critical checks failed.%s\033[0m\n" "$MISSING" "$([[ $DO_INSTALL == true ]] && echo ' (some steps may have been installed but issues remain)')"
  exit 1
else
  printf "\n\033[1;32m✅ %s\033[0m\n" "$([[ $DO_INSTALL == true ]] && echo 'Install/verify complete.' || echo 'All critical checks passed.')"
fi