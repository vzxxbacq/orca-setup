# orca-setup — PLAN

> Status: **P0–P5 implemented**: macOS parity, the Linux baseline, Orca on Linux, auth and optional modules on Linux,
> remote provisioning from a client, and (P5, §6.7) the Linux server in a Docker container with its work, Orca data
> and agent login directories mounted from the host; the native Linux server (systemd user unit) is gone. Real-device
> acceptance is **pending**; the checklist in §6.6 runs all of it in one session.
> Goal: turn a new device (macOS or **Linux**) into a usable Orca development machine with one set of scripts.
> Origin: generalized from a set of macOS-only scripts (`setup-mini.sh`, `install-agy.sh`, `orca-rpc.{sh,cjs}`,
> `audit-readiness.cjs`) written for migrating one Mac to another.
> License: [MIT](LICENSE). This repository is public: never commit host names, internal URLs, addresses or credentials.

---

## 0. Usage

```sh
./setup.sh                          # same as --plan: print what would happen on this device, change nothing
./setup.sh --check                  # read-only readiness report; exit code = number of missing items
./setup.sh --apply --role server    # install what is missing, Orca skills and defaults (role is required)
./setup.sh --apply --role server --pairing-address <ip-or-host>   # Linux server: Docker Engine + the orca-server container
./setup.sh --apply --role server --pairing-address <ip-or-host> --workdir /srv/orca   # projects/ and workspaces/ there
./setup.sh --apply --role server --pairing-address <ip-or-host> --upgrade-image       # Linux server: newest image
./setup.sh --apply --role server --power --media      # plus optional modules
./setup.sh --check --media          # readiness, counting the given modules' items too
./setup.sh --check --json           # the same report as one JSON document (names, states, counts; never values)
./setup.sh --plan --gpu             # Linux: report the NVIDIA GPU, driver and CUDA (detection only, never installs)
./setup.sh --apply --role client --task-source linear # plus Linear as Orca's task source (opt-in)
./setup.sh --auth-gh                # interactive logins, one or more per run: gh codex claude agy linear
```

From the control machine (pairing role client), for a device saved with `orca environment add` (§5.2):

```sh
remote/provision.sh --environment <name>                       # read-only: runs only ./setup.sh --plan on the device
remote/provision.sh --environment <name> --apply --pairing-address <ip-or-host> --destination <dir-on-device>
remote/provision.sh --environment <name> --check               # exit code = the device's missing items
```

- Optional modules (`--power --containers --apple --android --media --agent-gemini --gpu`) only install together with
  `--apply`; with `--plan` (or no mode) they are shown in detail, and `--check` counts their items. They never run
  on their own, and a module that does not apply to the device (`--apple` on Linux, for example) is skipped with a
  notice, not an error.
- `--auth-*` flags are their own mode and cannot be combined with `--plan`, `--apply` or `--check`.
- Run as your regular user; `sudo ./setup.sh` is refused. On macOS only `--power` and `--apple` call `sudo`
  themselves; on Linux the baseline apt steps of a client (packages, repository keys and source lists, the Orca
  `.deb`), the Docker Engine apt steps and `usermod -aG docker` of a server, and the modules' apt steps,
  `systemctl mask` (`--power`) and `usermod -aG docker` (`--containers`) run through `sudo`, and `--plan` prints every
  one of those commands. `docker` itself never runs through `sudo`: in the run that adds the user to the docker group
  it runs through `sg docker`, which asks for nothing (§3.3.2).
- On Linux (Ubuntu 24.04 / Debian 12, x86_64; anything else is refused) `--apply --role client` installs the
  baseline tools, agents and Orca's `.deb` and writes the PATH block (§3.1). `--apply --role server` installs only
  Docker Engine on the host and runs Orca and every agent in the `orca-server` container from
  `ghcr.io/vzxxbacq/orca-server` (§3.3.2, §6.7). The optional modules have Linux versions (§3.5), and every
  `--auth-*` works headless (§3.4); on a server the logins run inside the container.
