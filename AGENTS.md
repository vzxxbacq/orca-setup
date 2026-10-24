# AGENTS.md

Guidance for agents and humans working in this repository.

## Language

- **Repository content is English.** Code, comments, commit messages, documentation, test names, file names and any generated artifact are written in English.
- **Conversation is Chinese (Simplified).** Chat replies, progress updates and questions to the project owner are in Chinese. This applies to the conversation only, never to files in the repository.

## Project

`orca-setup` turns a fresh macOS or Linux device into a ready-to-use Orca development machine with a single set of scripts. The design plan lives in [README.md](README.md); read it before changing anything.

## Ground rules

- **Read-only by default.** Running with no arguments must only print what would happen (`--plan`).
- **Never run as root.** Refuse `sudo ./setup.sh`; optional modules may call `sudo` internally when required.
- **Preserve existing installs.** Detect first and install only what is missing; do not upgrade tools that are already present.
- **Never handle credentials.** Do not import, copy, print or commit tokens, keys or passwords; all authentication is interactive on the target device.

## Conventions

- Bash scripts: `set -euo pipefail`, `shellcheck`-clean, quoted expansions, no hardcoded `orca` (resolve the CLI name through `lib/detect.sh`).
- Tool inventories belong in `manifest/` — never duplicate per-platform package lists inside scripts.
- Tests: bats for unit tests, the Docker matrix for Linux integration.
- Keep documentation in sync with behaviour; update the relevant section of `README.md` in the same change.
