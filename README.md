# orca-setup — PLAN

> Status: **P0 implemented (macOS parity)**; Linux is detected but not provisioned yet (P1/P2).
> Goal: turn a new device (macOS or **Linux**) into a usable Orca development machine with one set of scripts.
> Origin: generalized from a set of macOS-only scripts (`setup-mini.sh`, `install-agy.sh`, `orca-rpc.{sh,cjs}`,
> `audit-readiness.cjs`) written for migrating one Mac to another.
> License: [MIT](LICENSE). This repository is public: never commit host names, internal URLs, addresses or credentials.

---

## 0. Usage (P0)

```sh
./setup.sh                          # same as --plan: print what would happen on this device, change nothing
./setup.sh --check                  # read-only readiness report; exit code = number of missing items
./setup.sh --apply --role server    # install what is missing, Orca skills and defaults (role is required)
./setup.sh --apply --role server --power --media      # plus optional modules
./setup.sh --apply --role client --task-source linear # plus Linear as Orca's task source (opt-in)
./setup.sh --auth-gh                # interactive logins, one or more per run: gh codex claude agy linear
```

- Optional modules (`--power --containers --apple --android --media --agent-gemini`) only run together with
  `--apply`; with `--plan` (or no mode) they are shown in detail. They never run on their own.
- `--auth-*` flags are their own mode and cannot be combined with `--plan`, `--apply` or `--check`.
- Run as your regular user; `sudo ./setup.sh` is refused. Only `--power` and `--apple` call `sudo` themselves.
- On Linux, P0 only prints detection results and states that provisioning is not implemented yet.

---

## 1. Goals and non-goals

**Goals**

1. A single entry command that, on macOS (arm64/x86_64) and Linux (Ubuntu 24.04 / Debian 12, **x86_64 only**):
   - installs the baseline development toolchain;
   - installs and configures Orca (on Linux primarily as a headless runtime), Orca skills and Orca default settings;
   - walks the user through logging in to each agent / platform (no credentials imported or printed);
   - prints a read-only readiness report (`--check`) that doubles as the acceptance criterion.
2. Once the new device is paired, it can be driven remotely from a control machine with
   `orca --environment <name>`: create projects, open worktrees, start agents.
3. Idempotent: re-running never breaks an existing install or user configuration.

**Non-goals**

- No SSH configuration (following the existing rule: `SSH is never configured`).
- No migration or copying of credentials, tokens or private keys; all authentication happens interactively on the target device.
- No project data migration; only extension points are reserved.
- No organization-specific integrations (internal Git hosts, VPNs, mirrors) in this repository; those go in a local, untracked overlay (§3.7).
- No Linux arm64.
- No network setup: the private route between client and server (Tailscale, LAN, WireGuard) is the user's job; `setup.sh` only takes the address to advertise.
- No Fedora/RHEL for now (`pkg-fedora.sh` stays a placeholder).
- No Windows / WSL for now (revisit later).

---

## 2. Design principles (inherited from setup-mini.sh)

| Principle | How it is implemented |
|---|---|
| Read-only by default | no arguments = `--plan`, which only prints what would happen |
| Run as non-root | check `id -u`, refuse `sudo ./setup.sh`; only explicit modules (`--power` etc.) call `sudo` internally when needed |
| Preserve existing installs | detect first (`command -v` / package-manager query), install only when missing; never upgrade existing versions |
| No credential leakage | `umask 077`; the audit prints booleans/names only, never values |
| npm first | agent CLIs are installed from npm whenever a package exists; vendor installers only when there is none |
| User-level first | npm global tools go to `~/.local` (`npm --prefix ~/.local`); PATH always includes `~/.local/bin` |
| Single source of truth | tool lists live in `manifest/` and are read per platform, so the macOS and Linux lists cannot drift |
| One pairing role per host | every device is either a client or a server, never both (§5.1) |

---

## 3. What a device needs (component inventory)

### 3.1 Baseline tools (installed by `--apply`)

