BCloud Local Envinronment Setup Script

## Current Version: v1
Generated script with following checks:
- [ ] **Xcode / Command Line Tools**
  - Ensures Xcode Command Line Tools are installed (`xcode-select -p`)
  - Warns if full Xcode.app is not present

- [ ] **Homebrew**
  - Checks if Homebrew is installed and available on `PATH`
  - Reports Homebrew version
  - Adds brew shellenv to `~/.zprofile` (install mode)

- [ ] **iTerm2**
  - Verifies iTerm2 is installed (via `/Applications` or bundle ID)
  - Installs with `brew install --cask iterm2` if missing (install mode)

- [ ] **rbenv**
  - Checks if `rbenv` is installed
  - Ensures `rbenv init` is configured in `~/.zshrc` (install mode)

- [ ] **libyaml**
  - Checks if `libyaml` is installed via Homebrew
  - Installs with `brew install libyaml` if missing (install mode)

- [ ] **Ruby (via rbenv)**
  - Confirms Ruby **3.2.6** is installed in rbenv
  - Verifies Ruby 3.2.6 is set as the global version
  - Reports actual `ruby -v` being used for debugging

- [ ] **~/dev folder**
  - Ensures a `~/dev` directory exists
  - Creates it if missing (install mode)

- [ ] **Git**
  - Checks if Git is installed
  - Reports Git version
  - Validates `git config --global user.name`
  - Validates `git config --global user.email`
  - Optionally sets these if `GIT_NAME` and `GIT_EMAIL` environment variables are provided (install mode)

- [ ] **SSH key**
  - Checks if `~/.ssh/id_ed25519.pub` exists
  - Generates a new key (ed25519) if missing (install mode)
  - Ensures ssh-agent and macOS keychain integration are configured

- [ ] **GitHub organization invites**
  - Reminds you to confirm membership in:
    - BigCommerce
    - BigCommerce Labs
  - (Cannot be auto-checked programmatically)

 ## Options
`-i` | `--install` - Install all dependencies that are listed.