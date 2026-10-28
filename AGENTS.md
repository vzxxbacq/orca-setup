# AGENTS.md

Guidance for agents and humans working in this repository.

## Language

- **Repository content is English.** Code, comments, commit messages, documentation, test names, file names and any generated artifact are written in English.
- **Conversation is Chinese (Simplified).** Chat replies, progress updates and questions to the project owner are in Chinese. This applies to the conversation only, never to files in the repository.

## Project

`orca-setup` prepares macOS and Linux devices for Orca. Read [README.md](README.md) before changing anything.
For installation and management without the TUI, follow [AGENT-OPERATIONS.md](AGENT-OPERATIONS.md).
Numbered design notes and implementation history live in [DESIGN.md](DESIGN.md); consult the relevant section when changing behavior.

## Ground rules

- **Read-only by default.** Running with no arguments must only print what would happen (`--plan`).
- **Never run as root.** Refuse `sudo ./setup.sh`; optional modules and, on Linux, the baseline apt steps may call `sudo` internally when required, and `--plan` lists every such command.
- **Preserve existing installs.** Detect first and install only what is missing; do not upgrade tools that are already present.
- **Never handle credentials.** Do not import, copy, print or commit tokens, keys or passwords; all authentication is interactive on the target device.

## Conventions

- Bash scripts: `set -euo pipefail`, `shellcheck`-clean, quoted expansions, no hardcoded `orca` (resolve the CLI name through `lib/detect.sh`).
- Tool inventories belong in `manifest/` — never duplicate per-platform package lists inside scripts.
- Tests: bats for unit tests, the Docker matrix for Linux integration.
- Keep documentation in sync with behaviour. Keep `README.md` short and user-facing; put command-line procedures in `AGENT-OPERATIONS.md` and implementation details in `DESIGN.md`.
