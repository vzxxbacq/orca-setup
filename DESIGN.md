# Design and implementation reference

For everyday use, read [README.md](README.md). For command-line operations, read
[AGENT-OPERATIONS.md](AGENT-OPERATIONS.md). This document retains the numbered design notes and historical decisions.

> Status: **P0–P5 implemented**: macOS parity, the Linux baseline, Orca on Linux, auth and optional modules on Linux,
> remote provisioning from a client, and (P5, §6.7) the Linux server in a Docker container with its work, Orca data
> and agent login directories mounted from the host; the native Linux server (systemd user unit) is gone. Since P5.1
> the container's Orca port is published on one private host address only (`--publish-address`, §3.3.2). Real-device
> acceptance is **pending**; the checklist in §6.6 runs all of it in one session.
> Optional isolated networking (§3.3.3) adds transparent proxy egress and a separate LAN-only command executor.
> Goal: turn a new device (macOS or **Linux**) into a usable Orca development machine with one set of scripts.
> Origin: generalized from a set of macOS-only scripts (`setup-mini.sh`, `install-agy.sh`, `orca-rpc.{sh,cjs}`,
> `audit-readiness.cjs`) written for migrating one Mac to another.
> License: [MIT](LICENSE). This repository is public: never commit host names, internal URLs, addresses or credentials.

---

## 0. Usage

