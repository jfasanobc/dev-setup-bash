# BCloud Local Environment Setup Script

## Current Version: **v3.0.0**

An interactive Zsh script that **checks** and (optionally) **installs/fixes** a macOS development environment.  
v3 introduces a full-screen TUI with arrow-key navigation, space-to-toggle multi-selects, a “Proceed” row, and verbose logging.

---

## What it checks / installs

### ✅ Homebrew
- Detects Apple Silicon vs Intel and verifies Homebrew is installed in the **correct prefix**  
  (`/opt/homebrew` on Apple Silicon, `/usr/local` on Intel).
- In install mode, installs Homebrew (or flags mis-located installs for remediation).

### ✅ Optional Software (runs first if selected)
- **GitHub CLI (`gh`)**
- **iTerm2**
- **DBeaver Community**
- Each item is checked; when install mode is enabled, missing items are installed via Homebrew.

### ✅ SSH Configuration
- Lists public keys in `~/.ssh` with full paths.
- Ensures `~/.ssh/config` exists.
- Checks `ssh-agent` is running and adds an **autostart block to `~/.zshrc`** (not a launchd plist).
- In install mode:
  - Prompts to generate either a **single key** (`id_ed25519`) or **separate keys**  
    (`gh_ed25519` for GitHub, `gcloud_ed25519` for Google Cloud).
  - Uses comment `first.last@bigcommerce.com` (derived from `$HOME`).
  - Adds keys to `ssh-agent`.

### ✅ Xcode / Command Line Tools
- Verifies Command Line Tools (`xcode-select -p`), Xcode.app, and **license acceptance**.
- Install mode:
  - Triggers **CLT installer** when missing.
  - Runs **`sudo xcodebuild -license accept`** when needed.

### ✅ Ruby (rbenv) & dependencies
- Checks for `rbenv` and common Ruby build deps (`libyaml`, `readline`, `openssl@3`, `gmp`, `zlib`).
- Verifies **Ruby 3.2.6** and offers to install + set global with `rbenv`.
- Adds an `rbenv init` block to `~/.zshrc` if missing.

### ✅ GitHub
- SSH connectivity test to GitHub.  
  Recognizes GitHub’s **expected success message** (“successfully authenticated…does not provide shell access”) as **success**.
- Verifies `git config --global user.name` and `user.email`.
- Ensures a `Host github.com` block exists in `~/.ssh/config`.
- Install mode can:
  - Prompt for GitHub username and set global git config.
  - Add the appropriate SSH key to `ssh-agent`.
  - Run `gh auth login` when `gh` is available.

---

## Usage

```bash
# Make executable
chmod +x mac-cdvm-check.zsh

# Default: interactive + checks only
./mac-cdvm-check.zsh

# Install/fix everything you select (skips first “mode” prompt)
./mac-cdvm-check.zsh -i

# Include Optional Software (gh, iTerm2, DBeaver) in the task menu
./mac-cdvm-check.zsh -o

# Verbose mode: show each command that runs and keep its output on screen
./mac-cdvm-check.zsh -v

# Combine flags in any order
./mac-cdvm-check.zsh -io
./mac-cdvm-check.zsh -ov
./mac-cdvm-check.zsh -iov