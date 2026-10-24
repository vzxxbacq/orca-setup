# shellcheck shell=bash
# Homebrew formulae and casks. Existing installs are detected and never upgraded.

# Packages from a tap ("owner/tap/name") are listed under their short name.
brew_formula_installed() { brew list --formula --versions "${1##*/}" >/dev/null 2>&1; }
brew_cask_installed() { brew list --cask "${1##*/}" >/dev/null 2>&1; }

# macos_installed <method>: the package manager already holds the package (the check command may be off PATH).
macos_installed() {
  have brew || return 1
  case "$1" in
    brew:*) brew_formula_installed "${1#brew:}" ;;
    cask:*) brew_cask_installed "${1#cask:}" ;;
    *) return 1 ;;
  esac
}

# macos_install <method>: install one missing package.
macos_install() {
  case "$1" in
    brew:*) step brew install --formula "${1#brew:}" ;;
    cask:*) step brew install --cask "${1#cask:}" ;;
    os) warn 'shipped with macOS; install the Xcode Command Line Tools with xcode-select --install'; return 1 ;;
    *) die "unknown macOS install method: $1" ;;
  esac
}