```sh
./setup.sh                          # same as --plan: print what would happen on this device, change nothing
./setup.sh --tui                    # Linux server installation or management; Install/Apply saves automatically
./setup.sh --config orca.toml        # Linux Docker host: one TOML for server, proxy, DNS, executor and limits
./setup.sh --config orca.toml --apply # apply that configuration; no role/address flags needed
./setup.sh --check                  # read-only readiness report; exit code = number of missing items
./setup.sh --apply --role server    # install what is missing, Orca skills and defaults (role is required)
./setup.sh --apply --role server --pairing-address <ip-or-host>   # Linux server: Docker Engine + the orca-server container
./setup.sh --apply --role server --pairing-address <host-name> --publish-address <private-ipv4>   # port 6768 only there
./setup.sh --apply --role server --pairing-address <ip-or-host> --workdir /srv/orca   # projects/ and workspaces/ there
./setup.sh --apply --role server --pairing-address <ip-or-host> --upgrade-image       # Linux server: newest image
./setup.sh --plan --role server --network-mode isolated       # optional proxy gateway and LAN-only executor
./setup.sh --apply --role server --pairing-address <ip-or-host> --network-mode isolated
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
  address in Orca's Settings; a client never advertises one). `--publish-address`, refused in the same places, is the
  server's own private IPv4 address that Docker publishes port 6768 on, and no other host address answers on that
  port; it defaults to an IPv4 `--pairing-address`, a host name needs it, and a re-run keeps the last one (§3.3.2).
  `--workdir`, `--upgrade-image` and `--network-mode` are for Linux servers only.

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

- No host SSH configuration. Optional container-only mutual SSH is configured explicitly with `server.internal_ssh`.
- No migration or copying of agent credentials, tokens or private keys; agent authentication happens interactively on the target device.
  Explicit proxy credentials may be entered in a private server TOML on that device (§3.3.3).
- No project data migration; only extension points are reserved.
- No organization-specific integrations (internal Git hosts, VPNs, mirrors) in this repository; those go in a local, untracked overlay (§3.7).
- No Linux arm64.
- No host VPN or private-route setup: the route between client and server (Tailscale, LAN, WireGuard) is the user's
  job. Optional isolated container networking (§3.3.3) consumes an existing proxy endpoint; it never installs a proxy
  client, handles SS credentials, installs custom host firewall rules or configures the Docker daemon's proxy.
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
| Always-on | desktop app login item | `--role server`: the **`orca-server` container** (Docker Compose, `restart: unless-stopped`, so Docker brings it back after a reboot) running `orca-ide serve --supervise --no-pairing --port 6768 --pairing-address <address>`, with port 6768 published on the private publish address only (§3.3.2); `--role client`: none |
| Pairing | Settings → Remote Orca Servers → New Link | TUI maintenance pairing shows a client link or mobile QR code without restarting Docker; Orca sessions may be interrupted (§3.3.2) |
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
  never a port forwarded to the public internet. `orca serve` itself listens on every interface: the CLI starts orcad
  with `--bind 0.0.0.0` (`orcadServeArgs`, `src/shared/orcad-serve-argv.ts`), the Electron serve path sets
  `exposeNetworkByDefault`, and `--pairing-address` only changes the address it advertises ("changes only the
  client-advertised address", `src/cli/specs/serve.ts`). So a Linux server limits the port by Docker's port
  publishing instead (§3.3.2).
- **Credentials**: integration credentials (Linear etc.) are sealed with a per-machine key in `~/.orca`; GitHub tokens
  stay in `gh`. Nothing for this repository to handle.
- **Single host mode**: never run `orca-ide serve` next to a desktop app that already shares the same machine.

#### 3.3.2 Linux server (Docker) and client roles

`--apply --role server --pairing-address <address> [--publish-address <ipv4>] [--workdir <dir>] [--upgrade-image]` on
Linux (design: §6.7, §6.7's P5.1 note):

1. **Docker Engine.** A host without Docker gets Docker Engine from Docker's apt repository through the verified path
   of `--containers` (§3.5): the baseline rows `manifest/server-host.tsv` names (`curl`, `ca-certificates`, `gnupg`),
   then the `containers` rows. A working Docker installed any other way (CLI, reachable daemon, Compose plugin: Docker's
   convenience script, the distribution's packages, a CI runner) is used as it is and never changed; packages from
   another source (`manifest/apt-conflicts.tsv`) count as such even where orca-setup's repository is set up already.
   Podman (as the `docker` command or on its own), Docker packages without a `docker` command, a missing Compose plugin
   and a daemon that does not answer are refused with the reason. Nothing else is installed on the host: no Node.js,
   agents or Orca `.deb`.
2. **The docker group.** `sudo usermod -aG docker $USER` when the user is not a member and Docker does not already
   answer the user without it (rootless Docker, for example); the group is root-equivalent (its members control the
   Docker daemon), and `--plan` says so. The running session only gets the group at its next
   login, so until then `setup.sh` runs `docker` through `sg docker`, which asks for nothing because the group
   database already lists the user (`NOTE docker runs through "sg docker" in this session`).
3. **Directories.** Every mount of `manifest/server-mounts.tsv`, created as the user when missing (an existing one
   must be a directory the user owns): the workdir (`--workdir`, else the one the last `--apply` recorded in
   `compose.yaml`, else `~/orca`) with `projects/` and `workspaces/`, `~/.orca` (Orca's user data: pairings, the device
   registry, sealed integration credentials), and the agents' directories `~/.codex`, `~/.claude`, `~/.config/gh`,
   `~/.gemini`, `~/.antigravity`, `~/.grok`, `~/.dsh`, `~/.dsh-tui`, `~/.pi` and `~/.omp`. Then the container's home
   `~/.local/share/orca-setup/home` (`$XDG_DATA_HOME` honoured) with the mount points inside it, so that Docker never
   creates one as root, and `~/.config/orca-setup/docker/manifest-local`, a copy of this checkout's `manifest/local/`
   (refreshed when it differs), which the container reads read-only as its own overlay (§3.7). A local
   `server-mounts.tsv` row that is not a plain relative path stops the run before anything changes.
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
   - the compose project's own bridge network (`<project>_default`) and exactly one published port,
     `"<publish address>:6768:6768/tcp"`: Docker binds port 6768 on that host address only and forwards it to the
     container, where `orca-ide serve` listens on every interface (§3.3.1); the host's other addresses, a public one
     included, do not answer on it. `hostname:` is the host's name, as on the host network before P5.1: Orca shows it
     to clients as the server's name and records it in its profile locks;
   - `restart: unless-stopped` (Docker brings it back after a reboot), `init: true`, `pull_policy: never`, and the
     command `orca-ide serve --supervise --no-pairing --port 6768 --pairing-address <address>`;
   - `user: <uid>:<gid>` of the user and `HOME` set to the user's home path; a read-only root filesystem with a tmpfs
     `/tmp`, every capability dropped and `no-new-privileges`; no `sudo` and no Docker in the image;
   - the container's home is `~/.local/share/orca-setup/home`, so a file written outside the mounts either persists
     there or fails (the root filesystem is read-only), and the mounts above are bind-mounted at the same absolute
     path (`create_host_path: false`: a missing directory is an error, never created as root);
   - the `json-file` log driver (rotated at 10 MB, three files), whatever the daemon's default is, so a removed
     container takes its log with it.
7. It waits up to 120 s (`ORCA_SETUP_SERVE_WAIT`) until `orca-ide status --json` inside the container reports the
   runtime reachable (the reply is read there and never printed), then installs the missing skills and aligns the
   settings with `docker exec <server-container> /opt/orca-setup/setup.sh --apply --role server`, the image's copy of these
   scripts.

A second run with the same arguments prints only `PRESENT` lines and the role report. `--pairing-address` is the
private IPv4 address or host name that clients dial (Tailscale, LAN, WireGuard; §1): loopback (`127.0.0.0/8`,
`localhost`), wildcard (`0.0.0.0`, `*`, `::`), broadcast and malformed values are refused. IPv6 literals are not
accepted; use a host name. The CI job on GitHub's runner advertises `127.0.0.2` through the test-only
`ORCA_SETUP_TEST_LOOPBACK_PAIRING_ADDRESS=1` (never `127.0.0.1`), because the runner has no private route; do not set
it on a real device. A systemd user unit `orca-serve.service` that an earlier orca-setup wrote (its first line marks
it) would share `~/.orca` and port 6768 with the container, so `--apply` stops until it is removed and `--plan` shows
how (`systemctl --user disable --now orca-serve.service`, remove the file, `systemctl --user daemon-reload`).

**The publish address.** `--publish-address <ipv4>` is the host's own private IPv4 address that Docker publishes port
6768 on; nothing else is published. Without the flag an IPv4 `--pairing-address` is used. A host name needs the flag,
because clients may resolve it to an address the server itself never sees (a VPN mapping, for example), and so does an
IPv4 pairing address that no interface of the host has. The address must be a plain dotted IPv4 address that
`ip -4 -o addr show` lists for one of the host's interfaces; loopback, wildcard, broadcast and multicast addresses are
refused (the CI override above also allows `127.0.0.2`, which `lo` answers). `compose.yaml` records it next to the
pairing address (`x-orca-setup`, `publish-address`): a re-run without the flag keeps it, except that a default (the
recorded pairing address) follows a new `--pairing-address`, and a different address changes `compose.yaml` and so
re-creates the container. `--plan` shows the endpoint (`publish  <address>:6768 (...); port 6768 is not reachable on
this host's other addresses`). `--check` reads the running container's actual bindings (`docker container inspect`)
and reports `Published endpoint: <address>:6768`; anything else counts as `WRONG (...)`: another or a wildcard
address, more ports, or a container from before P5.1 on the host network. The address must exist when Docker starts
the container: after a reboot that happens as soon as the daemon runs, so an address on an interface that comes up
later (a VPN interface such as Tailscale's or WireGuard's) needs `docker.service` ordered after it (a systemd drop-in
with `After=` and `Wants=` that interface's unit); otherwise Docker cannot bind the port, the container stays stopped
(`--check`: `INACTIVE`), and `docker compose start` in `~/.config/orca-setup/docker` (or `--apply`) starts it later.

**Docker's networking on the host.** Port publishing uses Docker Engine's bridge networking, which turns on IPv4
forwarding (`net.ipv4.ip_forward=1`) and adds Docker's own iptables chains and NAT rules; when Docker has to turn
forwarding on itself, it also sets the policy of the iptables `FORWARD` chain to `DROP`, which stops other forwarded
traffic on the host (a router, a VPN subnet router or exit node) unless that traffic has rules of its own. Its
published-port rules act before the `INPUT` rules of firewall front ends such as `ufw`, so the publish address, not
the host firewall, decides which address answers on port 6768. `--plan` says so; `setup.sh` changes no daemon
setting.

**Inside the container** `setup.sh` knows where it runs (the image sets `ORCA_SETUP_CONTAINER=orca-server`): `--plan`
and `--check` cover the image's tools, Orca and the logins and leave Docker, the image and the mounts to the host;
`--pairing-address`, `--publish-address`, `--workdir` and `--upgrade-image` are refused there and the host modules
(`--power`, `--containers`, `--gpu`) skipped.

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

**Independent Orca process control.** Newly applied deployments run a persistent Python process manager
inside the server container. Setup copies it to `~/.config/orca-setup/docker/orca-service.py` and mounts it
read-only at `/opt/orca-service.py`; existing locked images can use it without an image upgrade.
The manager resolves the installed CLI through `lib/detect.sh` and starts the normal supervised server.
The TUI separates **Start/Stop/Restart Orca process** from **Start/Stop/Restart deployment**.
Process controls use `compose exec -T` and a private Unix socket in container `/tmp`; they do not stop
containers, gateways or independent execution workers. Status describes the CLI process, not runtime readiness.
An intentional stop stays stopped until Start, Restart or a container restart. If the CLI supervisor itself
exits, the container stays up and process status records its exit code; use Start after investigating.
A stop waits up to 60 seconds for the tracked CLI to exit. It never force-kills descendants or starts a
replacement after a timeout. A failed or missing controller never falls back to restarting Docker.

For manual process status, use your generated Compose file:

```sh
docker compose -f ~/.config/orca-setup/docker/compose.yaml exec -T orca-server python3 /opt/orca-service.py status
# Replace status with start, stop or restart to control only Orca.
```

Existing deployments need one **Apply** during a maintenance window to adopt the new command and mount.
Apply and image/configuration changes can still recreate containers. Orca shutdown can interrupt its own
sessions, so container continuity does not establish continuity for every agent.

**Maintenance pairing (Orca downtime, container stays running).** In the management page choose
**Pair a client** or **Pair a mobile device**, review the interruption notice, then confirm **Yes, pair**.
The container manager stops the tracked Orca process and starts the same CLI with its existing address,
port and profile, without `--supervise` or `--no-pairing`. Mobile mode adds `--mobile-pairing` so Orca emits
its terminal QR code and link. The normal server and pairing server never run concurrently.

On your Mac, paste the client offer into **Settings → Remote Orca Servers → Add Server**; on mobile, scan
the displayed QR code. After pairing, press **Enter**, answer **y** to the exit confirmation, wait for recovery,
then press Enter to return to
management. Answer **n** or an empty line to keep pairing; **Ctrl-C** remains a shortcut to exit. Heartbeats
continue while the confirmation is open. Normal Orca restarts if it was running before pairing; a previously stopped Orca stays stopped.
The host checks the restored process state, not successful enrollment: verify connection on the client.

Offers stream directly through a private Unix socket and `docker compose exec -T` to the interactive terminal.
They are never written to Docker logs, temporary files or captured by the setup helper. Use a trusted terminal
without session recording; terminal scrollback still contains what was displayed. Do not copy offers into logs.
The host supplies a heartbeat through exec stdin. If the TUI/SSH process disappears, EOF or a 10-second lease
expiry makes the container manager stop pairing and restore the previous service state. Graceful shutdown can
add up to 60 seconds. A stop timeout never force-kills descendants or launches a second runtime; inspect process
status and resolve the failed stop before retrying. No recovery path restarts Docker or a gateway.

This is maintenance pairing, not live pairing: Orca connections and Orca-owned sessions can be interrupted.
Independent workers and executor/gateway containers stay running. Older managers are detected before any stop;
use **Apply** in a maintenance window to install the updated manager, then reopen the pairing action.
For the same interactive flow outside the TUI, from the setup checkout run:

```sh
python3 lib/server-manage.py pair-mobile   # mobile QR/link; Enter opens exit confirmation
python3 lib/server-manage.py pair          # desktop client offer; same downtime and recovery
```

The currently supported upstream runtime requests `agent-state-rules-engine-1-stable` or `-next` release assets
that may not exist (HTTP 404). This optional update falls back to local rules; it is independent of pairing.
The terminal relay explains this exact warning without hiding other errors. The current public settings API
rejects the internal `agentStateRulesLiveUpdates` switch, so setup does not edit the runtime database or pretend
to disable that request. Eliminating the request requires an upstream fix or supported configuration interface.

Unattended installation never starts pairing. Tests use synthetic offers; no account or real pairing credential
is created by automated pairing tests.

**Interactive shells and mutual container SSH.** New server images include zsh, OpenSSH and a pinned,
checksum-verified Oh My Zsh under `/opt/oh-my-zsh`. No shell framework downloads or automatic updates happen at
container startup. Each writable HOME gets a `.zshrc` only when absent; existing files are never replaced.
Custom plugins live under `~/.config/oh-my-zsh/custom`, cache under `~/.cache/oh-my-zsh`, and history in
`~/.zsh_history`. Orca and executor retain separate personal homes and a shared project directory.
Interactive SSH uses zsh; application commands still select their own Bash/Python interpreter.

Enable mutual SSH in the same server TOML (also available in the TUI server settings):

```toml
[server]
internal_ssh = true
# Keep your existing server address, image and storage settings.
[network]
mode = "isolated"
```

A compatible image carrying `org.orca-setup.internal-ssh=1` is required. Older locked images are refused;
explicitly build/select or upgrade an image before applying. SSH is disabled by default for existing installs.
Both daemons run as the regular container UID on their control-network IPv4 address, port 2222. There is no
published host SSH port, root login, password authentication, agent forwarding or SSH port forwarding. The
firewall permits only the other container's control address; Orca-to-executor SSH bypasses the proxy redirect.

Setup generates deployment-only client and host keys locally under the generated Docker directory's `ssh/`.
It mounts only the corresponding `orca/` or `executor/` identity directory into each container, read-only at
`/run/orca-ssh`. It never imports host SSH private keys or changes host `authorized_keys`/sshd configuration.
Peer host keys are pinned, private identities persist across recreation, and uninstall retains them. A full
host-home mount may also expose the deployment directory, consistent with the trusted-peer model; these paths
are not a security boundary between peers. The SSH
client uses a system include for these two aliases, preserving existing user SSH configuration:

```sh
# Inside the Orca container:
ssh executor
# Inside the executor container:
ssh orca
# Either container, including when mutual SSH is disabled:
zsh
```

SSH and the application have separate supervised processes. Stopping/restarting Orca for pairing leaves SSH
running; an intentional Docker restart still ends all sessions. Both containers are trusted peers: although the
executor's direct public egress remains blocked/proxied as configured, it can execute a network command through
`ssh orca`, using Orca's network. SSH forwarding restrictions do not turn an unrestricted remote shell into an
isolation boundary. This option deliberately enables that shared trust model.

#### 3.3.3 Optional isolated networking and LAN-only execution

Linux server hosts can opt in with `--network-mode isolated`; new installs default to `direct`, preserving §3.3.2.
The selected mode is recorded in `x-orca-setup.network-mode` in the generated Compose file and kept on later runs.
Returning to unrestricted bridge egress requires an explicit `--network-mode direct`. A missing or invalid policy
in isolated mode stops `--apply` before any changes; it never enables direct egress as a fallback. Changing topology
stops the previous stack before starting the new one so the private port has only one owner; work and account mounts
remain, but running commands and sessions are interrupted, as with an image upgrade.

```text
Mac --private published port--> Orca --transparent TCP/DNS--> existing proxy --> Internet / AI providers
                                 |
                                 +--private control network--> executor --allowed IPv4 CIDR/port--> LAN
```

The same digest-locked image supplies four services:

| Service | Permissions and network behavior |
|---|---|
| `orca-server` | Same UID:GID, state mounts and read-only root as before; joins `orca-gateway`'s network namespace without capabilities. Proxy environment variables are explicitly empty; TCP is transparently redirected regardless of application proxy support. |
| `orca-gateway` | Dedicated namespace owner, root with only `NET_ADMIN` and `NET_BIND_SERVICE`; `redsocks` forwards TCP to the existing SOCKS5 or HTTP CONNECT endpoint. A loopback DNS forwarder sends both UDP and TCP DNS queries through that proxy, using certificate-verified DNS-over-HTTPS by default. Owns the private `<publish address>:6768` binding; no other host port is published. |
| `orca-executor` | Same UID:GID, a separate persistent home, only the shared workdir mounted; no Orca state, agent login directories, local overlay or Docker socket. Runs the non-interactive command service on the private control address, port 7777. Public access is blocked, direct or proxied according to `executor.internet`. |
| `executor-gateway` | Dedicated executor namespace owner; allows direct traffic to explicit private IPv4 CIDR/protocol/port rules and an optional private DNS server. Public access is blocked by default; direct or transparent proxy egress is opt-in. Proxy mode uses `NET_ADMIN` and `NET_BIND_SERVICE`, other modes use `NET_ADMIN`. |

The gateway namespaces are connected to a dedicated internal control bridge and an outbound bridge. Firewall rules
inside each namespace default to DROP, including forwarding; applications cannot change them. Orca can reach the
executor's command port directly, and the executor can call Orca's control port directly. IPv6 is blocked. Orca and
proxied executor egress support TCP and forwarded DNS; other public UDP is blocked. In executor direct mode public
IPv4 protocols use the host route; private destinations remain restricted to explicit rules. Approved executor UDP
ports work directly. Docker's embedded DNS is disabled in these namespaces to avoid a resolver bypass. This is more
than setting `internal: true` or proxy environment variables: unapproved outgoing connections are actually blocked.

**Configure on the target device with one TOML (recommended).** Python 3.11 or newer is required on the Docker host
only when using TOML. Ubuntu 24.04 and Debian 12 provide compatible Python versions. Copy the tracked template:

Alternatively, run `./setup.sh --tui` from an interactive terminal on the Linux server, or add `--config FILE` to
select a TOML. The full-screen interface provides a highlighted navigation list and contextual explanations.
Review the sections from top to bottom: server/storage, Orca proxy/DNS, executor access, LAN rules, limits and
file locations, followed by Restore configuration, Preview plan and Install. There is no separate setup wizard
or Save button.
Moving between settings immediately updates the right-hand configuration preview, without entering the editor.
It shows the relevant addresses, paths, proxy endpoint, DNS, executor rules or limits. `*` marks unsaved changes
with the previous saved value; authentication values stay hidden, including in change summaries. PgUp/PgDn scroll
the preview, independently of the menu. These are configuration values, not live deployment status.
Use arrow keys (or `j`/`k`) and Enter to select; Esc cancels the current section without keeping partial edits.
Text fields support cursor keys, Home/End, Backspace/Delete and Ctrl-U to clear. Password input is masked, and
Enter keeps the existing password. Without a generated deployment, the installation page opens with the first
configuration section selected. Account sign-in and lifecycle actions appear
only in management; a saved TOML by itself does not count as an installation.
Changes stay in memory until **Install & start server**, **Apply changes** or **Apply & upgrade image** is confirmed.
The action validates the draft, automatically backs up any existing TOML and saves it atomically with mode 0600
before running setup. Validation or backup failure prevents replacement and deployment. Reapplying identical
content creates no additional backup. Saving keeps settings but rewrites TOML formatting and comments.
**Preview plan** works on current unsaved edits using a private temporary TOML, which is removed afterward;
relative paths still resolve against the selected configuration's directory. It never saves the draft, creates
a backup or changes the deployment. The plan output may mention its temporary configuration path.
The configuration path stays visible in the footer. **File locations** and
the pre-apply review show generated Compose/network files, Orca home, executor home, shared workdir and temporary
`/tmp` locations, along with the backup directory. Review the configuration and choose **Install & start server**;
Preview plan is optional. Installation, applying changes and image upgrade each require an explicit confirmation.
The deployment review shows the current settings and file locations with **Yes** / **No** buttons fixed at the
bottom of the same screen. Up/Down or PgUp/PgDn scrolls the review; Left/Right or Tab selects a button and Enter
confirms it. No is selected initially, and Esc returns to editing without saving or deploying.
Command output and sign-in temporarily use the regular terminal; Enter
returns to the interface afterward. A failed command displays its exit status.
If setup fails after saving, the new TOML remains saved and the previous version stays available for recovery;
the UI does not claim that the deployment succeeded or silently roll running containers back.

**Configuration history.** Before overwriting a TOML, the TUI saves its exact previous bytes (including comments)
under `<configuration-file>.backups/`, for example `~/.config/orca-setup/server.toml.backups/`. Filenames include a UTC
timestamp; the directory is mode 0700 and backups are 0600. Backups can contain inline proxy authentication, so
they are excluded from Git and Docker build contexts and must remain outside the executor home and shared workdir.
External authentication files are not copied. Backups are retained until the user removes them.
**Restore configuration** lists backups newest first and loads the selected version into the editor for review.
Install or Apply saves and deploys that version, backing up the current TOML first. Loading or cancelling a restore
does not change files or running containers. A malformed current TOML opens a recovery notice so backups remain
accessible. These are TOML backups, not snapshots of images, image locks or user data; image upgrades remain explicit.

Successful installation starts the selected image and opens **Server management**. Later TUI launches open management
automatically when this user's generated Compose exists, including when the server is stopped. The page shows
the applied client/listen addresses, container states and a local TCP port check. **Refresh status** updates the
snapshot; a successful TCP check does not establish client reachability or pairing.
Management provides **Start installed server**, **Stop server**, **Restart server**, **Uninstall server**, **Pair a client**, **Pair a mobile device** and
**Sign in to accounts**. Start/restart use the applied Compose and locked image without pulling or adopting TOML
edits; stopping preserves all data. Sign-in runs interactively in the terminal; pairing entries confirm Orca downtime, then stream a link or QR code while keeping containers running. **Edit configuration**
opens an editor for the existing deployment, with **Apply changes**, explicit image upgrade and **Back to management**;
it has no installation wizard, account or lifecycle menu. Esc in the editor returns to management, confirming
before discarding unsaved changes. Esc at the management root quits; cancelling a management dialog stays in management.
Management operations are serialized with `manage.lock` beside the generated Compose. Opening either page is
read-only; the user explicitly starts every install, lifecycle or login operation. Pairing never implies permission to stop a service.
**Uninstall server** shows the deployment and a removal/retention summary with Yes/No confirmation. It removes this
Compose project's containers and networks, retaining the TOML and its backups, image lock, images, private proxy
volumes, user home and shared workdir. It does not uninstall Docker. After successful removal, generated Compose
is archived as `docker/compose.uninstalled.yaml` and the TUI returns to installation with the saved settings.
Future launches also open installation, remembering the previous TOML location. If removal fails, the active
Compose remains available for recovery. Reinstall reuses the retained data and locked image.

**Deployment names.** New installs use a stable Compose project name `orca-<uid>-<12-character-hash>`, derived from
the user's generated Docker configuration directory. Containers share that prefix, for example
`orca-1000-a1b2c3d4e5f6-server`, `-gateway`, `-executor-gateway` and `-executor`; Docker networks become
`orca-1000-a1b2c3d4e5f6_control` and `_outbound` in isolated mode. Service keys such as `orca-server` stay unchanged,
so `docker compose exec orca-server ...` still works from the generated Compose directory. Restart and upgrade keep
the names. Existing deployments retain their recorded project and legacy names; uninstalling and reinstalling an
old deployment adopts the new names. Management displays the project and refuses mutations when its containers
belong to another installation directory. Separate installations still need separate data directories, listening
addresses and non-overlapping control subnets; unique names alone do not isolate shared profiles or published ports.
The interface uses Python's standard-library `curses` (no pip packages), requires a terminal at least 64×20,
supports resizing and scrollable lists/pages, and uses reverse-video selection when colors are unavailable or
`NO_COLOR` is set. Connect using `ssh -t` with a valid terminal type (`TERM`); `dumb` terminals are refused.
Without a selected or recorded TOML, the menu uses `~/.config/orca-setup/server.toml`. The normal no-argument
`./setup.sh` remains a read-only plan.

```sh
cp orca.example.toml orca.toml
chmod 600 orca.toml
# Edit the server, proxy and private executor rules in this file on the target device.
./setup.sh --config orca.toml                 # read-only plan
./setup.sh --config orca.toml --apply
./setup.sh --config orca.toml --check
./setup.sh --config orca.toml --apply --upgrade-image
```

`orca.toml` is ignored by Git and Docker builds. The default lookup is `./orca.toml`, then the last applied TOML
path recorded in Compose; an explicit `--config FILE` selects another file. A missing recorded TOML is an error;
`--no-config` explicitly selects the legacy CLI/manifest path. Authentication commands (`--auth-*`) continue to run
separately. No arguments still mean read-only `--plan`. Public CLI flags override matching TOML fields. Paths in
TOML support `~`; relative paths resolve against the TOML's directory. Unknown keys and malformed values fail before
apply. TOML networking, executor rules and limits replace their legacy local manifest settings; tool inventories,
Orca settings/skills and data mounts keep their existing manifest behavior.

The [complete template](orca.example.toml) includes `[server]`, `[network]`, `[proxy]`, `[dns]`, `[executor]`,
`[[executor.allow]]` and `[limits]`. Proxy `address` is a numeric IPv4 endpoint reachable from Docker, not an SS URI
or a subscription. For authenticated SOCKS5/HTTP CONNECT, set both `username` and `password` directly under `[proxy]`.
Such a file must be caller-owned with mode 0600 or 0400, and must live outside the checkout or at its ignored root
`orca.toml`. It must also be outside the shared workdir and executor data mounts, so execution commands cannot
read the source credentials. Do not put it in `manifest/local/`, which is copied into application containers. When
the full host home is mounted for Orca, a TOML inside that home is readable by the Orca process as the same user.
An optional external
`auth_file` remains supported, mutually exclusive with inline credentials.

Inline credentials are piped over stdin into a temporary, network-disabled container that writes a root-owned
mode-0600 file in a dedicated Docker volume. Only `orca-gateway` mounts that volume, read-only at `/run/secrets`.
No password is written to Compose, generated public policy, command arguments, Docker environment, labels or an
image. `--plan` never creates a volume or publishes credentials; `--check` compares the running gateway's private
file without changing it. `--apply` synchronizes changes and recreates the stack when its gateway detects changed
authentication. The volume persists across container removal/reboots; removing it requires reapplying the TOML.
The executor's separate proxy authentication, when configured, uses a separate private volume mounted only by
`executor-gateway`. The TOML remains the only user-maintained input; Compose, policy/resolver files and the private volume are generated
runtime state. Docker administrators can access that volume, just as they can access other container state.

`server.image_source = "registry"` (default) pulls and locks the configured image's registry digest. For an image
already built or loaded on the host, set `image_source = "local"` and `image = "your-image:tag"`: setup locks its
`sha256` content ID without a pull or temporary registry. Later applies keep that ID even if the tag moves;
`--upgrade-image` explicitly adopts the current tag. A missing locked local image fails instead of pulling. In TOML
mode the configured image is authoritative: a legacy `manifest/local/Dockerfile` is not built automatically. Build
any custom image first and name it in TOML. All four services use the same locked image, which must contain the
gateway/executor scripts from this version of the repository. If an existing registry image lock predates these
scripts, explicitly pass `--upgrade-image` when applying after the updated image has been published.

**Home directory and persistence.** `[server] home_mount = "host"` bind-mounts the entire host home at the same
path into `orca-server` as the current UID:GID. New TUI configurations and the template choose `host`; configurations
without this field and legacy CLI configurations retain the earlier `dedicated` home. The executor keeps its own
home and mounts only the shared workdir, so files written there appear in Orca without exposing the host home to the
executor. Orca can read and write everything in the host home, including its keys, accounts and a TOML stored there.
Only `/tmp` is a tmpfs; the image root remains read-only, so persistence is for writable mounts, not arbitrary system
directories. Changing home mode recreates the server and interrupts sessions. The previous dedicated home remains at
`~/.local/share/orca-setup/home` on disk and is not copied or merged automatically: files that existed only there are
not visible at their former home paths in host mode. For a custom workdir in host mode, `~/orca` must already be a
symlink to that workdir; setup refuses rather than altering an existing host directory.

**Executor public access.** `executor.internet` defaults to `"blocked"`; `"direct"` permits public IPv4 directly via
the host route, and `"proxy"` transparently proxies public TCP. Private CIDRs are still restricted to
`[[executor.allow]]` in every mode. In proxy mode, omit `[executor.proxy]` to reuse the Orca proxy or set its `type`,
`address`, `port` and optional authentication independently; a failed proxy never falls back to direct Internet.
Public DNS goes through that proxy by default. An explicitly configured `executor.dns` is a private resolver reached
directly and may receive the executor's DNS queries. Direct mode without a private DNS uses `dns.address` directly.
The executor still requires `orca-exec`; upstream Orca does not automatically move ordinary shell commands into it.
The gateway scripts for the selected modes must exist in the locked image; after updating this repository use
`--apply --upgrade-image` once when the installed image predates these features. Direct and proxy modes check the
image's `org.orca-setup.executor-network=1` label before replacing the stack; custom images must retain that label and
the current gateway scripts. The default blocked mode remains compatible with older isolated-network images.

**How the generated Compose sets up the gateways.** See the [rendered, annotated example](examples/compose.generated.yaml).
`orca-server.network_mode: service:orca-gateway` shares the gateway's network namespace: the two containers have the
same interfaces, routes, firewall and loopback, while retaining separate filesystems and users. Only the gateway
owns the published port. `orca-executor` similarly shares `executor-gateway`'s namespace. Both gateways attach to
the internal control bridge and the outbound bridge; the namespace firewall determines which traffic can use the
outbound route. There is no custom `ipam.gateway` or default-route change to another container: setting a Docker
bridge gateway alone does not create a proxy. `gateway.sh` installs transparent TCP redirection to `redsocks`,
proxy-only DNS and DROP policies inside the relevant namespace. The executor instead has direct private CIDR/port
exceptions and no proxy. Editing the generated YAML is unnecessary; edit TOML and run `--apply`.

**Legacy configuration (still supported).** Without TOML, create `manifest/local/server-network.env` using the tracked example:

```sh
mkdir -p manifest/local
cp manifest/local.example/server-network.env manifest/local/server-network.env
# Edit the proxy address/port and optional private executor DNS on this device, then inspect the plan:
./setup.sh --plan --role server --network-mode isolated --pairing-address <private-address>
./setup.sh --apply --role server --network-mode isolated --pairing-address <private-address> --upgrade-image
```

The explicit image upgrade is needed once if the locked image predates the gateway tools. Later runs keep that
image; updates still use `--upgrade-image` for Orca and all sidecars together. No additional gateway image or runtime
package installation is needed. A custom `manifest/local/Dockerfile` continues to extend the locked image.

Only the keys in `manifest/server-network.env` are accepted (data only, never sourced as shell):

| Key | Meaning |
|---|---|
| `proxy_type` | `socks5` or `http-connect` |
| `proxy_address`, `proxy_port` | Reachable unicast IPv4 literal and port of an existing proxy endpoint; loopback, URLs and inline authentication fields are refused. A host-side proxy must listen on an address reachable from Docker, not only host loopback. |
| `proxy_auth_file` | Optional absolute path to an external, root-owned mode-0600 JSON file with exactly `username` and `password`. Provision it separately on the target; keep the parent directory traversable so setup can stat the file. Setup only checks its existence and renders the path, never reads or copies its contents. Compose mounts it as a secret only into `orca-gateway`. Empty by default. |
| `dns_address` | IPv4 resolver reachable from the proxy exit, default `1.1.1.1`. All DNS forwarding travels through the proxy. |
| `dns_transport` | `https` (default): DNS wireformat POST to `/dns-query` over TLS on port 443. `tcp`: traditional DNS over TCP/53; the proxy must explicitly permit it. There is no direct fallback. |
| `dns_tls_name` | TLS certificate name, SNI and HTTP host for DoH, default `cloudflare-dns.com`. The connection uses `dns_address` directly, so bootstrap DNS is unnecessary; certificate verification stays enabled. |
| `executor_dns` | Optional private IPv4 resolver reached directly on TCP/UDP 53. Empty by default: the executor has no external DNS. Use a private resolver that knows the internal names your workloads need. |
| `control_subnet` | Canonical private `/24` for the Docker control bridge, default `172.30.70.0/24`; choose a non-overlapping range. Orca and executor use its `.2` and `.3` addresses. |

Add direct LAN exceptions in `manifest/local/server-network-allow.tsv`: four tab-separated columns, `name`, canonical
private IPv4 CIDR, `tcp` or `udp`, and one destination port. Public ranges, broad `0.0.0.0/0`, host bits in a subnet,
port ranges and executable values are refused. The shipped file has no rules; local rows follow the usual overlay
merge by name. Exceptions use destination addresses, not domain suffixes; if an internal name resolves to a public
address, the executor still cannot connect. Narrow rules to the services needed: an allowed internal relay could
itself offer access beyond that LAN, which destination filtering cannot inspect.

**Run a workload.** From an Orca terminal inside the server container:

```sh
cd <shared-workdir>/projects/<project>
orca-exec -- pnpm test
orca-exec --cwd <shared-workdir>/projects/<project> -- sh -c 'cmake --build build && ./build/tests'
printf 'input' | orca-exec --stdin -- python3 script.py
```

`orca-exec` preserves arguments, binary stdout/stderr and the command's exit code. It checks that the working
directory resolves inside the shared workdir (including symlinks), supplies EOF on stdin unless `--stdin` is given
(up to 1 MiB), and allocates no TTY. Environment and agent credentials are not forwarded. Disconnection terminates
the remote process group; transport/request failures return 125, never execute locally. Builds write as the host
user and persist in the shared workdir. Install additional workload tools in the image through the existing local
Dockerfile; fetch dependencies from permitted LAN mirrors or prepare them in Orca first.

Orca and its agents still start in `orca-server`: this feature provides an explicit execution command, not a change
to upstream Orca's shell dispatch. Use `orca-exec` for commands that require the LAN-only execution environment;
ordinary shell commands keep Orca's proxied network. The command service trusts Orca's private control address,
publishes no host port, and executes arbitrary user-requested commands as the same user. It is not a tenant isolation
boundary. No Docker socket or Docker API is exposed to an agent.

**Failure and readiness.** Applications start after their gateway is healthy. A failed proxy endpoint or daemon
cannot cause direct fallback because filtering and redirection remain installed. An upstream proxy outage leaves
the private Orca connection and direct LAN execution available. Stopping/replacing a namespace-owning gateway
container can also interrupt its application's private connectivity; `--apply` recreates the stack when a sidecar
is absent/unhealthy or an application refers to an old namespace. Firewall changes make a gateway unhealthy.
`--check` reports policy drift and gateway/executor health; JSON adds `server.network-mode="isolated"`. These checks
attest local policy/namespace health, not AI provider availability, IP reputation or the provider-observed exit IP.
The upstream proxy must itself select the intended exit; this project cannot prevent its operator from changing
nodes or using an exit pool. A fixed endpoint alone does not prove a fixed public IP.

Policy changes are included in the Compose checksum and recreate all four services. Healthchecks and `--check`
are read-only, and plans do not create policy files, install tools or contact the proxy. Only approved credential-free
values are written into the generated `network/` directory. The optional gateway secret is read only inside the
gateway and converted to its mode-0600 `/tmp/redsocks.conf` on tmpfs; it is never put in environment variables,
image layers, Compose labels, the overlay or logs. Rotating it makes gateway health stale until `--apply` recreates
the stack. Authentication values are limited to 1-255 printable ASCII characters. Setup does not import any proxy
credentials, subscriptions or SS keys; authenticated SOCKS5/HTTP CONNECT consumes an already provisioned file.

A fresh Orca profile may prepare its native runtime by downloading it before `status` becomes reachable. Working
proxy DNS/HTTPS is therefore required even before agent login; gateway process health alone does not verify it.

**Host bootstrap and image pulls remain separate.** Docker daemon traffic does not originate in these namespaces.
Supply the host's apt/private routes and, if needed, daemon/build proxy configuration yourself; no host-wide TUN or
custom host firewall rules are installed. The first image must be pulled using working host networking (or loaded in advance),
before a gateway from that image can start. Docker itself still manages host bridge/NAT rules as described in §3.3.2;
the additional filtering rules here live only in the sidecars' network namespaces. Protect the existing proxy
endpoint's listener separately.

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
the host runs `docker exec --interactive [--tty] <server-container> /opt/orca-setup/setup.sh --auth-<name>` (a terminal gets
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
    the current `compose.yaml`), for a running container its `Published endpoint` (`<publish address>:6768 (not
    reachable on this host's other addresses)`, else `WRONG (...)` with what it publishes instead, §3.3.2), and every
    mounted directory (`Mount <path>`: `ok`, `MISSING` or `WRONG OWNER`), plus
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
  "container", "endpoint", "workdir"}` from the host (`endpoint`: what the running container publishes, such as
  `192.0.2.10:6768`, `host` for the host network, or `none`), or `"host": "not-checked"` when it ran inside the
  container alone, and its `device` is the host's. P5 and P5.1 only added keys; the schema stays
  `orca-setup-check/1`. It holds names, states, counts and versions only, never credential values, and exits with the
  same code. `remote/provision.sh` reads it instead of parsing the text (§5.2).
- Orca's version: `VERSION orca <installed> (latest release <version>)`, from `<orca> --version` and the latest stable
  release of the repository the Linux `.deb` comes from (`manifest/baseline.tsv`, through the GitHub API; `unknown`
  when it cannot be read). Reported only: `setup.sh` never upgrades Orca (§3.3.1).
- Exit code = number of missing items, usable directly as an acceptance condition. Counted: `MISSING` tools and
  agents from the manifest (and from the modules given), a missing Orca CLI, an unreachable Orca runtime (not on a Linux client), missing Orca
  skills, on a Linux server a missing or unreachable Docker, a missing docker group, image lock or mounted directory
  (or one owned by someone else), a missing, stopped or stale container and one that publishes anything but port 6768
  on the publish address, a `PENDING` GitHub login or Codex
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
and `manifest/local/Dockerfile` is built on top of the locked Orca server image and runs instead (§3.3.2). The setup.sh
inside the container (skills, settings, `--check`) reads the copy of `manifest/local/` that the last `--apply` put in
`~/.config/orca-setup/docker/manifest-local`, so an overlay change reaches it with the next `--apply`. Overlay auth
modules are not implemented yet.
`manifest/local/server-network.env` and `server-network-allow.tsv` configure optional isolated container networking
and the LAN-only executor (§3.3.3). They hold no credentials. Removing them while isolated does not enable direct mode.

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
   Linux: ./setup.sh --apply --role server --pairing-address <address> [--publish-address <ipv4>]
          (Docker Engine, the orca-server container; port 6768 published on the private address only)

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
- `--role server` never runs `orca environment add`; `--role client` never prints a runtime pairing code.
  Unattended setup never creates a pairing offer. On Linux the normal server uses `--no-pairing`; TUI maintenance pairing requires explicit confirmation and an intentional maintenance window (§3.3.2).
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
[--publish-address <ipv4>] [--task-source linear] [modules] [--destination <dir> | --path <dir>] [--fast-forward]`
runs on the control machine and wraps steps 2–5 for one paired device. Everything goes through the public Orca CLI
(resolved like setup.sh's, `lib/detect.sh`); the device needs nothing but its paired Orca server.

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
   runs `./setup.sh --plan`, then `./setup.sh --apply --role server [--pairing-address ...] [--publish-address ...]
   [modules] [--task-source ...]`, then `./setup.sh --check --json --role server [modules] [--task-source ...]`;
   `--check` runs only the last one. Both addresses go to `--plan` and `--apply`; provision.sh checks only the form of
   `--publish-address`, and the device checks that one of its interfaces has it. The device's report is read from the
   JSON (§3.6), never from the text.
   **On a Linux server in Docker** `--plan` and `--check` run there as well (the plan without `--pairing-address` and
   `--publish-address`, which belong to the host's `compose.yaml`; the check covers the container's side and the
   summary points to `./setup.sh --check` on the host), but `--apply` is refused (exit 100) before setup.sh runs:
   right after the terminal opens on an existing checkout, after making the checkout otherwise. The container has no
   `sudo` and no Docker and cannot change its host, so the server is installed and updated on the host over SSH
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
| **P5 Linux server in Docker** | the Linux server runs Orca and every agent in a container from `ghcr.io/vzxxbacq/orca-server`; the host gets only Docker Engine; work and data directories are bind-mounted at the same paths; the native server path (systemd unit, linger, host agents and `.deb` on a server) is removed; Linux clients unchanged (§6.7) | implemented and accepted on CI (2026-10-26): every PR builds the image, and the runner VM, with its preinstalled Docker used as it is, runs `--apply --role server` twice with it from a local registry (the second run a no-op), reaches the runtime through `docker exec`, finds no pairing URL in any output, status reply or container log, keeps mounted data across `docker compose down && up` owned by the runner user, refuses writes outside the mounts, counts only the two logins, and moves to a newer image with `--upgrade-image`; pushes to `main` publish the image with a provenance attestation. **Pending**: everything in §6.6 |

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
- `--role server` added linger and the `orca-serve` user unit (P5 replaced both with the container, §6.7) and requires
  `--pairing-address`; `--role client` installs Orca only. Skills and settings follow on both, as on macOS.
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

### 6.6 Pending real-device acceptance (P2–P5.1)

Run in one session with a laptop as the control machine (client) and a real Linux x86_64 machine (Ubuntu 24.04 or
Debian 12) as the new server; nothing here is covered by CI, and no pairing secret ever leaves the two machines.

0. **The image** (once, after the first publish from `main`): make the package `ghcr.io/vzxxbacq/orca-server` public
   in GitHub's package settings, then check it on the laptop:
   `gh attestation verify oci://ghcr.io/vzxxbacq/orca-server:main --repo vzxxbacq/orca-setup`.
1. **P5, host install** (an SSH session on the server): `git clone https://github.com/vzxxbacq/orca-setup
   ~/orca/projects/orca-setup`, then `./setup.sh --plan --role server --pairing-address <private address>` (plus
   `--publish-address <the server's private IPv4 address>` when the pairing address is a host name or one the server
   does not have) and the same with `--apply`. Expect `publish  <private address>:6768`, Docker Engine from Docker's
   repository (or an existing Docker kept as it is), the `sudo usermod` step and the `sg docker` note, the image pulled
   and its digest locked, the container running. A second `--apply` prints only `PRESENT` lines; `./setup.sh --check`
   counts only the GitHub login and the Orca Codex account and reports `Published endpoint: <private
   address>:6768`. After `sudo reboot` and a new login the container is back (`docker ps`; for an address on a VPN
   interface see §3.3.2), `id` lists `docker`, and `--check` is unchanged.

   **P5.1, exposure**: `docker port orca-server` lists only `6768/tcp -> <private address>:6768`. From the laptop,
   `nc -vz <private address> 6768` connects and `nc -vz <public address> 6768` does not (on a VPS with an accepting
   firewall, the public address is the one to try); on the server, `sysctl net.ipv4.ip_forward` and
   `sudo iptables -S FORWARD | head -n 1` show what Docker changed (§3.3.2), and anything else that forwards traffic
   on the host still works.
2. **P2, pairing**: create a link with the container stopped (§3.3.2, `docker compose run --rm --service-ports`), save
   it on the laptop with `read -rs code && orca environment add --name <server> --pairing-code "$code"`, run `clear` on
   the server, and check `orca status --environment <server>` on the laptop. Confirm `docker compose logs orca-server` (from the generated Compose directory) holds
   no pairing URL.
3. **P4, provisioning**: on the laptop, `remote/provision.sh --environment <server>` (plan only; it recognises the
   Docker server), `remote/provision.sh --environment <server> --apply --path ~/orca/projects/orca-setup` (registers
   the checkout, then refuses with the pointer to the host), and `remote/provision.sh --environment <server> --check`
   (exit code = the container's pending logins). Also check that provision.sh refuses on the server itself, and run
   `./setup.sh --check --gpu` on a machine with an NVIDIA GPU.
4. **P3 and P5, logins** (SSH on the host): `./setup.sh --auth-gh` (device code), `--auth-codex`, `--auth-claude`,
   `--auth-linear` (into the server's Orca) and `--auth-agy`, each inside the container; then check that they survive
   `docker compose down && docker compose up --detach` (in `~/.config/orca-setup/docker`), and whether agy's sign-in
   survives at all without a Secret Service (§9, open question 1).
5. **P3, modules on hardware**: `--power` on the host (sleep targets masked; the BIOS setting by hand).
6. **P2 and P5, remote work**: `orca worktree create --environment <server> --project <x> --agent codex ...` from the
   laptop; the worktree appears under `~/orca/workspaces` on the host, owned by the user, and the agent finds its
   login. Also whether `computer-use` can drive an app under Xvfb in the container.
7. **P5, upgrade**: once `main` has a newer image, `./setup.sh --check` reports `Newest image: newer one available`,
   and `./setup.sh --apply --role server --pairing-address <private address> --upgrade-image` re-creates the
   container with pairings, logins and worktrees intact.
8. **Done when** `./setup.sh --check` on the host and `remote/provision.sh --environment <server> --check` on the
   laptop both exit 0.

### 6.7 P5: Linux server in Docker (decided and implemented 2026-10-26)

Replaces the native Linux server (§3.3.1, §3.3.2) with a container. Linux clients and macOS are unchanged. The plan
below is as decided; how it was built, and where it differs, follows at the end of this section.

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

- `docker compose`, `network_mode: host` (port 6768 and the pairing address need no mapping; **superseded by P5.1**:
  the compose project's bridge network with port 6768 published on the private publish address only, see the P5.1
  note at the end of this section), `restart: unless-stopped` (Docker brings it back after a reboot), `init: true`;
  the command is `orca-ide serve --supervise --no-pairing --port 6768 --pairing-address <address>`.
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

- Pairing: TUI maintenance pairing switches only the Orca process, streams the client link or mobile QR code,
  then restores the previous service state. Orca sessions may be interrupted; containers stay running (§3.3.2).
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
`docker exec`, that only `127.0.0.2:6768` is published and answers (P5.1; also for the pairing command), that no
output, container log or journal holds a pairing URL, that a file written in a mounted directory survives
`docker compose down && up` owned by the runner user, and that writing outside the mounts fails.
A publish job runs only on pushes to `main`.

**Implementation notes and deviations.**

- *Where things live.* `lib/docker-host.sh` (Docker Engine, the group, `sg docker`), `lib/orca-server.sh` (address,
  workdir, mounts, `compose.yaml`, `image.lock`, the container, `--check`, the logins), `docker/` (`Dockerfile`,
  `build.sh`, `entrypoint.sh`, the `compose.yaml` template), `manifest/server-host.tsv`, `server-mounts.tsv` and
  `server-limits.env`. The manifest row helpers moved from `setup.sh` to `lib/rows.sh` so the image build reuses
  them; Linux client and macOS output is unchanged, except one line of the role-less Linux plan, which named the
  removed unit and now says `Orca server: --role server --pairing-address <ip-or-host> runs it in Docker instead`.
- *Image layout.* The tools under `/opt/orca-agents` keep the user-level layout (`.local/bin`, `.grok/bin`), because
  the same code installs them (`npm --prefix ~/.local`, the official installers, uv) with the prefix as `HOME` during
  the build. Xvfb and `libnss-extrausers` are `image` rows of `manifest/baseline.tsv`.
- *The container's user.* The image cannot know the host UID and its root filesystem is read-only, so
  `libnss-extrausers` also reads `/var/lib/extrausers`, a link to the container's `/tmp`, where the entry point writes
  the user's entry (git, ssh and Node.js's `os.userInfo()` need one); the base image's `ubuntu` user (UID 1000) is
  removed. Beyond the plan the container also drops every capability and sets `no-new-privileges`.
- *Workspace directory.* Not written by `setup.sh`: upstream offers no RPC or CLI for a headless host's
  `workspaceDir`, and its default is `~/orca/workspaces` (§3.3.2). With the default `--workdir` that is exactly
  `<workdir>/workspaces`. **Deviation**: with another `--workdir`, Orca's paths read `~/orca/workspaces/...` (a link to
  the workdir in the container's home), not the same path as on the host.
- *`~/.claude.json`.* `CLAUDE_CONFIG_DIR=~/.claude` moves it into the mounted `~/.claude` (§3.3.2); no single file
  is mounted.
- *Mounts* (`manifest/server-mounts.tsv`): `~/orca` (`--workdir`), `~/.orca`, `~/.codex`, `~/.claude`, `~/.config/gh`,
  `~/.gemini`, `~/.antigravity`, `~/.grok`, `~/.dsh`, `~/.dsh-tui`, `~/.pi`, `~/.omp`; the container's home
  `~/.local/share/orca-setup/home` keeps everything else (`~/.gitconfig`, `~/.agents/skills`, caches).
- *Role check.* It runs in a throwaway, read-only `docker run` of the image before the container starts, because the
  host has no Node.js; the `--apply` inside the container then skips it (`ORCA_SETUP_ROLE_CHECKED=1`).
- *Image lock.* `image.lock` records `source=` (the tag pulled) and `image=` (the digest); a locked image missing from
  the host is pulled by digest. `manifest/local/Dockerfile` is built with the locked image as `ORCA_SERVER_IMAGE`
  and tagged by a checksum of its directory and base (`local=` in the lock). `ORCA_SETUP_IMAGE` must name a pullable
  image; CI serves the image it built from a local registry, so the PR job exercises the same pull and digest path.
- *`--check` newest digest* comes from `docker buildx imagetools inspect` (registry only, nothing pulled) and is
  `unknown` without buildx. The JSON report gained a `server` object and reports the host as `device`.
- *`remote/provision.sh`* recognises a Docker server from its terminal (`ORCA_SETUP_CONTAINER`,
  `/etc/orca-server-image`; §5.2). **Deviation**: on a device without a checkout, `--apply` still makes one (clone or
  registration) before it refuses, because a remote terminal can only open in a checkout.
- *Limits* are whole-container Compose options (`mem_limit`, `memswap_limit`, `pids_limit`, `cpus`), not the unit's
  per-terminal `ORCA_TERMINAL_*` limits, which need systemd.
- *Publish job.* `actions/attest-build-provenance` runs with `create-storage-record: false`: artifact storage records
  exist only for organization-owned repositories (and would need `artifact-metadata: write`). The job has
  `contents: read` besides the three write permissions, for the checkout.
- *Not covered by CI*: pairing, the logins, a pull from GHCR (CI pulls from its local registry), a reboot, and a host
  without Docker (bats covers that install path against fakes; the client containers install Docker Engine for real).
- A pre-P5 native unit (`orca-serve.service` with orca-setup's marker) stops `--apply --role server` until removed.
- *Overlay and logs.* The image has no `manifest/local/`; the host's is copied to
  `~/.config/orca-setup/docker/manifest-local` and mounted read-only at `/opt/orca-setup/manifest/local`, so local
  settings and skills apply inside the container. The service pins the `json-file` log driver so that the pairing
  run's log is removed with it whatever the daemon's default driver is.
- *P5.1: the port on one private address (2026-10-26).* The first real server is a VPS with a public interface and an
  accepting firewall, where the host network made port 6768 answer on every host address, the public one included:
  upstream's `orca serve` listens on every interface and `--pairing-address` only changes the advertised address
  (§3.3.1). Decided by the project owner: Docker port publishing, so the port is exposed only on the internal
  address. `docker/compose.yaml` drops `network_mode: host`; the container runs on the compose project's default
  bridge network, and the only published port is `"<publish address>:6768:6768/tcp"`. The new `--publish-address
  <ipv4>` (Linux server hosts only, like `--pairing-address`) defaults to an IPv4 `--pairing-address` and is required
  for a host name; it must be an IPv4 address of one of the host's interfaces (`ip -4 -o addr show`), not loopback,
  wildcard, broadcast or multicast (CI's loopback override allows `127.0.0.2`). It is recorded in `compose.yaml`
  (`x-orca-setup`): a re-run keeps it and a change re-creates the container. `--plan` shows the endpoint and Docker's
  forwarding and iptables changes; `--check` reports the running container's bindings as `Published endpoint` and
  counts anything else (`WRONG`); `--check --json` adds `server.endpoint`. The pairing command gained
  `--service-ports`. `remote/provision.sh` forwards `--publish-address` like `--pairing-address` (never into the
  container). Beyond the brief: **the container keeps the host's name** (`hostname:` in `compose.yaml`), because a
  bridge-network container would otherwise be named after its id, which changes on every re-create, and Orca shows
  `os.hostname()` to clients as the server's name and records it in its profile locks (`runtime-machine-name.ts`,
  `orcad-instance-lock.ts`); and **a default publish address follows the pairing address**: a recorded address that
  equals the recorded pairing address was the default, so a new `--pairing-address` replaces it instead of leaving
  the port on an address clients no longer dial (an address given explicitly is kept). Other ports that processes in
  the container open (a dev server in a worktree, for example) are no longer reachable on the host's addresses.

---

## 7. Test strategy

- Compose rendering reads the complete mount inventory before emitting bind mounts, avoiding asynchronous
  producer exits during Bash 3.2 output on macOS; a failed inventory aborts rendering.
- `tests/bats/network.bats` covers isolated topology rendering, mode persistence, validation before changes,
  idempotence, policy drift and explicit return to direct mode. Existing direct-mode tests remain unchanged in scope.
- `python3 -m unittest discover -s tests/python -v` exercises actual executor sockets/subprocesses, binary streams,
  exit codes, cwd/symlink validation, cancellation, background-process cleanup and DNS framing, with no credentials.
  Terminal tests cover navigation previews, masking, resizing, cancellation, automatic saving, private backups,
  restoration, draft plans and automatic management routing. Management tests cover deployment scoping,
  maintenance confirmation, legacy manager refusal, disconnect recovery and safe uninstall failure handling.
- The Linux server CI job runs the three lifecycle/SSH tests below against the image built from the PR's
  `docker/Dockerfile`, after baseline and network integration. Each step uses a clean environment and a time limit.
  They are required by the existing publish dependency; PRs never publish images. Pairing fixtures use synthetic
  offers, while the native-runtime test uses `--no-pairing` with a fresh container home.
- `ORCA_SETUP_TEST_IMAGE=<shell-capable-image> python3 tests/integration/internal-ssh.py` checks mutual SSH,
  non-root PTYs and zsh/Oh My Zsh, pinned identities, persistent user files, application-stop survival and blocked
  executor egress behind actual gateway firewalls. Only disposable containers and fresh identities are used.
- `ORCA_SETUP_TEST_IMAGE=<local-server-image> python3 tests/integration/service-native.py` tests native Orca stop/start
  in a disposable container with a fresh home and no published ports. It may download the native runtime; no host
  profile is mounted. This checks independent workers, not Orca-owned agent continuity.
- `ORCA_SETUP_TEST_IMAGE=<local-server-image> python3 tests/integration/tui-management.py` exercises process and deployment start/stop/restart,
  uninstall and reinstall in real Docker with direct and shared gateway namespaces. It invokes both pairing actions
  while an independent worker writes a heartbeat, and verifies synthetic offer streaming, Ctrl-C and killed-host
  recovery, an unchanged container ID/start time, continued worker activity and an unchanged gateway. Synthetic
  offers must not appear in Docker logs. No real pairing offer or account data is created. Each fixture
  uses a unique Compose project and removes only its own resources. Run as a regular Docker user with
  loopback `127.0.0.2:6768` available.
- `tests/integration/network.sh` runs after the existing Linux server integration on the GitHub-hosted VM. A local
  fixture supplies unauthenticated/authenticated SOCKS5, HTTP CONNECT, DNS and LAN TCP/UDP services; real packets verify proxy routing, allowed and
  denied executor ports, DNS/IPv6 restrictions, no direct fallback on proxy failure, private control availability,
  idempotence and firewall-drift recovery. It never contacts an AI provider or a live proxy. A Docker daemon is
  required; passing unit/protocol/schema checks alone does not constitute packet-level or real-device acceptance.
  The fixture reuses only public native-runtime artifacts downloaded by the preceding direct-network test; profile,
  settings and authentication files are not copied into the new container home.

Manual network acceptance on 2026-10-26 used Ubuntu 24.04 x86_64, Docker Engine 29.9.2 and Compose 5.6.1, with a
separately provisioned authenticated SOCKS5 endpoint. Setup ran as a disposable non-root user with fresh Orca data.
Twenty-one baseline checks, eight fault checks and six recovery checks passed: transparent HTTPS/DoH, private port
binding, LAN-only execution/RPC, blocked public egress and Docker DNS bypass, no direct fallback during a forced proxy
outage, preserved private control access from a Mac, unhealthy-policy reporting, recovery and persistent work data.
The original container was restored and temporary authentication removed. Provider probes carried no API credentials;
HTTP 401/403 confirms transport only. This does not complete the interactive pairing/account acceptance in §6.6.

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
    installed, no server container may be set up, and `--check` must count only the interactive GitHub login;
  - `server` directly on GitHub's Ubuntu 24.04 runner VM (systemd), as the runner user, with the image built from the
    commit (`docker/Dockerfile`) and pushed to a local registry (`registry:3`, pinned by digest) that
    `ORCA_SETUP_IMAGE` names: `--apply --role server --pairing-address 127.0.0.2 --power --containers --gpu`
    (test-only override, §3.3.2) twice. The second run must run no step and leave the packages, apt sources,
    `compose.yaml`, `image.lock` and the container itself unchanged; the runner's preinstalled Docker (packages, apt
    sources, group) must be used as it is and stay unchanged; the container must run on the compose project's bridge
    network (`<project>_default`) with the runner's host name, a read-only root filesystem, `restart:
    unless-stopped` and an init, as the runner's UID:GID with `HOME` at the runner's home path, without `sudo` or
    `docker`, and with every baseline tool, agent and image tool on its `PATH`; `orca-ide status --json` inside it
    must report the runtime reachable; `docker port` must list only `127.0.0.2:6768` (the publish address, defaulting
    to the pairing address), Orca must answer HTTP there from the host, and a TCP connection to port 6768 on the
    runner's primary address (its default route's, `eth0`) and on `127.0.0.1` must fail, after the first run, after a
    re-create, after the upgrade, and for the documented pairing command (`docker compose run --rm --service-ports`,
    run with `--no-pairing` added so that no offer exists); `--check` must report `Published endpoint:
    127.0.0.2:6768` and `--check --json` the same `endpoint`; neither the setup output, the status reply
    nor `docker logs` may contain a pairing URL; a file written in `~/orca/projects` (and one in the container's home)
    must survive `docker compose down && up` owned by the runner user, and writes to `/opt`, `/etc`, `/usr/local` and
    `/` must fail; the sleep targets must be masked; `--check` must count only the GitHub login and the Orca Codex
    account; and after a newer image is pushed to the same tag, a plain re-run must keep the locked digest while
    `--upgrade-image` locks the new one and re-creates the container with the data intact.
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
- **Linux server in Docker** (`tests/bats/server-docker.bats`) runs against a fake Docker CLI and daemon, a fake
  registry and `sg`, whose `exec` and `run` run the in-container `setup.sh` and `role.sh` in the sandbox: the server
  `--plan` snapshot, Docker Engine's fresh install with the group and `sg`, an existing Docker used as it is, Podman
  and broken Docker refused, the rendered `compose.yaml` (UID:GID, home, no host network but exactly one published port
  on the publish address, the host name, read-only, tmpfs, mounts at the same path, limits), the publish address
  (the IPv4 pairing address by default, required for a host name, refused when malformed, loopback, wildcard,
  broadcast, multicast or missing from a fake `ip`, the CI loopback override, refused on clients, macOS and inside the
  container, recorded and kept by a re-run, a new one re-creating the container, a default following the pairing
  address), the published endpoint in `--check` (counted on another or a wildcard address, with more ports or on
  the host network), `--workdir`, the image lock and `--upgrade-image`, the local Dockerfile, the role check before
  the start, the logins through `docker exec`, the combined `--check` (text and JSON, with and without a running
  container), and `setup.sh` inside the container; no output may carry the fake pairing URL. `provision.bats` also
  covers forwarding `--publish-address` and refusing a malformed one.
- **CI**: the same workflow runs shellcheck, `node --check` and bats on `ubuntu-latest` and `macos-latest`. The Linux
  jobs also pass `--gpu` (the runners have no NVIDIA GPU) and check that `--check --json` reports the same missing
  count as `--check`. Remote provisioning is not run end to end in CI (§6.5). On pushes to `main` only, a publish job
  builds the image again with `docker/build-push-action`, pushes `ghcr.io/vzxxbacq/orca-server:main` and
  `:sha-<commit>`, and attests its build provenance (`actions/attest-build-provenance`); every action is pinned by
  commit, and only that job has `packages`, `id-token` and `attestations` write permissions.
- **macOS regression**: on an already provisioned Mac run only `--plan` / `--check` (no re-installs).
- **Security regression**: grep the audit output to ensure no token/key-shaped strings; CI fails on host names, private IPs or internal URLs in tracked files.
  The bats fake of `orca-ide status` carries a pairing URL, and every Linux Orca test (the server's included, whose
  status replies pass through the fake container) asserts it never reaches the output.

---

## 8. Risks

| Risk | Mitigation |
|---|---|
| `orca-rpc.cjs` depends on Orca internals (`out/cli/runtime-client.js`) and RPC method names (`settings.update`, `accounts.list`, `linear.status`, `files.writeBase64`), which may change between versions | use the public CLI wherever possible; keep all RPC calls under `orca/`; `--check` fails loudly instead of silently when a probe fails |
| On Linux, `orca` collides with the GNOME screen reader | `detect.sh` resolves the CLI name in one place; scripts must never hardcode `orca` |
| Support for `agy`, `computer-use` etc. on Linux is uncertain | verify feasibility before P2/P3; mark them macOS-only in the manifest if unsupported (`computer-use` has an upstream Linux helper and stays installed, §3.3) |
| A pairing URL leaks through logs or scrollback | normal containers run with `--no-pairing`; maintenance pairing streams directly to a trusted terminal without Docker logging or offer files, during deliberate Orca downtime (§3.3.2). Unattended tests never create offers. |
| The `.deb` download is tampered with | GitHub's per-asset sha256 digest and the package's control fields are checked before `apt-get` sees the file; no digest, no install (§3.3.1) |
| Browser login on headless Linux | prefer device-code flows (codex, gh); otherwise print a URL for the user to finish on any machine (Linear; agy prints its own over SSH) |
| agy cannot keep its sign-in on a headless server (no unlocked Secret Service keyring) | documented in §3.4; `--auth-agy` warns without SSH or D-Bus; `setup.sh` never handles keyring passwords; verified on real hardware (§6) |
| `--containers` or a Linux server replaces or upgrades a Docker or Podman someone installed another way | `--containers` is skipped when a conflicting package (`manifest/apt-conflicts.tsv`) or a foreign `docker`/`podman` exists; a server uses a working foreign Docker as it is and refuses Podman or a broken Docker; CI checks the runner's preinstalled Docker stays unchanged |
| The docker group is root-equivalent | only added by the explicit `--containers` module, or by `--apply --role server`, which needs Docker; `--plan` and the README say so |
| The Orca server image is tampered with, or changes under a running server | the base image is pinned by digest, its tools pass the same key and digest checks as on a client, the image is published only from `main` with a build provenance attestation (`gh attestation verify`), and a host runs the digest locked in `image.lock` until `--upgrade-image`. The image's agents are the latest releases at build time, as on a client |
| A process in the server container reaches beyond its user | it runs as the user's UID:GID with every capability dropped, `no-new-privileges`, a read-only root filesystem, no `sudo` and no Docker socket, on its own bridge network (since P5.1); it still shares the mounted directories, which hold the user's logins |
| Orca's port answers on a public address of the server (a VPS with a public interface and an accepting firewall) | upstream's `orca serve` listens on every interface and `--pairing-address` only changes the advertised address, so the container no longer uses the host network: Docker publishes port 6768 on the private `--publish-address` only, which must be an address of one of the host's interfaces (§3.3.2); `--check` counts any other binding; CI checks that the runner's primary address and `127.0.0.1` refuse the port |
| Docker's bridge networking changes the host's forwarding and firewall | it turns on IPv4 forwarding, adds its own iptables chains and NAT rules, and may set the `FORWARD` policy to `DROP`, which can stop other forwarded traffic (a router, a VPN subnet router or exit node); its published-port rules act before `ufw`-style `INPUT` rules. Documented in §3.3.2 and printed by `--plan`; `setup.sh` changes no daemon setting; the real-device run checks it (§6.6) |
| The publish address does not exist yet when Docker starts the container after a reboot (an address on a VPN interface) | Docker cannot bind the port and the container stays stopped; `--check` counts it `INACTIVE`; §3.3.2 says how to order `docker.service` after that interface; the reboot step of §6.6 covers it |
| Orca's workspace directory or other internals change upstream | `setup.sh` relies only on Orca's documented default (`~/orca/workspaces`) and never writes Orca's profile state; a different default shows up in `--plan` and in the real-device run (§6.6) |
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
| Linux form factor | headless server first, driven remotely; since P5 it runs in the `orca-server` container (§6.7) |
| Agent baseline | codex, claude, dsh, agy, pi, grok, omp; gemini is optional (not usable with personal accounts) |
| Task source | opt-in (`--task-source linear`); not set by default |
| Node on Linux | NodeSource 24.x apt repo |
| Containers on Linux | Docker Engine |
| GPU | detection only, in P4 |
| Linux architecture | x86_64 only; no arm64 |
| Network | not managed by `setup.sh`; the user provides the private route and passes the address to advertise (and, on a Linux server, the host address to publish Orca's port on) |
| Fedora/RHEL | not now; `pkg-fedora.sh` is kept as a placeholder |
| Agent install source | npm whenever a package exists (§3.2); grok and agy use their official installers |
| Orca on Linux | official `.deb` from GitHub releases (§3.3.1): installed on a client; on a server inside the image, run as `orca-ide serve --supervise` in the container (§3.3.2; until P5 under a systemd user unit) |
| Linux server address | `--pairing-address <ip-or-host>` is required for `--apply --role server`; loopback and wildcards are refused |
| Linux server port (2026-10-26, P5.1) | no host network: Docker publishes the container's port 6768 only on the server's private `--publish-address` (default: an IPv4 `--pairing-address`; required for a host name; an address of one of the host's interfaces), recorded in `compose.yaml`; the container keeps the host's name (§3.3.2, §6.7) |
| Pairing link on a Linux server | normal containers run with `--no-pairing`; TUI maintenance pairing displays a client link or mobile QR and restores Orca without restarting containers (§3.3.2) |
| P2 acceptance | accepted on CI; pairing from a laptop client to a real Linux x86_64 machine is pending (§6) |
| `computer-use` on Linux | installed: upstream ships a Linux AT-SPI helper; it needs a graphical session to drive apps (§3.3) |
| agy sign-in on a headless host | `--auth-agy` runs agy, which prints a URL over SSH; keeping the session needs an unlocked Secret Service keyring, which `setup.sh` does not set up (§3.4) |
| Docker on Linux | Docker Engine from Docker's apt repository, key fingerprint `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88`; a foreign Docker or Podman is left alone (§3.5) |
| Android tools on Linux | the distributions' `android-sdk-platform-tools` (older than Google's zip); skipped with a pointer to the zip where apt lacks it |
| P3 acceptance | accepted on CI; the interactive logins on a real headless server are pending (§6) |
| Remote provisioning | `remote/provision.sh` on the client, through the public Orca CLI only (setup-clone or an existing checkout, an Orca terminal, `--check --json`); read-only by default; never handles passwords or runs `--auth-*` (§5.2) |
| GPU module | `--gpu`: NVIDIA detection on Linux only, never installs; counts a missing driver next to an NVIDIA GPU (§3.5) |
| Linux server form (2026-10-26) | Docker container from GHCR (`ghcr.io/vzxxbacq/orca-server`) with work, Orca data and agent login directories bind-mounted at the same paths; native server path removed; no Docker inside the container; Linux clients stay native (§6.7) |
| P5 implementation (2026-10-26) | image digest locked per host (`image.lock`, `--upgrade-image`); Claude's state file through `CLAUDE_CONFIG_DIR=~/.claude`; Orca's workspace directory left at its default (`~/orca/workspaces`); provision.sh recognises a Docker server from its terminal and refuses `--apply` there; accepted on CI, real-device acceptance pending (§6.6) |
| P4 acceptance | covered by bats against a fake server; a laptop client provisioning a real Linux server is pending (§6.6). CI does not pair a second runtime, so no pairing secret exists in CI (§6.5) |

**Open**

1. agy's interactive sign-in on a real headless server, now inside the container, which has no Secret Service at all:
   whether the session survives a new SSH login and a container re-create (upstream issues #53, #950). If not, decide
   whether to document a keyring inside the image or the `GEMINI_API_KEY` route (§3.4).
2. P3 real-device acceptance (pending): `--auth-gh` device code, `--auth-linear` into the server's Orca, and
   `--containers` / `--power` on real hardware.
3. P2 and P5 real-device acceptance (pending): pair a laptop client with a real Linux x86_64 server set up by
   `--apply --role server` (in Docker), then `orca worktree create --environment <server> --agent codex` from the
   client; also check whether `computer-use` can drive an app under Xvfb in the container.
4. P4 real-device acceptance (pending): `remote/provision.sh` from a laptop client to that server (`--plan`, the
   refused `--apply`, `--check`), including the unverified CLI details listed in §6.5. All pending items are collected
   in §6.6.

---

## 10. References

- Original macOS scripts this plan generalizes: `setup-mini.sh`, `install-agy.sh`, `orca-rpc.sh`, `orca-rpc.cjs`, `audit-readiness.cjs`, `linear-login.cjs` (kept outside this repository).
- Orca CLI: `orca serve` (`--supervise` adapts to launchd/systemd), `orca environment add`, `orca project setup-clone`, `orca skills install`, `orca account add`, `orca vm recipe doctor` (`environmentRecipes` in `orca.yaml`, a possible direction for VM automation after P4).
- Repository conventions (language, style, ground rules): [`AGENTS.md`](AGENTS.md).