- `--pairing-address` is required for `--apply --role server` on Linux and refused anywhere else (macOS picks the
  address in Orca's Settings; a client never advertises one). `--workdir` and `--upgrade-image` are for Linux servers
  only.

---

## 1. Goals and non-goals

**Goals**

1. A single entry command that, on macOS (arm64/x86_64) and Linux (Ubuntu 24.04 / Debian 12, **x86_64 only**):
   - installs the baseline development toolchain;
   - installs and configures Orca (on Linux primarily as a headless runtime, which a Linux server runs in a Docker
     container), Orca skills and Orca default settings;
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
| Run as non-root | check `id -u`, refuse `sudo ./setup.sh`; `sudo` is called internally only where root is required: on Linux the apt steps (packages, repository keys, source lists) and a server's docker group, on both platforms explicit modules (`--power`, `--containers` etc.); `--plan` lists every such command. The Orca server container runs as the user, without `sudo` or Docker inside |
| Preserve existing installs | detect first (`command -v` / package-manager query), install only when missing; never upgrade existing versions |
| No credential leakage | `umask 077`; the audit prints booleans/names only, never values; the Linear key is read without echo and goes only to Orca |
| npm first | agent CLIs are installed from npm whenever a package exists; vendor installers only when there is none |
| User-level first | npm global tools go to `~/.local` (`npm --prefix ~/.local`); PATH always includes `~/.local/bin`, and on Linux `--apply` persists it in `~/.profile` and `~/.zshrc` |
| Single source of truth | tool lists live in `manifest/` and are read per platform, so the macOS and Linux lists cannot drift; module packages, repositories and the packages that mark a foreign install too |
| Verify every download | apt keys must match the fingerprints in `manifest/apt-repos.tsv`; GitHub release files (the Orca `.deb`, marksman) must match GitHub's sha256 digest; the Orca server image is pinned by its registry digest (`image.lock`) and published with a build provenance attestation |
| One pairing role per host | every device is either a client or a server, never both (§5.1) |

---

## 3. What a device needs (component inventory)

### 3.1 Baseline tools (installed by `--apply`)

| Tool | Purpose | macOS install | Linux install (Ubuntu 24.04 / Debian 12) |
|---|---|---|---|
| git, git-lfs | version control | brew | apt |
| gh | GitHub CLI / authentication | brew | official GitHub CLI apt repo |
| ripgrep, jq, tmux, cmake, pkg-config | general dev/agent dependencies | brew (`pkgconf`) | apt (`ripgrep jq tmux cmake pkg-config build-essential`) |
| Node.js 24 | agent CLIs, pnpm projects | brew `node@24` | NodeSource 24.x apt repo |
| pnpm | JS projects | npm → `~/.local` | same |
| Python 3.12 + uv + ruff | Python projects | brew `python@3.12 uv ruff` | official uv installer → `uv python install 3.12`; `uv tool install ruff` |
| curl, unzip, ca-certificates | installer dependencies | shipped with the OS | apt |
| gnupg | verifies the apt repository keys | not needed | apt |

Linux notes:

- `--apply` installs in this order: distribution packages (one `apt-get update` first), then the third-party apt
  repositories (GitHub CLI, NodeSource 24.x) and their packages, then official installers (uv, grok, agy), npm
  packages, and finally `uv python install 3.12` and `uv tool install ruff`. Everything after the apt steps is
  user-level (`~/.local`); only the apt steps use `sudo`.
- Third-party repositories follow each vendor's own layout: the key goes to `/etc/apt/keyrings/` and the source list
  uses `signed-by=`. The expected primary-key fingerprints are recorded in `manifest/apt-repos.tsv`; a downloaded key
  is trusted only when every primary key in it is listed there, otherwise `--apply` stops before writing anything.
  A repository is only added when its package is missing. Docker Engine's repository belongs to `--containers`
  (§3.5); its URL and suite are per distribution (`{distro}`/`{codename}` in the manifest: `ubuntu`/`noble`,
  `debian`/`bookworm`).
- PATH: `--apply` appends a marked block (`# >>> orca-setup PATH >>>`) that puts `~/.local/bin` (npm, uv, uv tools,
  agy) and `~/.grok/bin` (grok) on PATH to `~/.profile` and `~/.zshrc` (created when missing), once, only when the
  block is not there yet. A bash login shell reads `~/.bash_profile` or `~/.bash_login` instead of `~/.profile` when
  one exists, so an existing one gets the block as well (P2; neither is ever created). The uv installer runs with `UV_NO_MODIFY_PATH=1`; grok's installer still adds its own block
  to the rc file of the user's shell, as on macOS.
- The pairing role check needs Node.js, which a fresh Linux device does not have, so `--apply` runs it after the
  baseline install and before any Orca step (on both platforms, §5.1).
- **A Linux server installs none of this on the host** (§3.3.2): the same rows (and the `--media`, `--android` and
  `--agent-gemini` modules, and the `image` rows of `manifest/baseline.tsv`, such as Xvfb) are installed into the Orca
  server image by `docker/build.sh`, through the same `lib/` code with the same key and digest checks. User-level
  tools go under the fixed prefix `/opt/orca-agents` there (it plays the user's home during the build, so its layout is
  `.local/bin` and `.grok/bin`); no PATH block is written for the image.

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
| Antigravity (`agy`) | yes | no npm package: official `install.sh` (installs into `~/.local/bin`; the installer supports Linux x86_64) | run `agy` interactively and sign in to Google |
| Gemini (`gemini`) | **optional** (`--agent-gemini`) | npm `@google/gemini-cli` | not usable with personal accounts, so it is never installed by default |

Package names are recorded in `manifest/agents.tsv`, not in scripts. Every baseline agent is installed on Linux x86_64
too; an agent whose installer does not support Linux would get `-` in the `debian` column (macOS-only). agy's
headless sign-in is described in §3.4.

### 3.3 Orca

| Item | macOS | Linux |
|---|---|---|
| Orca itself | `/Applications/Orca.app` (desktop; Homebrew cask `stablyai/orca/orca` when missing) | **headless runtime**: the official `.deb` from the latest stable GitHub release (`orca-ide_<version>_amd64.deb`), checked against GitHub's sha256 digest, then installed with `apt-get install <file>`; see §3.3.1. A client installs it on the host (`sudo`); a server has it in the Orca server image (§3.3.2) |
| CLI name | `orca` | `orca` inside the Orca terminal; **outside the Orca terminal you must use `orca-ide`** (bare `orca` is the GNOME screen reader). Scripts resolve it uniformly via `ORCA_CLI_COMMAND` / probing |
| Always-on | desktop app login item | `--role server`: the **`orca-server` container** (Docker Compose, `restart: unless-stopped`, so Docker brings it back after a reboot) running `orca-ide serve --supervise --no-pairing --port 6768 --pairing-address <address>` (§3.3.2); `--role client`: none |
| Pairing | Settings → Remote Orca Servers → New Link | the user stops the container and runs `orca-ide serve` in an interactive `docker compose run --rm` (§3.3.2); `setup.sh` never creates or prints a pairing link |
| Accounts | `orca account add --agent claude\|codex` | same, run on the server: inside the container, which `./setup.sh --auth-codex` on the host enters with `docker exec` (a remote client cannot add accounts) |
| Skills | `orca skills install --skill orca-cli --skill orca-linear --skill computer-use --skill orca-emulator --agent universal,claude-code,codex`, listed in `manifest/orca-skills.tsv`; a skill is skipped when the local plan of `orca skills install ... --dry-run --json` would write nothing for it (an older copy counts as installed: no upgrades), with `orca skills installed` (which needs a running runtime) as the fallback for builds whose dry-run prints no plan | same, minus `orca-emulator` (the iOS simulator is macOS-only). `computer-use` is installed: upstream ships a Linux helper (AT-SPI, `native/computer-use-linux`) and the `.deb` depends on `python3-gi`, `at-spi2-core`, `xdotool` and `xvfb`, but it drives apps in a graphical session, so a headless server has nothing to drive until an app runs on a display |
| Default settings | written through `orca-rpc settings.update` from `manifest/orca-settings.json`: `defaultTuiAgent=codex`, `agentStatusHooksEnabled=true`; the task source is **opt-in** (`--task-source linear` sets `defaultTaskSource=linear` and `visibleTaskProviders=[linear]`). `--apply` reads `settings.get` first and writes only when a key differs | same, through the `.deb`'s bundled runtime (`/opt/Orca/orca-ide` with `ELECTRON_RUN_AS_NODE`); a server's skills and settings are applied inside its container (`docker exec`) once the runtime answers; a client without a running Orca skips them with a notice |
| Workspace directory | Orca's own setting | a server's is Orca's default, `~/orca/workspaces`, which `--workdir` provides (§3.3.2) |
| Resource limits (optional) | none | a server's container limits (`mem_limit`, `memswap_limit`, `pids_limit`, `cpus`) from `manifest/local/server-limits.env` (git-ignored; keys and formats in `manifest/server-limits.env`), written into its `compose.yaml` |

#### 3.3.1 Orca on headless Linux (from the upstream docs)

Source: `docs/site/content/docs/install.mdx` and `remote-servers.mdx` in [stablyai/orca](https://github.com/stablyai/orca).

- **Package**: each release ships an AppImage, a `.deb` and an `.rpm`. The `.deb` is used here because it puts
  `orca-ide` on `PATH` (`/usr/bin/orca-ide`, a link to `/opt/Orca/resources/bin/orca-ide`) at install time; the
  AppImage can only register its CLI from the desktop Settings UI, which a headless host does not have. The file name
  carries the version, so the script resolves it through the GitHub releases API instead of a fixed URL.
- **Install** (`--apply`, only when `orca-ide` is missing): read `/repos/stablyai/orca/releases/latest` (GitHub never
  returns a draft or prerelease there, and the script refuses one anyway), require exactly one
  `orca-ide_<version>_amd64.deb` asset whose download URL belongs to that release, download it, and require the
  `sha256:` digest the API records for the asset (computed by GitHub when the asset was uploaded) plus the package's
  own control fields (`Package: orca-ide`, `Architecture: amd64`). Only then does
  `sudo apt-get install -y --no-install-recommends <file>` install it and its dependencies (GTK, NSS, AT-SPI, xvfb
  and others) on a client; the Orca server image build runs the same code as root (§6.7). A release without a digest is refused: there is no signed checksum file or apt repository to fall back
  to. The digest protects the download, not the release itself: it would not catch a malicious asset uploaded by
  someone holding the upstream release credentials.
- **Updates**: the `.deb` does not self-update and there is no apt repository yet (upstream #18086). Orca downloads the
  new package to `~/.cache/orca-updater/pending/` and offers an install command; `setup.sh` never upgrades an existing
  install (ground rule), it only reports the available version in `--check`. A server's Orca changes only with its
  image (`--upgrade-image`, §3.3.2).
- **Runtime**: `orca-ide serve` runs on Orca's own Node server (orcad), so no display is needed. A packaged serve writes a
  bare `orca` shim into `~/.local/bin` as it starts, but the first launch must always use `orca-ide`; the server
  container's command is `orca-ide serve ...`.
- **Supervision**: `--supervise` is upstream's mode for service managers: it restarts the server with growing delays
  and gives up (exit 0) after 6 failures in 15 minutes, after which Docker's `restart: unless-stopped` starts the
  container again. When its output is not a terminal, as in a container, upstream also hides any pairing URL from
  the log. Upstream's own `orca serve service install` writes a systemd unit; P5 replaced orca-setup's unit of that
  kind with the container (§6.7).
- **Network**: bind the pairing address to a private route (Tailscale `100.x`, LAN, WireGuard); never `127.0.0.1` and
  never a port forwarded to the public internet.
- **Credentials**: integration credentials (Linear etc.) are sealed with a per-machine key in `~/.orca`; GitHub tokens
  stay in `gh`. Nothing for this repository to handle.
- **Single host mode**: never run `orca-ide serve` next to a desktop app that already shares the same machine.

#### 3.3.2 Linux server (Docker) and client roles

`--apply --role server --pairing-address <address> [--workdir <dir>] [--upgrade-image]` on Linux (design: §6.7):

1. **Docker Engine.** A host without Docker gets Docker Engine from Docker's apt repository through the verified path
   of `--containers` (§3.5): the baseline rows `manifest/server-host.tsv` names (`curl`, `ca-certificates`, `gnupg`),
   then the `containers` rows. A working Docker installed any other way (CLI, reachable daemon, Compose plugin: Docker's
   convenience script, the distribution's packages, a CI runner) is used as it is and never changed. Podman (as the
   `docker` command or on its own), Docker packages without a `docker` command, a missing Compose plugin and a daemon
   that does not answer are refused with the reason. Nothing else is installed on the host: no Node.js, agents or
   Orca `.deb`.
2. **The docker group.** `sudo usermod -aG docker $USER` when the user is not a member; the group is root-equivalent
   (its members control the Docker daemon), and `--plan` says so. The running session only gets the group at its next
   login, so until then `setup.sh` runs `docker` through `sg docker`, which asks for nothing because the group
   database already lists the user (`NOTE docker runs through "sg docker" in this session`).
3. **Directories.** Every mount of `manifest/server-mounts.tsv`, created as the user when missing (an existing one
   must be a directory the user owns): the workdir (`--workdir`, else the one the last `--apply` recorded in
   `compose.yaml`, else `~/orca`) with `projects/` and `workspaces/`, `~/.orca` (Orca's user data: pairings, the device
   registry, sealed integration credentials), and the agents' directories `~/.codex`, `~/.claude`, `~/.config/gh`,
   `~/.gemini`, `~/.antigravity`, `~/.grok`, `~/.dsh`, `~/.dsh-tui`, `~/.pi` and `~/.omp`. Then the container's home
   `~/.local/share/orca-setup/home` (`$XDG_DATA_HOME` honoured) with the mount points inside it, so that Docker never
   creates one as root.
4. **The image.** The first `--apply` pulls `ghcr.io/vzxxbacq/orca-server:main` and records the digest it got in
   `~/.config/orca-setup/docker/image.lock` (`$XDG_CONFIG_HOME` honoured). Re-runs keep that digest (a locked image
   missing from the host is pulled by its digest, never by tag); only `--upgrade-image` pulls `main` again and, when
   its digest changed, locks the new one, which re-creates the container. `ORCA_SETUP_IMAGE` replaces the image
   reference for tests and CI only. With a `manifest/local/Dockerfile` (git-ignored; `ARG ORCA_SERVER_IMAGE` and
   `FROM ${ORCA_SERVER_IMAGE}`, see `manifest/local.example/Dockerfile.example`) the locked image is the base of a local
   `docker build`, whose result runs instead; it is built again when a file in `manifest/local/` or the base changes.
5. **The pairing role** (§5.1) is checked before the container starts, read-only inside the image
   (`docker run --rm --network none --read-only` with `~/.orca` mounted read-only), because the host has neither
   Node.js nor Orca.
6. **The container.** `docker/compose.yaml` is rendered into `~/.config/orca-setup/docker/compose.yaml` (written when it
   differs), and `docker compose up --detach` starts the container unless it already runs from that file (it carries
   a checksum of the file as its `org.orca-setup.config` label):
   - `network_mode: host` (port 6768 and the pairing address need no mapping), `restart: unless-stopped` (Docker
     brings it back after a reboot), `init: true`, `pull_policy: never`, and the command
     `orca-ide serve --supervise --no-pairing --port 6768 --pairing-address <address>`;
   - `user: <uid>:<gid>` of the user and `HOME` set to the user's home path; a read-only root filesystem with a tmpfs
     `/tmp`, every capability dropped and `no-new-privileges`; no `sudo` and no Docker in the image;
   - the container's home is `~/.local/share/orca-setup/home`, so a file written outside the mounts either persists
     there or fails (the root filesystem is read-only), and the mounts above are bind-mounted at the same absolute
     path (`create_host_path: false`: a missing directory is an error, never created as root).
7. It waits up to 120 s (`ORCA_SETUP_SERVE_WAIT`) until `orca-ide status --json` inside the container reports the
   runtime reachable (the reply is read there and never printed), then installs the missing skills and aligns the
   settings with `docker exec orca-server /opt/orca-setup/setup.sh --apply --role server`, the image's copy of these
   scripts.

A second run with the same arguments prints only `PRESENT` lines and the role report. `--pairing-address` is the
private IPv4 address or host name that clients dial (Tailscale, LAN, WireGuard; §1): loopback (`127.0.0.0/8`,
`localhost`), wildcard (`0.0.0.0`, `*`, `::`), broadcast and malformed values are refused. IPv6 literals are not
accepted; use a host name. The CI job on GitHub's runner advertises `127.0.0.2` through the test-only
`ORCA_SETUP_TEST_LOOPBACK_PAIRING_ADDRESS=1` (never `127.0.0.1`), because the runner has no private route; do not set
it on a real device. A systemd user unit `orca-serve.service` that an earlier orca-setup wrote (its first line marks
it) would share `~/.orca` and port 6768 with the container, so `--apply` stops until it is removed and `--plan` shows
how (`systemctl --user disable --now orca-serve.service`, remove the file, `systemctl --user daemon-reload`).

**Inside the container** `setup.sh` knows where it runs (the image sets `ORCA_SETUP_CONTAINER=orca-server`): `--plan`
and `--check` cover the image's tools, Orca and the logins and leave Docker, the image and the mounts to the host;
`--pairing-address`, `--workdir` and `--upgrade-image` are refused there and the host modules (`--power`,
`--containers`, `--gpu`) skipped.

**Orca's workspace directory.** Upstream keeps it as the `workspaceDir` global setting in the host's own profile state
under `~/.orca` (SQLite; `orca-data.json` is the older form), and a fresh profile gets
`getDefaultWorkspaceDir(homedir())`, i.e. `<home>/orca/workspaces` (`src/shared/constants.ts` in stablyai/orca). The
paired `settings.update` RPC takes a strict list of keys without it ("filesystem defaults stay host-private",
`src/shared/rpc-contract/client-settings-params.ts`), and no CLI command sets it, so `setup.sh` never writes it.
Because the container's `HOME` is the user's home path, Orca's default already is `<workdir>/workspaces` for the
default workdir `~/orca`. With another `--workdir`, `~/orca` in the container's home is a link to it, so the same
default lands in `<workdir>/workspaces` (Orca names those paths `~/orca/workspaces/...`; on the host the files are
under `<workdir>`, and the host's own `~/orca` is not touched).

**Claude's `~/.claude.json`.** Claude Code keeps its account state, MCP servers and per-project state in a file of its
own in the home directory and replaces it by renaming a new copy over it, which a single-file bind mount does not
survive. The container therefore sets `CLAUDE_CONFIG_DIR=~/.claude`: Claude Code then keeps that file as
`~/.claude/.claude.json` with the rest of its state in the mounted `~/.claude` (Claude Code's docs: "All settings,
session history, and plugins are stored under this path"; Orca's `resolveClaudeGlobalConfigFile` reads it from there
as well). No single file is mounted anywhere. A host whose user ran Claude Code natively keeps its `~/.claude.json`
as it is; copy it to `~/.claude/.claude.json` by hand to carry that state over. Other files written straight into
the home (`~/.gitconfig`, Orca's `~/.local/bin` shims, `~/.agents/skills`, caches) land in the container's home
directory and persist there.

`--role client` on Linux installs Orca and its CLI and the skills (§3.1); it starts no container and never creates a
pairing offer. Settings are aligned only when an Orca runtime already runs on the device.

**Pairing a client with a Linux server.** The pairing URL grants access to the server's runtime, so `setup.sh` never
creates, captures, prints or logs one, and the container runs with `--no-pairing`. Upstream has no command or RPC that
creates a pairing offer for a running server, and a supervised serve hides the URL from its log, so the user creates
the link in an interactive terminal on the host (a plain SSH session, not tmux or an Orca terminal whose scrollback is
kept):

```sh
cd ~/.config/orca-setup/docker
docker compose stop                     # one Orca per profile: a second serve would refuse to start
docker compose run --rm orca-server orca-ide serve --port 6768 --pairing-address <address>
                                        # prints "Pairing URL: orca://pair?..."; copy it, then Ctrl-C
docker compose start
clear                                   # drop the URL from the terminal
```

This is upstream's documented way for a service-managed server ("pair clients … with `orca serve` in a terminal while
the service is stopped"). `docker compose run --rm` uses the same image, user, home and mounts, so the offer is stored
in the device registry in `~/.orca` and the restarted container accepts it; the removed run container takes its log
with it. Stopping the container ends the terminal sessions running in it. On the client, paste it in
**Settings → Remote Orca Servers → Add Server**, or read it without echo instead of putting it on a command line (the
shell history would keep it): `read -rs code && orca environment add --name <server> --pairing-code "$code"`.
`--mobile-pairing` does the same for Orca Mobile. If a link leaks before it is used, generate a new one: that replaces
the unused link. Never take a link from `docker logs`: with `--no-pairing` the server never writes one there, and a
log would keep it.

### 3.4 Authentication (all interactive, run on demand)

| Mode | What it does | Linux without a desktop |
|---|---|---|
| `--auth-gh` | `gh auth login --web` (skipped when already logged in) | the same command is GitHub's device-code flow: gh shows a one-time code, the user opens `https://github.com/login/device` on any device and enters it; `GH_BROWSER=true` keeps gh from trying a browser here |
| `--auth-codex` | `orca account add --agent codex` (skipped when a Codex account is already selected) | device auth, works headless by design (P2) |
| `--auth-claude` | `orca account add --agent claude` (skipped when a Claude account is already selected) | headless requires a browser elsewhere or copying the URL (P2) |
| `--auth-agy` | run `agy` to sign in (there is no login subcommand) | over SSH agy prints an authorization URL; open it on any device, sign in, paste the code it shows back into the prompt. See the keyring caveat below |
| `--auth-linear` | open the Linear API settings page, silently read the key and write it into Orca (skipped when Linear is connected) | `xdg-open` when a desktop exists, otherwise the URL `https://linear.app/settings/api` is printed; the key needs this device's Orca runtime (a server), so a device without one stops before the prompt |

"Without a desktop" means neither `DISPLAY` nor `WAYLAND_DISPLAY` is set (`lib/detect.sh`); macOS always has one.

On a Linux server every login runs inside the container, where the agents and Orca are: `./setup.sh --auth-<name>` on
the host runs `docker exec --interactive [--tty] orca-server /opt/orca-setup/setup.sh --auth-<name>` (a terminal gets
`--tty`, so the hidden Linear prompt works), passes `SSH_CONNECTION` and `SSH_TTY` through so that agy prints its URL,
and refuses while the container is not running. What the logins store lands in the mounted directories (`~/.config/gh`,
`~/.orca`, `~/.codex`, `~/.claude`, `~/.gemini`).

- **Linear key.** `auth/linear-login.cjs` reads the key on a terminal with echo off, never from arguments or a
  pipe, and passes it on stdin to `orca/orca-rpc.sh local linear.connect`, which stores it inside Orca (sealed in
  `~/.orca` on Linux). It is never printed, logged or written by this repository.
- **agy on a headless server (from upstream's docs and issues).** agy keeps its session in the OS keyring, which on
  Linux is the Secret Service over D-Bus (GNOME Keyring, KWallet). Upstream's troubleshooting page asks for an active
  D-Bus session and an unlocked keyring; a plain SSH login on a server usually has neither, and then the sign-in
  succeeds but is not kept (upstream `google-antigravity/antigravity-cli` issues #53 and #950). agy also prints the
  URL only when it sees an SSH session; in an Orca terminal on a headless server it tries to open a browser instead.
  `--auth-agy` therefore warns when `SSH_CONNECTION` or `DBUS_SESSION_BUS_ADDRESS` is missing, and `setup.sh` never
  sets up or unlocks a keyring (that would mean handling a password). Upstream's non-interactive alternative, a
  Gemini API key in `GEMINI_API_KEY`, is a credential the user configures by hand. The server container has no
  Secret Service at all, so there the sign-in is expected not to persist; whether it does is part of the pending
  acceptance (§6.6).

Further auth modes (for example a self-hosted Git server) are added through the local overlay (§3.7), not in this repository.

### 3.5 Optional modules

Modules are selected on the command line and install only with `--apply`; their packages live in the matching group
of `manifest/baseline.tsv` / `manifest/agents.tsv`, and extra steps (pmset, Xcode, opening Docker, masking sleep
targets, the docker group) in `modules/<name>.sh`. `--plan` shows each selected module's rows and every `sudo`
command; a second `--apply` prints only `PRESENT`, `SKIP` and `NOTE` lines.

| Module | macOS | Linux |
|---|---|---|
| `--power` no sleep + restart after power loss | `sudo pmset -c sleep 0 autorestart 1` | `sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target` (only the targets not masked yet); restart-after-power-loss is a BIOS/UEFI setting, so every run prints a reminder. Skipped where systemd is not the init system (containers) |
| `--containers` | Docker Desktop (cask) | Docker Engine (`docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`) from Docker's apt repository, then `sudo usermod -aG docker $USER`; the group applies from the next login and grants root-equivalent access to the daemon. On a Linux server Docker is part of the baseline (§3.3.2), so the module adds nothing there |
| `--apple` | xcodegen / xcbeautify / xcodes + Xcode first launch | not applicable: skipped with a notice |
| `--android` | android-platform-tools (cask) | apt `android-sdk-platform-tools` (Debian 12 main, Ubuntu 24.04 universe) plus `adb` and `fastboot`, which that metapackage only recommends; the distributions' builds are older than Google's. When the device's apt sources do not offer them, skipped with a notice pointing to Google's platform-tools zip |
| `--media` | poppler ffmpeg sevenzip marksman | apt `poppler-utils ffmpeg p7zip-full`; marksman from its GitHub release binary (`marksman-linux-x64`) into `~/.local/bin` |
| `--agent-gemini` | npm `@google/gemini-cli` | same (`~/.local`) |
| `--gpu` | not applicable: skipped with a notice | detection only, never installs anything: NVIDIA GPUs (PCI vendor `0x10de`, display class `0x03xx`, from sysfs, else `lspci`), the loaded driver's version (`/sys/module/nvidia/version`, else `/proc/driver/nvidia/version`; a loaded `nouveau` is named), `nvidia-smi`, and the CUDA toolkit (`nvcc` on `PATH` or in `/usr/local/cuda/bin`) |

Linux notes:

- **Docker repository.** The key (`https://download.docker.com/linux/{ubuntu,debian}/gpg`) must consist of the
  primary key `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88` ("Docker Release (CE deb)"), the fingerprint
  Docker's own Ubuntu and Debian install guides printed (docker/docs, `engine/install/ubuntu.md` and `debian.md`);
  it is stored dearmored as `/etc/apt/keyrings/docker.gpg` with the source list
  `/etc/apt/sources.list.d/docker.list` (`deb [arch=amd64 signed-by=...] https://download.docker.com/linux/<distro>
  <codename> stable`). Docker's current guide writes `docker.asc` and a deb822 `docker.sources` instead and no longer
  prints the fingerprint; the one-line form is Docker's earlier layout and keeps the fingerprint check of §3.1.
- **Existing Docker or Podman is never touched.** `--containers` is skipped (with the reason) when any package listed
  in `manifest/apt-conflicts.tsv` is installed (Docker's list of unofficial packages, `docker.io docker-compose
  docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc`, plus `podman`), or when `docker`,
  `podman` or `docker-ce` exists without the repository setup above (Docker's convenience script, a hand-made
  repository, GitHub's runner image). Then nothing is installed and the group is left as it is.
- **marksman** is resolved like the Orca `.deb` (§3.3.1): the latest stable release of `artempyanykh/marksman`
  through the GitHub API, exactly one `marksman-linux-x64` asset whose URL belongs to that release, and its download
  must match the `sha256:` digest GitHub records; only then is it copied to `~/.local/bin/marksman`. No `sudo`.
- **`--gpu`** has no manifest rows and no `sudo` command: `--plan` and `--apply` print what they find (`--apply` as
  `NOTE gpu:` lines) and a hint for installing the driver by hand. With an NVIDIA GPU present, `--check --gpu` counts
  a missing driver (`NVIDIA driver: MISSING`); `nvidia-smi` and the CUDA toolkit are reported, not counted; without
  one it reports `NVIDIA GPU: none found (not counted)`.
- **On a Linux server** `--power` and `--gpu` run on the host as above; `--media`, `--android` and `--agent-gemini`
  are built into the Orca server image (`--apply` prints `PRESENT module <name> (built into the orca-server image)`,
  `--check` counts their rows inside the container); `--containers` is the server's Docker Engine; `--apple` is
  skipped. Inside the container the host modules are skipped with the reason.
- `--check --<module>` counts the module's manifest rows plus its own items (`Sleep targets`, `docker group`,
  `NVIDIA driver`); a module skipped on the device reports `skipped (<reason>; not counted)`.

### 3.6 Readiness audit (`--check`)

- Port `audit-readiness.cjs`: booleans/names only; covers whether env vars exist, auth and MCP names for claude/gemini/dsh/pi/codex, and cloud configs (gcloud/aws/azure/docker/npm).
- Add: a `PRESENT/MISSING` tool list, versions (node/pnpm/python/uv), Orca runtime reachability, whether the Orca accounts (codex/claude) are selected, whether Linear is connected (only when `--task-source linear` was chosen), whether gh is logged in, the pairing role check (§5.1); on a Linux server also Docker, the container, its image and its mounts.
- On Linux the Orca items depend on the role (`--role`, else server when
  `~/.config/orca-setup/docker/compose.yaml` exists, else client):
  - client: the PATH block in `~/.profile` and `~/.zshrc` is checked and counted too; the runtime is reported but not
    counted (`not running (client; not counted)`), skills are counted, and accounts and settings are checked only
    when a runtime runs.
  - server: one combined report. The host checks `Docker` (`working (Engine <version>, Compose <version>)`, else
    `MISSING`, `UNREACHABLE` or `CONFLICT` with the reason), the `docker group`, the `Orca server image` (`locked
    (<repository>@sha256:...)`, or `MISSING` without `image.lock`), `Newest image` (whether the registry's `main`
    differs from the lock, through `docker buildx imagetools inspect`; reported, never counted, never pulled), the
    `Orca server container` (`running`, else `INACTIVE (<status>)`, `MISSING`, or `STALE` when it was not created from
    the current `compose.yaml`), and every mounted directory (`Mount <path>`: `ok`, `MISSING` or `WRONG OWNER`), plus
    the host modules. It then runs `/opt/orca-setup/setup.sh --check [--json]` inside the container with those items
    (`docker exec`, environment `ORCA_SETUP_HOST_ITEMS`, `ORCA_SETUP_HOST_DEVICE`, `ORCA_SETUP_HOST_SERVER`), which
    prints them first and adds the image's tools, the logins and Orca's items (runtime, skills, accounts, settings,
    the role) as on macOS; its exit code is the total. Without a running container the host prints its own items and
    counts `Container checks (tools, logins, Orca): UNREACHABLE`. Run inside the container without those items (for
    example by `remote/provision.sh`), the report says `Docker host: not visible from inside the container (...; not
    counted)`.
- After `--apply`, the only counted items on a fresh Linux device are interactive logins: the GitHub login, plus the
  Orca Codex account on a server (both inside its container).
- Optional modules are checked only when given on the command line (`--check --media`): their manifest rows, the
  masked sleep targets (`--power`; on macOS the pmset values) and the docker group (`--containers` on Linux) are
  counted; a module skipped on the device is reported, not counted (§3.5).
- `--check --json` prints the same report as one JSON document on stdout instead of the text (schema
  `orca-setup-check/1`): `device`, `role` (requested and detected), `modules`, `missing`, `items` (every reported
  line as `{name, state, counted}`), `auth` (`gh`, `codex`, `claude`, `linear` with `complete`, `pending`,
  `not-selected` or `not-connected`, and whether it is counted), `versions` (including `orca` and `orca-latest`) and
  `audit` (the `READINESS_JSON` object). A Linux server adds `server`: `{"form": "docker", "image", "newest",
  "container", "workdir"}` from the host (or `"host": "not-checked"` when it ran inside the container alone), and its
  `device` is the host's. P5 only added keys; the schema stays `orca-setup-check/1`. It holds names, states, counts
  and versions only, never credential values, and exits with the same code. `remote/provision.sh` reads it instead of
  parsing the text (§5.2).
- Orca's version: `VERSION orca <installed> (latest release <version>)`, from `<orca> --version` and the latest stable
  release of the repository the Linux `.deb` comes from (`manifest/baseline.tsv`, through the GitHub API; `unknown`
  when it cannot be read). Reported only: `setup.sh` never upgrades Orca (§3.3.1).
- Exit code = number of missing items, usable directly as an acceptance condition. Counted: `MISSING` tools and
  agents from the manifest (and from the modules given), a missing Orca CLI, an unreachable Orca runtime (not on a Linux client), missing Orca
  skills, on a Linux server a missing or unreachable Docker, a missing docker group, image lock or mounted directory
  (or one owned by someone else) and a missing, stopped or stale container, a `PENDING` GitHub login or Codex
  account, Linear when `--task-source linear` is given, and a pairing role conflict (dual role, or the
  other role than `--role`) or an unknown role (unreadable pairing stores), and a missing NVIDIA driver next to an
  NVIDIA GPU (`--gpu`). Reported but not counted: versions (including Orca's installed and latest version), the
  Claude account, Orca settings that differ from the manifest, Linear when only Orca's settings select it,
  `nvidia-smi` and the CUDA toolkit, a newer server image, and the `READINESS_JSON` audit line.

### 3.7 Local overlay (untracked)

Organization- or device-specific settings live in `manifest/local/` (git-ignored): extra packages, extra auth modules,
mirrors, internal hosts. `setup.sh` merges the overlay on top of `manifest/` when it exists. The repository only ships
`manifest/local.example/` with placeholder values.

Merge rules: a TSV row in `manifest/local/<file>.tsv` whose first column matches a shipped row replaces it in place;
other rows are appended (`server-mounts.tsv` too: extra directories for the server container).
`manifest/local/orca-settings.json` is deep-merged over the shipped file (objects merge, values and arrays replace).
For a Linux server, `manifest/local/server-limits.env` sets container limits (keys in `manifest/server-limits.env`),
and `manifest/local/Dockerfile` is built on top of the locked Orca server image and runs instead (§3.3.2). Overlay
auth modules are not implemented yet.

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
│   ├── rows.sh                  # one manifest row: label, detection, install; plan/apply a group (setup.sh, image build)
│   ├── json.cjs                 # JSON helpers for the shell (names/booleans only)
│   ├── pkg-macos.sh             # brew formulae / casks
│   ├── pkg-debian.sh            # apt, third-party apt repos (gh, NodeSource, Docker), GitHub release files (Orca .deb, marksman), sudo steps
│   ├── docker-host.sh           # Linux server host: Docker Engine (or an existing Docker), the docker group, sg docker
│   ├── orca-server.sh           # Linux server: pairing address, workdir, mounts, compose.yaml, image.lock, container, check, logins
│   ├── pkg-fedora.sh            # (later) dnf placeholder
│   └── npm-tools.sh             # npm global tools under ~/.local
├── manifest/
│   ├── baseline.tsv             # tool → per-platform package/install method (single source of truth); "image" rows for the server image
│   ├── agents.tsv               # agent CLI inventory (baseline / optional, per-platform support)
│   ├── apt-repos.tsv            # third-party apt repositories and their expected key fingerprints
│   ├── apt-conflicts.tsv        # packages that mark a foreign install of a repository's software (Docker, Podman)
│   ├── server-host.tsv          # baseline rows a Linux server host installs before Docker Engine
│   ├── server-mounts.tsv        # directories mounted into the server container at the same path
│   ├── server-limits.env        # allowed container limit keys for the server (values go in local/)
│   ├── orca-skills.tsv          # Orca skills per platform and their install targets
│   ├── orca-settings.json       # Orca default settings and opt-in task sources
│   └── local.example/           # placeholder overlay; the real manifest/local/ is git-ignored
├── docker/
│   ├── Dockerfile               # the Orca server image (ghcr.io/vzxxbacq/orca-server), base pinned by digest
│   ├── build.sh                 # installs the image's tools from manifest/ through lib/ (run by the Dockerfile only)
│   ├── entrypoint.sh            # the container user's passwd/group entry (libnss-extrausers), then the command
│   └── compose.yaml             # template of the server's compose.yaml (§3.3.2)
├── modules/                     # power / containers / apple / android / media / agent-gemini, macOS and Linux; gpu (Linux detection)
├── auth/                        # gh / codex / claude / agy / linear (+ linear-login.cjs hidden prompt)
├── orca/
│   ├── orca-rpc.sh              # locate the Orca executable per platform (ORCA_APP_PATH), ELECTRON_RUN_AS_NODE
│   ├── orca-rpc.cjs             # reuse Orca's bundled RuntimeClient (never exports the pairing key)
│   ├── role.sh                  # pairing role check (§5.1); picks node or Orca's bundled runtime
│   └── role.cjs                 # role logic: reads the pairing stores, never prints secrets
├── audit/readiness.cjs          # read-only audit
├── remote/provision.sh          # run on the control machine: provisions one paired device through the Orca CLI (§5.2)
├── .github/workflows/ci.yml     # static checks + bats on Ubuntu and macOS; Linux client containers; Linux server in Docker
│                                #   on the runner VM; publishing the server image from main
└── tests/
    ├── bats/                    # unit tests (detect, manifest, role, readiness, Debian, Orca on Linux, the Linux server in
    │                            #   Docker, Linux modules and auth, --gpu, --check --json, remote provisioning against a fake
    │                            #   Orca server, --plan snapshots, static checks)
    │   └── pty.py               # types one line at a hidden prompt on a pseudo-terminal (Linear key tests)
    └── integration/linux.sh     # Linux integration: client in ubuntu:24.04 / debian:12 containers, server in Docker on the runner VM
```

---

## 5. New-device onboarding flow (target shape)

```
[new device, role: server]                    [control machine, role: client]

0. Install Orca (macOS desktop / Linux in Docker)
   Linux: ./setup.sh --apply --role server --pairing-address <address>  (Docker Engine, the orca-server container)

1. Generate a pairing code
   (desktop Settings, or on Linux        ──►   orca environment add --name <device> --pairing-code <code>
   `docker compose run --rm` in a             orca status --environment <device>
   terminal, §3.3.2)

2.                                      ◄──   orca project setup-clone --project <orca-setup project id>
                                               --host runtime:<environment-id> --url https://github.com/vzxxbacq/orca-setup
                                               --destination <home>/orca/projects

3.                                      ◄──   run in an orca-setup workspace terminal:
                                               ./setup.sh --plan --role server  →  ./setup.sh --apply --role server
                                               (a Linux server's terminals run in its container: --plan only)

4. Complete each `--auth-*` interactively on the device (or through an Orca terminal)

5.                                      ◄──   ./setup.sh --check   (exit code 0 = ready)

6.                                      ◄──   orca worktree create --environment <device> --project <x> --agent codex ...
```

- Steps 0–1 cannot be done remotely; they must happen locally on the device (on Linux, in an SSH session), so the
  README lists them as a manual checklist (§6.6). On Linux, step 0 runs `setup.sh` from a clone made on the host; a
  clone inside the workdir (`~/orca/projects`) is also visible to the container at the same path.
- On a Linux server the Orca terminals of step 3 run inside the `orca-server` container, which has no `sudo` and no
  Docker and cannot change the host: there step 3 is `--plan` only, `--apply` (and any later change) runs on the host
  over SSH, and step 5 checks the container's side (the host's side is `./setup.sh --check` on the host).
- The repository is public, so step 2 needs no Git credentials on the device.
- Steps 2–5 are one command on the control machine: `remote/provision.sh` (§5.2).

### 5.1 Pairing roles

Orca pairing is one-way: only a **client** (a host that saved a server pairing with `orca environment add`) can call a
**server**. A host that is both a client and a server relays editor tabs between its peers; with desktops paired both
ways, tabs multiply and end up bound to the wrong host. Rule: **every host has exactly one role.**

| Role | Saves environments (dials) | Accepts runtime pairings (is dialed) |
|---|---|---|
| `client` | yes, the servers it needs | no |
| `server` | no | yes, from its clients |

- `setup.sh --role client|server` is required for `--apply`; `--plan` shows what the role implies.
- `--role server` never runs `orca environment add`; `--role client` never prints a runtime pairing code. No role
  makes `setup.sh` print a pairing code: on a Linux server the container runs with `--no-pairing` and the user
  creates each link in an interactive terminal (§3.3.2).
- On Linux the role also decides the Orca setup: a server runs Orca in the `orca-server` container (Docker Engine on
  the host), a client gets Orca and its CLI only (§3.3.2).
- `--apply` refuses to continue when the device already holds the other role (saved environments on a server, or
  runtime clients seen recently on a client) and names the pairings to remove. Mobile pairings do not count. The
  check runs after the baseline install (which brings Node.js to a fresh Linux device) and before any Orca step, so
  the baseline is never blocked by it. A Linux server host has no Node.js: its check runs read-only inside the image,
  before the container starts.
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

### 5.2 Remote provisioning (`remote/provision.sh`)

`remote/provision.sh --environment <name> [--plan | --apply | --check] [--role server] [--pairing-address <address>]
[--task-source linear] [modules] [--destination <dir> | --path <dir>] [--fast-forward]` runs on the control machine
and wraps steps 2–5 for one paired device. Everything goes through the public Orca CLI (resolved like setup.sh's,
`lib/detect.sh`); the device needs nothing but its paired Orca server.

1. **Preflight** (read-only). This machine must be a client (`orca/role.sh --expect client`: saved environments, no
   runtime clients seen recently); on a server, a dual role, a host without saved environments or an unknown role
   it refuses with the reason before asking any server. The environment must be saved here
   (`orca environment show --environment <name> --json`, which also gives the id behind `runtime:<id>`) and reachable
   (`orca status --environment <name> --json`). Neither reply is ever printed.
2. **The checkout** (step 2). An existing project setup of `github:vzxxbacq/orca-setup` on the device is reused
   (`orca project setups --host runtime:<id> --json`). Otherwise `--apply` clones the public repository with
   `orca project setup-clone --project github:vzxxbacq/orca-setup --host runtime:<id> --url https://github.com/vzxxbacq/orca-setup
   --destination <dir> --json` (`--destination` is an absolute parent directory on the device, required then), or
   registers a checkout made on the device during step 0 with
   `orca project setup-existing-folder --project github:vzxxbacq/orca-setup --host runtime:<id> --path <dir> --kind git --json`
   (`--path`). `--plan` and `--check` only print that command and stop: they never clone.
3. **The terminal.** `orca terminal create --environment <name> --worktree path:<checkout> --title "orca-setup provision" --json`
   opens one terminal in that workspace. Each step is sent with `orca terminal send --environment <name> --terminal
   <handle> --text "sh -c '<command>; printf ... <marker> $?'" --enter --json` and its output streamed back with
   `orca terminal read --environment <name> --terminal <handle> --cursor <n> --json` (shown as `  | ` lines) until a
   marker line with a per-step nonce carries the exit status. `sh -c` keeps the commands independent of the device's
   login shell. The terminal stays open at the end, for the logins.
   **A Linux server in Docker is recognised here**, by the first command in that terminal: Orca's terminals there run
   inside the `orca-server` container, whose image sets `ORCA_SETUP_CONTAINER=orca-server` and writes
   `/etc/orca-server-image` (a terminal inherits the runtime's environment, and the file covers one that does not).
   The answer is a `orca-setup-form <host|orca-server>` line that printf assembles, so the echoed command line never
   matches it. Neither the CLI's `status` reply nor the environment record names the form, and a remote terminal needs
   a checkout to open in, so on a device without one `--apply` makes the checkout (step 2) before it can tell.
4. **An existing checkout is verified** first: its `origin` must be this repository (https or ssh spelling, else
   refused), local changes are reported and never touched, and after a `git fetch` (remote-tracking refs only) a checkout behind its upstream is
   fast-forwarded only with `--fast-forward` (`git merge --ff-only @{u}`; refused with local changes or local
   commits). `--apply` refuses to run a checkout that is behind without it; `--plan` and `--check` warn.
5. **setup.sh** (steps 3 and 5). `--plan` (the default) runs only `./setup.sh --plan --role server [...]`. `--apply`
   runs `./setup.sh --plan`, then `./setup.sh --apply --role server [--pairing-address ...] [modules]
   [--task-source ...]`, then `./setup.sh --check --json --role server [modules] [--task-source ...]`; `--check`
   runs only the last one. The device's report is read from the JSON (§3.6), never from the text.
   **On a Linux server in Docker** `--plan` and `--check` run there as well (the plan without `--pairing-address`,
   which belongs to the host's `compose.yaml`; the check covers the container's side and the summary points to
   `./setup.sh --check` on the host), but `--apply` is refused (exit 100) before setup.sh runs: right after the
   terminal opens on an existing checkout, after making the checkout otherwise. The container has no `sudo` and no
   Docker and cannot change its host, so the server is installed and updated on the host over SSH
   (`./setup.sh --apply --role server --pairing-address <address>`).
6. **sudo** (Linux apt steps and modules). provision.sh never reads, sends or stores a password. When the device's
   output shows a sudo prompt it prints `ACTION: sudo on <name> is asking for a password. Answer it in the Orca
   terminal "orca-setup provision" (handle <handle>) of <checkout> on <name>` with the `orca terminal switch` command
   that brings that terminal up in the desktop app, and keeps waiting (`ORCA_SETUP_REMOTE_TIMEOUT`, default 7200 s per
   step).
7. **Interactive logins** (step 4) are never run by provision.sh (`--auth-*` is refused). The summary lists the
   counted items and every login the device's `--check --json` reports as pending, as `./setup.sh --auth-<name>`
   lines to run in that terminal, plus `--auth-agy`, which `--check` cannot detect.

`--role` accepts only `server`: this client dials the device, so the device holds the server role (§5.1). The exit
code is the device's missing count for `--check` and `--apply` (capped at 99; 0 means ready), 0 for a finished
`--plan`, 100 when it refused or failed before the device's check finished, and 2 for a usage error.

---

## 6. Implementation phases

| Phase | Scope | Done when |
|---|---|---|
| **P0 Skeleton + macOS parity** | `setup.sh` entry, `lib/common.sh`, `lib/detect.sh`, `manifest/`, `--role`; port every mode from setup-mini.sh | on the reference Mac, `--plan` output matches setup-mini.sh; `--check` results do not regress |
| **P1 Linux baseline** | `pkg-debian.sh`, user-level npm/uv installs, PATH written to `~/.profile`/`~/.zshrc` | in Docker, `ubuntu:24.04` and `debian:12` run `--apply` twice successfully (idempotent); `--check` reports only auth items |
| **P2 Orca on Linux** | install the headless runtime, `orca-ide` detection, systemd user unit + linger, skills, default settings, cross-platform `orca-rpc` | accepted on CI (2026-10-24): containers install the `.deb` as a client; the runner VM runs the server unit with linger, reaches the runtime, re-runs as a no-op and counts only interactive logins. **Pending**: a real Linux x86_64 machine paired from a laptop client with `orca environment add`, then `worktree create --agent codex` remotely |
| **P3 Auth + optional modules** | headless adaptations for `auth/*` (xdg-open / print URL), Linux versions of `--power`, `--containers`, `--media`, `--android`, `--agent-gemini` | accepted on CI (2026-10-24) for everything that can run unattended: every Linux module has `--plan` output covered by bats, and `--apply` twice is a no-op the second time in ubuntu:24.04 / debian:12 containers (Docker Engine fresh install, media, android, gemini; `--power` and `--apple` skipped) and on the runner VM (`--power` masks the targets, the preinstalled Docker is left alone). **Pending**: the interactive logins (`--auth-gh` device code, `--auth-agy`, `--auth-linear`) on a real headless server; CI tests them with fakes only |
| **P4 Remote provisioning + extensions** | `remote/provision.sh` (wrapping §5 steps 2–5), `--gpu` detection, audit enhancements (`--check --json`, Orca's installed vs latest version) | implemented and covered by bats against a fake Orca server (2026-10-24); `--gpu` and `--check --json` also run in the Linux CI jobs. **Pending**: a laptop client provisioning a real Linux x86_64 server from "paired" to "all green except interactive auth" with `remote/provision.sh --apply` (§6.6) |
| **P5 Linux server in Docker** | the Linux server runs Orca and every agent in a container from `ghcr.io/vzxxbacq/orca-server`; the host gets only Docker Engine; work and data directories are bind-mounted at the same paths; the native server path (systemd unit, linger, host agents and `.deb` on a server) is removed; Linux clients unchanged (§6.7) | CI builds the image and, on the runner VM, `--apply --role server` twice with it (second run a no-op), the runtime is reachable through the container, no pairing URL in any output or container log, mounted data survives a container re-create with the host user's ownership; pushes to `main` publish the image with provenance. Real-device acceptance per the rewritten §6.6 |

### 6.1 P0 port notes (differences from setup-mini.sh)

- `--agy` is gone: agy is a baseline agent installed by `--apply`.
- Optional modules run only together with `--apply` (setup-mini ran `--power`, `--apple` … immediately).
- `--apply` requires `--role` and refuses a dual role before changing anything.
- New baseline items from §3.1/§3.2: git-lfs, the Orca app itself, bun, omp, grok; Codex comes from npm (an existing
  Homebrew cask install is detected and kept).
- The Linear task source is opt-in (`--task-source linear`); setup-mini always set it.
- Orca skills and settings are skipped when already in place; `--auth-claude` is skipped when an account is selected.
- `--check` counts GitHub, Codex and role problems in its exit code, and also prints the `READINESS_JSON` audit.

### 6.2 P1 notes (Linux baseline)

- Linux devices other than Ubuntu 24.04 / Debian 12 on x86_64 are refused by `--plan`, `--apply` and `--check`
  with the reason (arm64, or the distribution and release).
- The pairing role check moved after the baseline install on both platforms (§5.1); it still runs before any Orca step.
- In P1, `--apply` on Linux skipped the Orca section and optional modules (P3), `--check` did not count Orca items,
  and `--auth-gh` was the only auth mode on Linux. P2 replaced the Orca part (§6.3).
- A second `--apply` prints only `PRESENT` lines (plus the deferred items and the role report) and runs no step.

### 6.3 P2 notes (Orca on Linux)

- The Orca `.deb` is a baseline row (`orca-deb:stablyai/orca:orca-ide`), installed last and only when `orca-ide` is
  missing; existing installs are never upgraded (§3.3.1).
- `--role server` adds linger and the `orca-serve` user unit (§3.3.2) and requires `--pairing-address`; `--role client`
  installs Orca only. Skills and settings follow on both, as on macOS.
- `orca/orca-rpc.sh` and `orca/role.sh` find the `.deb` install under `/opt/Orca` (`ORCA_APP_PATH` overrides).
- `--check` counts the Linux Orca items by role (§3.6); the P1 notice is gone.
- `--auth-codex` and `--auth-claude` work on Linux (`orca-ide account add` on the server); agy and Linear followed in P3.
- Real-device acceptance is pending (table above): the CI runner cannot be dialed from another machine.

### 6.4 P3 notes (auth + optional modules on Linux)

- Every `--auth-*` runs on Linux; the headless behaviour is in §3.4. macOS behaviour is unchanged.
- Linux modules use the same flow as macOS: the module's manifest rows, then its own steps. A module can declare
  itself not applicable to the device (`--apple` on Linux, `--power` without systemd, `--containers` next to a
  foreign Docker or Podman, `--android` when apt does not offer the package); `--apply` then prints
  `SKIP module <name>: <reason>` and continues.
- `--check` accepts modules and counts their items (§3.6); `--auth-*` still refuses them.
- `manifest/apt-repos.tsv` accepts `{distro}` and `{codename}`; `manifest/apt-conflicts.tsv` is new; the
  `github-release:<owner/repo>:<asset>:<command>` method replaces the P1 placeholder `github-release:<name>`, and the
  P1 placeholder `docker-apt-repo:` became ordinary `apt-repo:docker:<package>` rows.

### 6.5 P4 notes (remote provisioning + extensions)

- `remote/provision.sh` is new (§5.2); setup.sh is unchanged on the device except for `--check --json`.
- `--gpu` is a Linux detection module (§3.5); on macOS it is skipped with a notice.
- `--check --json` and the Orca version report are new in the audit (§3.6). Still open from §3.6: nothing; MCP and
  cloud configuration were already covered by the `READINESS_JSON` audit.
- The module and login lists moved to `lib/common.sh` (`ORCA_SETUP_MODULES`, `ORCA_SETUP_AUTHS`), so provision.sh
  forwards exactly the modules setup.sh accepts.
- CI does not provision a device end to end. Pairing a second, isolated client runtime with the runner VM's server
  would need a pairing offer, which only `orca-ide serve` prints to its terminal: the CI job would have to capture a
  live credential in its own process and files, where any failure path could print it into a public log. And
  `project setup-clone` clones the public default branch, not the commit under test. Both are left to the real-device
  session (§6.6).
- Unverified against a real server (the bats fake follows the CLI's documented `--json` shapes): that
  `project setup-clone` accepts the project id `github:vzxxbacq/orca-setup` for a fresh device, the `terminal read`
  cursor semantics for a partial last line (a sudo prompt has no newline), and the terminal `status` values.

### 6.6 Pending real-device acceptance (P2, P3, P4)

Run in one session with a laptop as the control machine (client) and a real Linux x86_64 machine (Ubuntu 24.04 or
Debian 12) as the new server; nothing here is covered by CI.

1. **P2, server install** (in an SSH session on the server): clone the repository, then
   `./setup.sh --apply --role server --pairing-address <private address>`; `./setup.sh --check` counts only the GitHub
   login and the Orca Codex account.
2. **P2, pairing**: create a link with the unit stopped (§3.3.2), save it on the laptop with
   `read -rs code && orca environment add --name <server> --pairing-code "$code"`, run `clear` on the server, and
   check `orca status --environment <server>` on the laptop. Confirm the journal holds no pairing URL.
3. **P4, provisioning**: on the laptop, `remote/provision.sh --environment <server>` (plan only), then
   `remote/provision.sh --environment <server> --apply --pairing-address <private address> --path <checkout from 1>`
   (or `--destination <dir>` on a server set up without step 1). Expect the existing checkout to be verified, a sudo
   hand-off message if sudo asks, only `PRESENT` lines from `--apply`, and an exit code equal to the pending logins.
   Also try `--check`, `--gpu` on a machine with an NVIDIA GPU, and confirm that provision.sh refuses on the server
   itself.
4. **P3, logins** (in the Orca terminal provision.sh left open, or over SSH): `./setup.sh --auth-gh` (device code),
   `--auth-codex`, `--auth-claude`, `--auth-linear` (into the server's Orca), and `--auth-agy`; then check whether
   agy's sign-in survives a new SSH login without a desktop keyring (§9, open question 1).
5. **P3, modules on hardware**: `--power` (sleep targets masked; the BIOS setting by hand) and `--containers`.
6. **P2, remote work**: `orca worktree create --environment <server> --project <x> --agent codex ...` from the laptop;
   also whether `computer-use` can drive an app under Xvfb on the headless server.
7. **Done when** `remote/provision.sh --environment <server> --check` exits 0.

### 6.7 P5 plan: Linux server in Docker (decided 2026-10-26)

Replaces the native Linux server (§3.3.1, §3.3.2) with a container. Linux clients and macOS are unchanged.

**Host.** `./setup.sh --apply --role server --pairing-address <address> [--workdir <abs dir>]` on Linux:

- installs Docker Engine through the existing verified apt path (§3.5 `--containers`, key fingerprint
  `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88`) and adds the user to the `docker` group (root-equivalent;
  `--plan` and the README say so). A working existing Docker (CLI, reachable daemon, compose plugin) is used as it
  is (preserve existing installs); Podman or a broken Docker is refused with the reason.
- installs nothing else on the host: no Node.js, agents or Orca `.deb` for a server. `--power` and `--gpu` still run
  on the host. `--containers` on a Linux server is part of the baseline.
- creates the mounted directories (owned by the user), renders `docker/compose.yaml` into
  `~/.config/orca-setup/docker/` (`$XDG_CONFIG_HOME` honoured) and starts the container. The systemd user unit,
  linger, `lib/orca-serve.sh`, `orca/systemd/` and the unit's environment file are removed.

**Container.**

- `docker compose`, `network_mode: host` (port 6768 and the pairing address need no mapping),
  `restart: unless-stopped` (Docker brings it back after a reboot), `init: true`; the command is
  `orca-ide serve --supervise --no-pairing --port 6768 --pairing-address <address>`.
- runs as the host user's UID:GID with `HOME` set to the host user's home path; no `sudo` and no Docker inside.
- read-only root filesystem with a tmpfs `/tmp`; the rest of the container's `HOME` is a dedicated host directory
  (`~/.local/share/orca-setup/home`, `$XDG_DATA_HOME` honoured), so a write outside the mounts fails or persists
  instead of vanishing on re-create, and the host's real home is reached only through the mounts below.
- terminal resource limits, if wanted, become container limits from the local overlay
  (`manifest/local/`), replacing the unit's `ORCA_TERMINAL_*` cgroup settings.

**Mounts** (same absolute path on the host and in the container; the list lives in `manifest/`):

| Host path | Contents |
|---|---|
| `~/orca` (`--workdir`) | `projects/` and `workspaces/`; Orca's workspace directory setting points here |
| `~/.orca` | Orca user data: pairings, device registry, sealed integration credentials |
| agent state: `~/.codex`, `~/.claude` (+ its top-level state file), `~/.config/gh`, `~/.gemini` and the other agents' directories | logins and configuration survive image upgrades |

**Image.** `ghcr.io/vzxxbacq/orca-server`, built from `docker/Dockerfile`:

- base image pinned by digest; the baseline tools and every agent come from `manifest/` through the existing
  `lib/` install code (no package list in the Dockerfile), installed under a fixed system prefix rather than a
  user's home; the Orca `.deb` keeps its digest and control-field checks (§3.3.1); also Xvfb, the `--media` tools,
  gemini and adb, so `--media`, `--android` and `--agent-gemini` are built in on a Linux server; a copy of this
  repository's scripts at `/opt/orca-setup` for in-container checks and logins.
- CI builds it on every PR (no push) and, on pushes to `main`, publishes `sha-<commit>` and `main` with a build
  provenance attestation; actions pinned by commit. The package must be made public once in GitHub's settings.
- `--apply` pulls `main` on first install and records the digest it started in
  `~/.config/orca-setup/docker/image.lock`; re-runs keep that digest (no upgrades). `--upgrade-image` pulls the
  current `main` and re-creates the container; `--check` reports the running digest and whether a newer one exists.
- organization-specific tools: an optional `manifest/local/Dockerfile` (`FROM` the published image) is built locally
  and used instead.

**Pairing, logins, check.**

- Pairing: `docker compose stop`, then an interactive `docker compose run --rm` of `orca-ide serve --port 6768
  --pairing-address <address>` in an SSH terminal; copy the link, Ctrl-C, `docker compose start`, `clear`. The
  removed run container takes its log with it; `setup.sh` still never creates, captures or prints a link.
- `./setup.sh --auth-*` on the host runs each login inside the container (`docker exec -it`); Orca skills and
  settings are applied the same way. agy has no Secret Service in the container, so its sign-in is expected not to
  persist; confirmed or refuted on real hardware (§9).
- `--check` on the host: Docker, group membership, container state, image digest, mounts and ownership, then
  `/opt/orca-setup/setup.sh --check --json` inside the container for tools, logins and Orca; one combined report.

**`remote/provision.sh`.** An Orca terminal on a Docker server runs inside the container, without `sudo` or Docker,
so it cannot change the host: for such a server provision.sh keeps `--plan` and `--check` and refuses `--apply`,
pointing to the host install over SSH.

**CI.** The client container matrix stays. The runner VM job builds the image locally and runs
`--apply --role server --pairing-address 127.0.0.2` with it twice (second run a no-op), checks the runtime through
`docker exec`, that no output, container log or journal holds a pairing URL, that a file written in a mounted
directory survives `docker compose down && up` owned by the runner user, and that writing outside the mounts fails.
A publish job runs only on pushes to `main`.

---

## 7. Test strategy

- **Static**: `shellcheck` every `*.sh`; `node --check` every `*.cjs`.
- **Unit**: bats tests for `detect.sh` (fake `/etc/os-release`, `uname`), manifest parsing, role checks and `--plan` output snapshots.
  Run `bats tests/bats`; every test runs in a sandbox whose `PATH` holds only fakes and a few core utilities. Refresh
  snapshots with `UPDATE_SNAPSHOTS=1 bats tests/bats/plan.bats` and review the diff.
- **Linux integration** (`tests/integration/linux.sh`, `.github/workflows/ci.yml`), as a non-root user with
  passwordless sudo, in two shapes:
  - `client` in a container matrix (ubuntu:24.04 / debian:12, amd64; no systemd): `--apply --role client` with every
    optional module twice (the second run must run no step and leave packages, apt sources, keyrings, dotfiles and
    groups unchanged); Docker Engine must be installed from Docker's repository with the user in the docker group,
    `pdftotext`, `ffmpeg`, `7z`, `adb`, `gemini` and `~/.local/bin/marksman` must run, and `--power` / `--apple` must
    be skipped; a login shell must
    find the user-level tools and `orca-ide`, the `.deb` must be installed and `orca-ide` must run, the skills must be
    installed, no unit may be written, the rendered unit must pass `systemd-analyze verify`, and `--check` must count
    only the interactive GitHub login;
  - `server` directly on GitHub's Ubuntu 24.04 runner VM (systemd), as the runner user:
    `--apply --role server --pairing-address 127.0.0.2 --power --containers` (test-only override, §3.3.2) twice; the
    sleep targets must be masked, the runner's preinstalled Docker (packages, apt sources, group) must be unchanged
    and `--containers` skipped, the unit must be enabled
    and active, linger on, the unit must pass `systemd-analyze --user verify`, `orca-ide status --json` must report the
    runtime reachable, neither the setup output, the status reply nor the unit's journal may contain a pairing URL,
    and `--check` must count only the GitHub login and the Orca Codex account.
  Pairing from another machine and the interactive logins are verified on real hardware (§6). In bats, every
  module's plan, the key fingerprint and release digest checks, the skip paths, headless detection and the auth
  modes run against fakes; the Linear key is typed on a pseudo-terminal (`tests/bats/pty.py`, only once echo is
  off) and must appear in no output and no file except what the fake Orca runtime received.
- **Remote provisioning** (`tests/bats/provision.bats`): a fake Orca CLI plays this machine's pairing store and one
  paired server whose terminal runs each command for real in a git checkout cloned from a local bare repository
  (standing in for the public one through git's `insteadOf`), with a stub `setup.sh`. It covers the role refusal on a
  server host (before any server is asked), a host without environments and a dual role, unknown and unreachable
  environments, `setup-clone` versus an existing checkout (wrong origin, local changes, behind its upstream with and
  without `--fast-forward`, `--path`), the plan-only default, the apply order, the sudo hand-off message, the exit
  code from the device's `--check --json`, an old device without `--check --json`, and that no output carries the
  pairing secret the fake replies hold.
- **`--gpu`** (`tests/bats/gpu.bats`) runs against a fake sysfs tree, `/proc`, `lspci`, `nvidia-smi` and `nvcc`;
  **`--check --json`** (`tests/bats/check-json.bats`) checks the schema, the exit code, the Orca version report and,
  with seeded secrets, that no credential value appears.
- **CI**: the same workflow runs shellcheck, `node --check` and bats on `ubuntu-latest` and `macos-latest`. The Linux
  jobs also pass `--gpu` (the runners have no NVIDIA GPU) and check that `--check --json` reports the same missing
  count as `--check`. Remote provisioning is not run end to end in CI (§6.5).
- **macOS regression**: on an already provisioned Mac run only `--plan` / `--check` (no re-installs).
- **Security regression**: grep the audit output to ensure no token/key-shaped strings; CI fails on host names, private IPs or internal URLs in tracked files.
  The bats fake of `orca-ide status` carries a pairing URL, and every Linux Orca test asserts it never reaches the output.

---

## 8. Risks

| Risk | Mitigation |
|---|---|
| `orca-rpc.cjs` depends on Orca internals (`out/cli/runtime-client.js`) and RPC method names (`settings.update`, `accounts.list`, `linear.status`, `files.writeBase64`), which may change between versions | use the public CLI wherever possible; keep all RPC calls under `orca/`; `--check` fails loudly instead of silently when a probe fails |
| On Linux, `orca` collides with the GNOME screen reader | `detect.sh` resolves the CLI name in one place; scripts must never hardcode `orca` |
| Support for `agy`, `computer-use` etc. on Linux is uncertain | verify feasibility before P2/P3; mark them macOS-only in the manifest if unsupported (`computer-use` has an upstream Linux helper and stays installed, §3.3) |
| A pairing URL leaks through logs or scrollback | the unit runs with `--no-pairing`; `setup.sh` never asks for an offer; the user creates links in an interactive terminal (§3.3.2); tests assert no pairing URL in any output or journal |
| The `.deb` download is tampered with | GitHub's per-asset sha256 digest and the package's control fields are checked before `apt-get` sees the file; no digest, no install (§3.3.1) |
| Browser login on headless Linux | prefer device-code flows (codex, gh); otherwise print a URL for the user to finish on any machine (Linear; agy prints its own over SSH) |
| agy cannot keep its sign-in on a headless server (no unlocked Secret Service keyring) | documented in §3.4; `--auth-agy` warns without SSH or D-Bus; `setup.sh` never handles keyring passwords; verified on real hardware (§6) |
| `--containers` replaces or upgrades a Docker or Podman someone installed another way | skipped when a conflicting package (`manifest/apt-conflicts.tsv`) or a foreign `docker`/`podman` exists; CI checks the runner's preinstalled Docker stays unchanged |
| The docker group is root-equivalent | only added by the explicit `--containers` module; `--plan` and the README say so |
| GPG key management for third-party apt repos (NodeSource / gh / Docker) | use `/etc/apt/keyrings/` + `signed-by=`, and record key fingerprints in the manifest for verification (Docker's no longer appears in its current guide; the recorded one comes from its earlier guides, §3.5) |
| A GitHub release binary (marksman) is tampered with | GitHub's per-asset sha256 digest is required before it is copied into `~/.local/bin`; no digest, no install |
| No public CLI lists the runtime clients paired with a host, so `orca/role.sh` reads Orca's device registry file | read only scope/name/last-seen; never print tokens; fail closed (`ROLE unknown`) when the file does not parse or has an unexpected shape; covered by bats tests with fake registries; switch to a CLI once one exists |
| Dual pairing roles corrupt editor tabs across hosts | `--role` is mandatory for `--apply`; preflight refuses a dual role (§5.1) |
| Private details leak into the public repository | local overlay for anything organization-specific; CI leak check (§7) |
| `remote/provision.sh` depends on the CLI's `--json` shapes (`environment show`, `project setups`, `project setup-clone`, `terminal create/read`) and reads command results from terminal output | public CLI only; each step's end is a marker line with a per-step nonce, and the device's report is JSON (`--check --json`), not text; a device without it is reported, not guessed; real-device acceptance pending (§6.6) |
| A password or pairing code passes through provision.sh | it never asks for one: sudo is answered by the user in the device's Orca terminal, `--auth-*` is refused, and the environment and status replies are never printed; bats asserts the fake replies' pairing secret never reaches the output |
| provision.sh runs an old or modified checkout on the device | the origin must be this repository; local changes are never touched; `--apply` refuses a checkout behind its upstream unless `--fast-forward` (fast-forward only) |

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
| Linux server address | `--pairing-address <ip-or-host>` is required for `--apply --role server`; loopback and wildcards are refused |
| Pairing link on a Linux server | never handled by `setup.sh`; the unit runs with `--no-pairing` and the user runs `orca-ide serve` in a terminal while the unit is stopped (§3.3.2) |
| P2 acceptance | accepted on CI; pairing from a laptop client to a real Linux x86_64 machine is pending (§6) |
| `computer-use` on Linux | installed: upstream ships a Linux AT-SPI helper; it needs a graphical session to drive apps (§3.3) |
| agy sign-in on a headless host | `--auth-agy` runs agy, which prints a URL over SSH; keeping the session needs an unlocked Secret Service keyring, which `setup.sh` does not set up (§3.4) |
| Docker on Linux | Docker Engine from Docker's apt repository, key fingerprint `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88`; a foreign Docker or Podman is left alone (§3.5) |
| Android tools on Linux | the distributions' `android-sdk-platform-tools` (older than Google's zip); skipped with a pointer to the zip where apt lacks it |
| P3 acceptance | accepted on CI; the interactive logins on a real headless server are pending (§6) |
| Remote provisioning | `remote/provision.sh` on the client, through the public Orca CLI only (setup-clone or an existing checkout, an Orca terminal, `--check --json`); read-only by default; never handles passwords or runs `--auth-*` (§5.2) |
| GPU module | `--gpu`: NVIDIA detection on Linux only, never installs; counts a missing driver next to an NVIDIA GPU (§3.5) |
| Linux server form (2026-10-26) | Docker container from GHCR (`ghcr.io/vzxxbacq/orca-server`) with work, Orca data and agent login directories bind-mounted at the same paths; native server path removed; no Docker inside the container; Linux clients stay native (§6.7) |
| P4 acceptance | covered by bats against a fake server; a laptop client provisioning a real Linux server is pending (§6.6). CI does not pair a second runtime, so no pairing secret exists in CI (§6.5) |

**Open**

1. agy's interactive sign-in on a real headless server: whether the session survives a new SSH login without a
   desktop keyring (upstream issues #53, #950). If not, decide whether to document a keyring setup or the
   `GEMINI_API_KEY` route (§3.4).
2. P3 real-device acceptance (pending): `--auth-gh` device code, `--auth-linear` into the server's Orca, and
   `--containers` / `--power` on real hardware.
3. P2 real-device acceptance (pending): pair a laptop client with a real Linux x86_64 server set up by
   `--apply --role server`, then `orca worktree create --environment <server> --agent codex` from the client; also
   check whether `computer-use` can drive an app under Xvfb on a headless server.
4. P4 real-device acceptance (pending): `remote/provision.sh --apply` from a laptop client to that server, including
   the unverified CLI details listed in §6.5. All pending items are collected in §6.6.

---

## 10. References

- Original macOS scripts this plan generalizes: `setup-mini.sh`, `install-agy.sh`, `orca-rpc.sh`, `orca-rpc.cjs`, `audit-readiness.cjs`, `linear-login.cjs` (kept outside this repository).
- Orca CLI: `orca serve` (`--supervise` adapts to launchd/systemd), `orca environment add`, `orca project setup-clone`, `orca skills install`, `orca account add`, `orca vm recipe doctor` (`environmentRecipes` in `orca.yaml`, a possible direction for VM automation after P4).
- Repository conventions (language, style, ground rules): [`AGENTS.md`](AGENTS.md).
