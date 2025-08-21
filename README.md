# BCloud Local Environment Setup Script

## Current Version: v2

This script bootstraps and validates a local macOS development environment.  
By default it runs in **check-only mode**; use the install flag to attempt to fix or install missing dependencies.  
You will be prompted to select which sections to run (`all` or a comma-separated list).

---

## Checks & Install Steps

- [ ] **SSH**
  - Always:
    - Lists all SSH keys in `~/.ssh` with name, path, and public key (table format)
    - Ensures `~/.ssh/config` exists
    - Ensures `ssh-agent` is running
    - Checks that `ssh-agent` autostart is present in `~/.zshrc`
  - Install mode:
    - Prompts for **single key** (default `id_ed25519`) or **separate keys** (`gh_ed25519` for GitHub, `gcloud_ed25519` for Cloud VM)
    - Generates keys with `-C first.last@bigcommerce.com`
    - Adds generated keys to `ssh-agent`
    - Reprints SSH key table

- [ ] **Homebrew**
  - Always:
    - Verifies if Homebrew is installed and reports version
    - Checks whether Homebrew is in the correct path for the machine’s architecture (`/opt/homebrew` for Apple Silicon, `/usr/local` for Intel)
  - Install mode:
    - Installs the appropriate Homebrew version for the detected processor type
    - Can uninstall and reinstall if Homebrew is in the wrong location

- [ ] **iTerm2**
  - Always:
    - Checks if iTerm2 is installed
    - Detects whether iTerm2 was installed via Homebrew Cask
  - Install mode:
    - Installs iTerm2 with Homebrew if missing
    - If currently running inside Terminal.app, launches iTerm2 and warns user to switch

- [ ] **Xcode / Command Line Tools**
  - Always:
    - Checks if Command Line Tools are installed (`xcode-select -p`)
    - Checks if full Xcode.app is present
    - Checks if the Xcode license agreement is accepted
  - Install mode:
    - Prompts user to install Xcode via **Self Service** (Jamf)
    - Offers to re-run checks after installation
    - Exits with error if installation cannot be confirmed

- [ ] **Ruby Environment (rbenv)**
  - Always:
    - Checks if `rbenv` is installed
    - Reports `rbenv` version
    - Checks for Ruby build dependencies (e.g., `libyaml`)
    - Verifies Ruby **3.2.6** is installed under rbenv
    - Verifies Ruby **3.2.6** is set as the global version
    - Reports `ruby -v` and active path
  - Install mode:
    - Installs `rbenv` and dependencies via Homebrew
    - Appends `rbenv init` block to `~/.zshrc` if missing
    - Installs Ruby 3.2.6 and sets it globally

- [ ] **GitHub / GitHub CLI**
  - Always:
    - Tests SSH connection to GitHub (`ssh -T git@github.com`)
    - Checks for `Host github.com` entry in `~/.ssh/config`
    - Checks if GitHub CLI (`gh`) is installed
  - Install mode:
    - Adds minimal SSH config entry for GitHub if missing
    - Installs `gh` via Homebrew
    - Runs `gh auth login` to complete GitHub authentication

---

## Usage

```bash
# Check mode (default)
./mac_dev_setup.zsh

# Install / fix mode
./mac_dev_setup.zsh -i
```