| Tool | Purpose | macOS install | Linux install (planned) |
|---|---|---|---|
| git, git-lfs | version control | brew | apt/dnf |
| gh | GitHub CLI / authentication | brew | official GitHub apt repo |
| ripgrep, jq, tmux, cmake, pkg-config | general dev/agent dependencies | brew (`pkgconf`) | apt (`ripgrep jq tmux cmake pkg-config build-essential`) |
| Node.js 24 | agent CLIs, pnpm projects | brew `node@24` | NodeSource 24.x apt repo |
| pnpm | JS projects | npm → `~/.local` | same |
| Python 3.12 + uv + ruff | Python projects | brew `python@3.12 uv ruff` | official uv installer → `uv python install 3.12`; `uv tool install ruff` |
| curl, unzip, ca-certificates | installer dependencies | shipped with the OS | apt |

### 3.2 Agent CLIs

All agents below are baseline (installed by `--apply`) unless marked optional. npm packages go to `~/.local`
(`npm --prefix ~/.local`) on both platforms. An agent that is already installed some other way (for example a Homebrew
cask) is detected and left alone.

| Agent | Baseline | Install (macOS and Linux) | Login |
|---|---|---|---|
| Codex (`codex`) | yes | npm `@openai/codex` | `orca account add --agent codex` (device auth, completable in a browser on another machine) |
| Claude Code (`claude`) | yes | npm `@anthropic-ai/claude-code` | `orca account add --agent claude` |
| DeepSeek (`dsh`, `dsh-tui`) | yes | npm `@deepseek-ai/dsh`, `@deepseek-harness-tui/dsh-tui` | configured individually (the audit only checks whether it is configured) |
| Pi (`pi`) | yes | npm `@earendil-works/pi-coding-agent` (needs Node ≥ 22.19) | run `pi` interactively |
| OMP (`omp`) | yes | npm `@oh-my-pi/pi-coding-agent`; needs Bun ≥ 1.3.14, installed from npm `bun` | run `omp` interactively |
| Grok (`grok`) | yes | no npm package: official installer `curl -fsSL https://x.ai/cli/install.sh \| bash` (installs under `~/.grok`) | run `grok` and sign in in the browser |
| Antigravity (`agy`) | yes | no npm package: official `install.sh` (**Linux support to be confirmed**) | run `agy` interactively and sign in to Google |
| Gemini (`gemini`) | **optional** (`--agent-gemini`) | npm `@google/gemini-cli` | not usable with personal accounts, so it is never installed by default |

Package names are recorded in `manifest/agents.tsv`, not in scripts.

### 3.3 Orca

| Item | macOS | Linux |
|---|---|---|
| Orca itself | `/Applications/Orca.app` (desktop; Homebrew cask `stablyai/orca/orca` when missing) | **headless runtime**: the official `.deb` from the latest GitHub release (`orca-ide_<version>_amd64.deb`, installed with `sudo apt install ./<file>`); see §3.3.1 |
| CLI name | `orca` | `orca` inside the Orca terminal; **outside the Orca terminal you must use `orca-ide`** (bare `orca` is the GNOME screen reader). Scripts resolve it uniformly via `ORCA_CLI_COMMAND` / probing |
| Always-on | desktop app login item | systemd **user unit**: `orca-ide serve --supervise --port 6768 --pairing-address <LAN/Tailscale IP>` together with `loginctl enable-linger $USER` so it survives logout |
| Pairing | Settings → Remote Orca Servers → New Link | `orca-ide serve` prints a runtime pairing URL (`--mobile-pairing` for the phone app) |
| Accounts | `orca account add --agent claude\|codex` | same, run from the server shell (a remote client cannot add accounts) |
| Skills | `orca skills install --skill orca-cli --skill orca-linear --skill computer-use --skill orca-emulator --agent universal,claude-code,codex`, listed in `manifest/orca-skills.tsv`; skipped when `orca skills installed` already lists them | same, minus `orca-emulator` (the iOS simulator is macOS-only); `computer-use` support on Linux is to be verified |
| Default settings | written through `orca-rpc settings.update` from `manifest/orca-settings.json`: `defaultTuiAgent=codex`, `agentStatusHooksEnabled=true`; the task source is **opt-in** (`--task-source linear` sets `defaultTaskSource=linear` and `visibleTaskProviders=[linear]`). `--apply` reads `settings.get` first and writes only when a key differs | same |
| Resource limits (optional) | none | `ORCA_TERMINAL_PROCESS_CEILING` / `ORCA_TERMINAL_MEMORY_MAX` / `ORCA_TERMINAL_MEMORY_SWAP_MAX` in the systemd unit's `Environment=` (needs cgroup v2 and linger) |

#### 3.3.1 Orca on headless Linux (from the upstream docs)

