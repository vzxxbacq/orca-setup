# shellcheck shell=bash
# npm global tools, always installed user-level under ~/.local (never into the Node prefix).

npm_prefix() { printf '%s\n' "$HOME/.local"; }

# npm_install <package>: install the latest release of one package with its optional native dependencies.
npm_install() {
  have npm || die "npm is required to install $1; install the baseline first."
  step npm install --global --prefix "$(npm_prefix)" --include=optional "$1@latest"
}
