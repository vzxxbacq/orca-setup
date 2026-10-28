#!/usr/bin/env bash
# Initialize only missing user files; existing shell customizations are authoritative.
set -euo pipefail
if [ ! -e "$HOME/.zshrc" ] && [ ! -L "$HOME/.zshrc" ] && [ -r /opt/oh-my-zsh/oh-my-zsh.sh ]; then
  (umask 077; set -C; cat > "$HOME/.zshrc" <<'RC'
# Orca container defaults. This file and custom plugins persist in your HOME.
if [[ -r /opt/oh-my-zsh/oh-my-zsh.sh ]]; then
export ZSH=/opt/oh-my-zsh
export ZSH_CUSTOM="$HOME/.config/oh-my-zsh/custom"
export ZSH_CACHE_DIR="$HOME/.cache/oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git)
zstyle ':omz:update' mode disabled
mkdir -p "$ZSH_CUSTOM" "$ZSH_CACHE_DIR"
source "$ZSH/oh-my-zsh.sh"
fi
HISTFILE="$HOME/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000
setopt INC_APPEND_HISTORY
RC
  ) || [ -f "$HOME/.zshrc" ]
fi