Source: `docs/site/content/docs/install.mdx` and `remote-servers.mdx` in [stablyai/orca](https://github.com/stablyai/orca).

- **Package**: each release ships an AppImage, a `.deb` and an `.rpm`. The `.deb` is used here because it puts
  `orca-ide` on `PATH` (`/usr/bin/orca-ide`) at install time; the AppImage can only register its CLI from the desktop
  Settings UI, which a headless host does not have. The file name carries the version, so the script resolves it
  through the GitHub releases API instead of a fixed URL.
- **Updates**: the `.deb` does not self-update and there is no apt repository yet (upstream #18086). Orca downloads the
  new package to `~/.cache/orca-updater/pending/` and offers an install command; `setup.sh` never upgrades an existing
  install (ground rule), it only reports the available version in `--check`.
- **Runtime**: `orca-ide serve` runs on Orca's own Node server (orcad), so no display is needed. A packaged serve writes a
  bare `orca` shim into `~/.local/bin` as it starts, but the first launch must always use `orca-ide`.
- **Network**: bind the pairing address to a private route (Tailscale `100.x`, LAN, WireGuard); never `127.0.0.1` and
  never a port forwarded to the public internet.
- **Credentials**: integration credentials (Linear etc.) are sealed with a per-machine key in `~/.orca`; GitHub tokens
  stay in `gh`. Nothing for this repository to handle.
- **Single host mode**: never run `orca-ide serve` next to a desktop app that already shares the same machine.

### 3.4 Authentication (all interactive, run on demand)

| Mode | What it does | Cross-platform notes |
|---|---|---|
| `--auth-gh` | `gh auth login --web` (skipped when already logged in) | use the device-code flow when Linux has no desktop |
| `--auth-codex` | `orca account add --agent codex` (skipped when a Codex account is already selected) | device auth, works headless by design |
| `--auth-claude` | `orca account add --agent claude` (skipped when a Claude account is already selected) | headless requires a browser or copying the URL |
| `--auth-agy` | run `agy` to sign in | TBD |
| `--auth-linear` | open the Linear API settings page, silently read the key and write it into Orca | macOS `open` → Linux `xdg-open`; headless just prints the URL |

Further auth modes (for example a self-hosted Git server) are added through the local overlay (§3.7), not in this repository.

### 3.5 Optional modules

Modules are selected on the command line and run only with `--apply`; their packages live in the matching group of
`manifest/baseline.tsv` / `manifest/agents.tsv`, and extra steps (pmset, Xcode, opening Docker) in `modules/<name>.sh`.

| Module | macOS | Linux |
|---|---|---|
| `--power` no sleep + restart after power loss | `sudo pmset -c sleep 0 autorestart 1` | `sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target`; restart-after-power-loss must be set in the BIOS by hand (the script only reminds you) |
| `--containers` | Docker Desktop (cask) | official Docker Engine apt repo + add the user to the `docker` group |
| `--apple` | xcodegen / xcbeautify / xcodes + Xcode first launch | not applicable (skip with a notice) |
| `--android` | android-platform-tools (cask) | apt `android-sdk-platform-tools` or Google's official zip |
| `--media` | poppler ffmpeg sevenzip marksman | apt `poppler-utils ffmpeg p7zip-full`; marksman from a GitHub release binary |
| `--agent-gemini` | npm `@google/gemini-cli` | same |
| `--gpu` *(P4)* | not applicable | NVIDIA driver / CUDA detection only, never installs anything |

### 3.6 Readiness audit (`--check`)

- Port `audit-readiness.cjs`: booleans/names only; covers whether env vars exist, auth and MCP names for claude/gemini/dsh/pi/codex, and cloud configs (gcloud/aws/azure/docker/npm).
- Add: a `PRESENT/MISSING` tool list, versions (node/pnpm/python/uv), Orca runtime reachability, whether the Orca accounts (codex/claude) are selected, whether Linear is connected (only when `--task-source linear` was chosen), whether gh is logged in, the pairing role check (§5.1); on Linux also the systemd user unit state and linger.
- Exit code = number of missing items, usable directly as an acceptance condition. Counted: `MISSING` tools and
  agents from the manifest, a missing Orca CLI, an unreachable Orca runtime, missing Orca skills, a `PENDING` GitHub
  login or Codex account, Linear when `--task-source linear` is given, and a pairing role conflict (dual role, or the
  other role than `--role`) or an unknown role (unreadable pairing stores). Reported but not counted: versions, the Claude account, Orca settings that differ from the
  manifest, Linear when only Orca's settings select it, and the `READINESS_JSON` audit line.

### 3.7 Local overlay (untracked)

Organization- or device-specific settings live in `manifest/local/` (git-ignored): extra packages, extra auth modules,
mirrors, internal hosts. `setup.sh` merges the overlay on top of `manifest/` when it exists. The repository only ships
`manifest/local.example/` with placeholder values.

Merge rules: a TSV row in `manifest/local/<file>.tsv` whose first column matches a shipped row replaces it in place;
other rows are appended. `manifest/local/orca-settings.json` is deep-merged over the shipped file (objects merge,
values and arrays replace). Overlay auth modules are not implemented yet.

---

## 4. Repository layout

```
orca-setup/
├── README.md                    # this PLAN
├── AGENTS.md                    # repository conventions (language, style, ground rules)
├── LICENSE                      # MIT
├── setup.sh                     # single entry: --plan | --apply | --check | --auth-* | --role | modules
├── lib/
│   ├── common.sh                # logging, non-root check, umask, PATH, idempotency helpers
│   ├── detect.sh                # OS / distro / arch / package manager / desktop presence / orca CLI name
│   ├── manifest.sh              # manifest parsing and local overlay merge
│   ├── json.cjs                 # JSON helpers for the shell (names/booleans only)
│   ├── pkg-macos.sh             # brew formulae / casks
│   ├── pkg-debian.sh            # (P1) apt (incl. third-party repos: gh, NodeSource, Docker)
│   ├── pkg-fedora.sh            # (later) dnf placeholder
│   └── npm-tools.sh             # npm global tools under ~/.local
├── manifest/
│   ├── baseline.tsv             # tool → per-platform package/install method (single source of truth)
│   ├── agents.tsv               # agent CLI inventory (baseline / optional, per-platform support)
│   ├── orca-skills.tsv          # Orca skills per platform and their install targets
│   ├── orca-settings.json       # Orca default settings and opt-in task sources
│   └── local.example/           # placeholder overlay; the real manifest/local/ is git-ignored
├── modules/                     # power / containers / apple / android / media / agent-gemini (gpu, orca-runtime later)
├── auth/                        # gh / codex / claude / agy / linear (+ linear-login.cjs hidden prompt)
├── orca/
│   ├── orca-rpc.sh              # locate the Orca executable per platform (ORCA_APP_PATH), ELECTRON_RUN_AS_NODE
│   ├── orca-rpc.cjs             # reuse Orca's bundled RuntimeClient (never exports the pairing key)
│   ├── role.sh                  # pairing role check (§5.1); picks node or Orca's bundled runtime
│   ├── role.cjs                 # role logic: reads the pairing stores, never prints secrets
│   └── systemd/orca-serve.service  # (P2)
├── audit/readiness.cjs          # read-only audit
├── remote/provision.sh          # (P4) push and run from the control machine (§5)
└── tests/
    ├── bats/                    # unit tests (detect, manifest, role, readiness, --plan snapshots, static checks)
    └── docker/                  # (P1) Linux matrix: ubuntu:24.04, debian:12 (amd64)
```

---

## 5. New-device onboarding flow (target shape)

```
[new device, role: server]                    [control machine, role: client]

0. Install Orca (macOS desktop / Linux headless)

1. Generate a pairing code
   (desktop Settings or `orca serve`)  ──►   orca environment add --name <device> --pairing-code <code>
                                             orca status --environment <device>

2.                                      ◄──   orca project setup-clone --project <orca-setup project id>
                                               --host runtime:<environment-id> --url https://github.com/vzxxbacq/orca-setup
                                               --destination <home>/orca/projects

3.                                      ◄──   run in an orca-setup workspace terminal:
                                               ./setup.sh --plan --role server  →  ./setup.sh --apply --role server

4. Complete each `--auth-*` interactively on the device (or through an Orca terminal)

5.                                      ◄──   ./setup.sh --check   (exit code 0 = ready)

6.                                      ◄──   orca worktree create --environment <device> --project <x> --agent codex ...
```

- Steps 0–1 cannot be done remotely; they must happen locally on the device, so the README will list them as a "manual checklist".
- The repository is public, so step 2 needs no Git credentials on the device.

### 5.1 Pairing roles

Orca pairing is one-way: only a **client** (a host that saved a server pairing with `orca environment add`) can call a
**server**. A host that is both a client and a server relays editor tabs between its peers; with desktops paired both
ways, tabs multiply and end up bound to the wrong host. Rule: **every host has exactly one role.**

| Role | Saves environments (dials) | Accepts runtime pairings (is dialed) |
|---|---|---|
| `client` | yes, the servers it needs | no |
| `server` | no | yes, from its clients |

- `setup.sh --role client|server` is required for `--apply`; `--plan` shows what the role implies.
- `--role server` never runs `orca environment add`; `--role client` never prints a runtime pairing code.
- `--apply` refuses to continue when the device already holds the other role (saved environments on a server, or
  runtime clients seen recently on a client) and names the pairings to remove. Mobile pairings do not count.
- `--check` reports the current role and flags a dual role.
- How the role is read (`orca/role.sh`, read-only): saved environments come from `orca environment list --json`
  (falling back to `orca-environments.json`); runtime clients come from the device registry `orca-devices.json` in
  Orca's user-data directory. That directory follows upstream orcad: `$ORCA_USER_DATA` when set; on macOS
  `~/Library/Application Support/Orca`; on Linux `$XDG_DATA_HOME/Orca`, else `~/.orca` (headless runtime), with the
  Electron desktop path `${XDG_CONFIG_HOME:-~/.config}/Orca` as a second candidate (the first candidate holding a
  pairing store wins). Only each entry's scope, name and last-seen time are used; tokens and device ids are never
  printed. "Recently" means within the last 30 days (`ORCA_SETUP_RECENT_DAYS`). Names are printed only on a conflict.
- The check fails closed. It runs on Node.js, or on Orca's bundled runtime (`ELECTRON_RUN_AS_NODE`) when Node.js is not
  installed yet. When neither is available, or a pairing store exists but is not valid JSON or has an unexpected
  shape, it reports `ROLE unknown` with the reason: `--apply` refuses and `--check` counts
  `Pairing role check: UNREACHABLE`.

---

## 6. Implementation phases

| Phase | Scope | Done when |
|---|---|---|
| **P0 Skeleton + macOS parity** | `setup.sh` entry, `lib/common.sh`, `lib/detect.sh`, `manifest/`, `--role`; port every mode from setup-mini.sh | on the reference Mac, `--plan` output matches setup-mini.sh; `--check` results do not regress |
| **P1 Linux baseline** | `pkg-debian.sh`, user-level npm/uv installs, PATH written to `~/.profile`/`~/.zshrc` | in Docker, `ubuntu:24.04` and `debian:12` run `--apply` twice successfully (idempotent); `--check` reports only auth items |
| **P2 Orca on Linux** | install the headless runtime, `orca-ide` detection, systemd user unit + linger, skills, default settings, cross-platform `orca-rpc` | a real Linux machine / VM can be paired from the control machine with `orca environment add` and can `worktree create --agent codex` remotely |
| **P3 Auth + optional modules** | headless adaptations for `auth/*` (xdg-open / print URL), Linux versions of `--power`, `--containers`, `--media`, `--android`, `--agent-gemini` | each module has clear `--plan` output on Linux and `--apply` is re-entrant |
| **P4 Remote provisioning + extensions** | `remote/provision.sh` (wrapping §5 steps 2–5), `--gpu` detection, audit enhancements | a single command from the control machine takes a new device from "paired" to "all green except interactive auth" |

### 6.1 P0 port notes (differences from setup-mini.sh)

- `--agy` is gone: agy is a baseline agent installed by `--apply`.
- Optional modules run only together with `--apply` (setup-mini ran `--power`, `--apple` … immediately).
- `--apply` requires `--role` and refuses a dual role before changing anything.
- New baseline items from §3.1/§3.2: git-lfs, the Orca app itself, bun, omp, grok; Codex comes from npm (an existing
  Homebrew cask install is detected and kept).
- The Linear task source is opt-in (`--task-source linear`); setup-mini always set it.
- Orca skills and settings are skipped when already in place; `--auth-claude` is skipped when an account is selected.
- `--check` counts GitHub, Codex and role problems in its exit code, and also prints the `READINESS_JSON` audit.

---

## 7. Test strategy

- **Static**: `shellcheck` every `*.sh`; `node --check` every `*.cjs`.
- **Unit**: bats tests for `detect.sh` (fake `/etc/os-release`, `uname`), manifest parsing, role checks and `--plan` output snapshots.
  Run `bats tests/bats`; every test runs in a sandbox whose `PATH` holds only fakes and a few core utilities. Refresh
  snapshots with `UPDATE_SNAPSHOTS=1 bats tests/bats/plan.bats` and review the diff.
- **Linux integration**: Docker matrix (ubuntu:24.04 / debian:12, amd64), running `--apply` twice plus `--check`; systemd pieces verified on a real VM.
- **macOS regression**: on an already provisioned Mac run only `--plan` / `--check` (no re-installs).
- **Security regression**: grep the audit output to ensure no token/key-shaped strings; CI fails on host names, private IPs or internal URLs in tracked files.

---

## 8. Risks

| Risk | Mitigation |
|---|---|
| `orca-rpc.cjs` depends on Orca internals (`out/cli/runtime-client.js`) and RPC method names (`settings.update`, `accounts.list`, `linear.status`, `files.writeBase64`), which may change between versions | use the public CLI wherever possible; keep all RPC calls under `orca/`; `--check` fails loudly instead of silently when a probe fails |
| On Linux, `orca` collides with the GNOME screen reader | `detect.sh` resolves the CLI name in one place; scripts must never hardcode `orca` |
| Support for `agy`, `computer-use` etc. on Linux is uncertain | verify feasibility before P2/P3; mark them macOS-only in the manifest if unsupported |
| Browser login on headless Linux | prefer device-code flows (codex, gh); otherwise print a URL for the user to finish on any machine |
| GPG key management for third-party apt repos (NodeSource / gh / Docker) | use `/etc/apt/keyrings/` + `signed-by=`, and record key fingerprints in the manifest for verification |
| No public CLI lists the runtime clients paired with a host, so `orca/role.sh` reads Orca's device registry file | read only scope/name/last-seen; never print tokens; fail closed (`ROLE unknown`) when the file does not parse or has an unexpected shape; covered by bats tests with fake registries; switch to a CLI once one exists |
| Dual pairing roles corrupt editor tabs across hosts | `--role` is mandatory for `--apply`; preflight refuses a dual role (§5.1) |
| Private details leak into the public repository | local overlay for anything organization-specific; CI leak check (§7) |

---

## 9. Decisions and open questions

**Decided (2026-10-24)**

| Topic | Decision |
|---|---|
| Repo hosting | public GitHub repository `vzxxbacq/orca-setup`, MIT license |
| Organization-specific integrations | not in this repository; local overlay only (§3.7) |
| Pairing role | chosen per device with `--role client\|server` (§5.1) |
| Linux form factor | headless server first (`orca serve` + systemd user unit, driven remotely) |
| Agent baseline | codex, claude, dsh, agy, pi, grok, omp; gemini is optional (not usable with personal accounts) |
| Task source | opt-in (`--task-source linear`); not set by default |
| Node on Linux | NodeSource 24.x apt repo |
| Containers on Linux | Docker Engine |
| GPU | detection only, in P4 |
| Linux architecture | x86_64 only; no arm64 |
| Network | not managed by `setup.sh`; the user provides the private route and passes the address to advertise |
| Fedora/RHEL | not now; `pkg-fedora.sh` is kept as a placeholder |
| Agent install source | npm whenever a package exists (§3.2); grok and agy use their official installers |
| Orca on Linux | official `.deb` from GitHub releases, run as `orca-ide serve --supervise` under a systemd user unit (§3.3.1) |

**Open**

1. **Linux support** of `agy` and `computer-use`: to be verified on a real machine in P2.

---

## 10. References

- Original macOS scripts this plan generalizes: `setup-mini.sh`, `install-agy.sh`, `orca-rpc.sh`, `orca-rpc.cjs`, `audit-readiness.cjs`, `linear-login.cjs` (kept outside this repository).
- Orca CLI: `orca serve` (`--supervise` adapts to launchd/systemd), `orca environment add`, `orca project setup-clone`, `orca skills install`, `orca account add`, `orca vm recipe doctor` (`environmentRecipes` in `orca.yaml`, a possible direction for VM automation after P4).
- Repository conventions (language, style, ground rules): [`AGENTS.md`](AGENTS.md).
