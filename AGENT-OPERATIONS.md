# Agent operations manual

Use this manual to install and manage Orca from the command line, without the TUI.
Run commands from the `orca-setup` checkout on the target host as the deployment's
regular user. Repository editing rules are in [AGENTS.md](AGENTS.md).

## Before making changes

1. Establish the target device, deployment user and requested operation. Do not run
   `setup.sh` as root or inside the server container to manage its host.
2. Use the existing configuration and deployment when present. Do not overwrite
   a TOML with the example or change storage, addresses or network modes implicitly.
3. Run a plan before installation or configuration changes. Apply, image upgrades
   and deployment restarts can interrupt active work. Use process controls when the
   request concerns only Orca; do not replace them with Docker restarts.
4. Keep authentication interactive on the target. Do not read, copy or log account
   stores, private keys, proxy passwords or pairing offers. Let the user enter
   proxy authentication directly in their private configuration.

A Linux server requires Ubuntu 24.04 or Debian 12 on x86_64. TOML configuration
requires Python 3.11+. The host must already have its private routes and working
network access for package installation and image downloads. Container proxy rules
cannot proxy Docker daemon downloads. Setup does not configure the host VPN.

## Locate the deployment

Default paths (honor `XDG_CONFIG_HOME` and `XDG_DATA_HOME` when set):

| Item | Path |
|---|---|
| TUI-created configuration | `~/.config/orca-setup/server.toml` |
| Active Compose | `~/.config/orca-setup/docker/compose.yaml` |
| Locked image | `~/.config/orca-setup/docker/image.lock` |
| Generated policy and resolvers | `~/.config/orca-setup/docker/network/` |
| Internal SSH identities | `~/.config/orca-setup/docker/ssh/` |
| Dedicated Orca home, when selected | `~/.local/share/orca-setup/home/` |
| Executor home | `~/.local/share/orca-setup/executor-home/` |
| Default shared workdir | `~/orca/` |

`--config FILE` selects a TOML explicitly. Otherwise setup checks `./orca.toml`,
then the last applied TOML path recorded in Compose. A missing recorded file is an
error; do not silently replace it. `--no-config` selects legacy CLI/manifest mode.
Public CLI flags override TOML values. Relative TOML paths resolve beside the TOML.

The management helper uses the generated Compose under the current user's config
directory, not an arbitrary TOML. A different `--config` path alone does not create
a separate deployment. Keep the same user and XDG environment for every operation.
Use Compose service names rather than guessing generated container names.

## Prepare a new configuration

For a fresh host only, create a private configuration outside the checkout and
shared workdir. The following refuses to replace an existing configuration:

```sh
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/orca-setup"
config_file="$config_dir/server.toml"
mkdir -p "$config_dir"
(umask 077; set -C; cat orca.example.toml > "$config_file")
```

Edit the public settings for the target device. The template contains placeholder
addresses and must not be applied unchanged. See [orca.example.toml](orca.example.toml)
for the complete schema.

| Setting | Meaning |
|---|---|
| `server.pairing_address` | Private address or hostname clients dial |
| `server.publish_address` | Private IPv4 present on a host interface; port 6768 binds only here |
| `server.workdir` | Shared projects and workspaces; defaults to `~/orca` |
| `server.home_mount` | `host` mounts the whole host home into Orca; `dedicated` uses a separate persistent home |
| `server.image` | Registry image tag, or a prebuilt local image tag |
| `server.image_source` | `registry` or `local`; both keep a locked image until explicit upgrade |
| `network.mode` | `direct` or `isolated` |
| `network.control_subnet` | Private `/24` that does not overlap host LAN/VPN routes |
| `proxy.type` | `socks5` or `http-connect`; not an SS URI or subscription |
| `proxy.address`, `proxy.port` | Existing proxy endpoint reachable from Docker; address is numeric IPv4 |
| `executor.internet` | `blocked`, `direct` or `proxy`, in isolated mode |
| `executor.dns` | Optional private resolver reached directly |
| `executor.allow` | Private CIDR, protocol and port exceptions, in every executor Internet mode |
| `server.internal_ssh` | Optional mutual SSH; requires isolated mode and a compatible image |

In executor proxy mode, omit `[executor.proxy]` to reuse Orca's proxy, or configure
that table for a different endpoint. Proxy failure never enables direct fallback.
Without private DNS, proxy mode sends DNS through the proxy too, so a proxy outage
can break internal hostname lookups even when an allowed private IP remains reachable.

The user may enter `username` and `password` under `[proxy]` or `[executor.proxy]`.
A TOML containing them must be caller-owned and mode 0600 or 0400, outside shared
work and executor mounts. Do not print it. Setup writes authentication to private
Docker volumes, not Compose or environment variables. The full host-home mount
still lets Orca read a configuration stored in that home.

For a custom workdir with `home_mount = "host"`, `~/orca` must already be a symlink
to that workdir. Do not replace an existing directory automatically. Changing home
mode does not migrate the old home. The executor always keeps a separate home.

## Plan, apply and verify

Set `config_file` to the actual deployment configuration, then run:

```sh
./setup.sh --config "$config_file" --plan
./setup.sh --config "$config_file" --apply
./setup.sh --config "$config_file" --check --json
```

Plan is read-only. Apply installs missing components, renders runtime files and
starts the deployment. Repeating it keeps the locked image and existing installs.
Do not edit generated Compose, policy or resolver files; edit TOML and apply.

Check emits schema `orca-setup-check/1`. Its exit code is the number of missing
items, so a nonzero result does not by itself mean installation failed. Inspect
`missing`, `items`, `auth` and `server`: pending GitHub/Codex login is distinct from
an unhealthy gateway, stale policy or unreachable runtime. Preserve the exit code
when collecting a report; do not treat every nonzero result as a transport error.

A healthy gateway verifies local policy, not provider access, IP reputation or the
public IP seen by an AI provider. Do not report those as verified without a separate
network probe. Successful pairing also needs confirmation from the client.

## Manage processes and containers

The helper checks deployment ownership and serializes management operations.
These commands act immediately; only invoke the action the task requires.

```sh
python3 lib/server-manage.py orca-status
python3 lib/server-manage.py orca-start
python3 lib/server-manage.py orca-stop
python3 lib/server-manage.py orca-restart
```

These control only Orca inside the running container. Gateways, container SSH and
independent workers stay up, but Orca-owned sessions can be interrupted. Status is
process status, not a readiness check. A failed stop does not force-kill descendants
or start a second runtime. Do not automatically fall back to restarting Docker.

For the entire deployment:

```sh
python3 lib/server-manage.py start
python3 lib/server-manage.py stop
python3 lib/server-manage.py restart
```

Start/restart use the applied Compose and locked image; they do not apply TOML
edits or upgrade images. A deployment restart ends container sessions.

To inspect containers or open a shell when Docker is accessible to this user:

```sh
compose_file="${XDG_CONFIG_HOME:-$HOME/.config}/orca-setup/docker/compose.yaml"
docker compose -f "$compose_file" ps
docker compose -f "$compose_file" exec orca-server zsh
docker compose -f "$compose_file" exec orca-executor zsh
```

The executor exists only in isolated mode. New Docker group membership may require
a new login for these raw Docker commands; setup and the management helper handle
that through `sg docker`. Do not work around group access by running setup as root.

## Pairing and account login

Use a trusted, interactive terminal operated by the user; do not capture its output
in agent logs. Pairing switches the Orca process into maintenance pairing mode.
It leaves containers running but can interrupt Orca sessions. Do not start a second
Orca runtime against the same profile.

```sh
python3 lib/server-manage.py pair
python3 lib/server-manage.py pair-mobile
```

Use one command for the desired client type. Desktop pairing prints an offer;
mobile pairing displays a QR/link. Enter opens the exit confirmation; `y` restores
the prior Orca process state, while `n` or an empty answer keeps pairing open.
Ctrl-C also exits. Terminal loss triggers lease-based recovery. If recovery fails,
inspect `orca-status`; do not restart the deployment automatically.

Login commands run separately from plan/apply and enter the server container:

```sh
./setup.sh --auth-gh
./setup.sh --auth-codex
./setup.sh --auth-claude
./setup.sh --auth-linear
```

The user completes authentication. Never pass account tokens as command arguments
or import another machine's login files. Run check again after login. Antigravity's
`--auth-agy` may not retain its login without a Secret Service keyring in the container.

## Execute with the executor's network

Ordinary Orca shell commands run in Orca, not the executor. From an Orca terminal,
explicitly dispatch commands that need the executor policy:

```sh
cd ~/orca/projects/my-project
orca-exec -- pnpm test
printf 'input' | orca-exec --stdin -- python3 script.py
```

The working directory must resolve inside the shared workdir. Output and the
command's exit code are forwarded; transport failures return 125 with no local
fallback. Environment variables and agent credentials are not forwarded. There
is no TTY; stdin is EOF unless `--stdin` is supplied (up to 1 MiB).

With `server.internal_ssh = true`, use `ssh executor` from Orca or `ssh orca` from
the executor. Setup generates deployment-only identities; do not import host keys.
The two containers are trusted peers: an executor shell can run network commands
through Orca even when its own public access is blocked. SSH is not published on
a host port. Both containers include zsh and Oh My Zsh; existing `.zshrc` is kept.

## Upgrade, recover or uninstall

Update the checkout only if clean; do not discard local changes. An explicit image
upgrade adopts the current registry digest or local image ID and may recreate the
containers:

```sh
git status --short
git pull --ff-only
./setup.sh --config "$config_file" --plan --upgrade-image
./setup.sh --config "$config_file" --apply --upgrade-image
./setup.sh --config "$config_file" --check --json
```

A repository update alone does not update the running image. If a locked image
lacks a requested feature, use a compatible published or prebuilt image; do not
bypass capability checks.

The TUI makes private TOML backups under `<config-file>.backups/` before saving.
Direct CLI edits do not automatically create these backups. Preserve the previous
configuration privately when editing, without exposing credentials. Restoring a
TOML requires another apply and does not roll back images or user data. Do not
attempt automatic rollback by deleting `image.lock` or editing Orca's profile DB.

When the requested action is uninstall:

```sh
python3 lib/server-manage.py uninstall
```

This command has no interactive confirmation. It removes deployment containers and
networks, archives Compose as `compose.uninstalled.yaml`, and retains configuration,
backups, images, volumes, SSH identities and user data. It does not uninstall Docker.
Do not add `down --volumes`, image pruning or home deletion. Reapply the retained
TOML to reinstall using the retained image lock and data.

## Local clients and remote provisioning

For a local macOS or supported Linux client:

```sh
./setup.sh --plan --role client
./setup.sh --apply --role client
./setup.sh --check --json
```

This installs tools locally. It does not start a server container. Each device has
one pairing role; do not erase pairings to resolve a role conflict automatically.
See `./setup.sh --help` for optional modules.

For an already paired device, `remote/provision.sh --environment NAME --plan`
and `--check` run through Orca from the client. They cannot apply host Docker
changes from a terminal inside Orca's container. Manage a Linux Docker server over
host SSH as its deployment user instead. Remote provisioning does not perform login.

For topology details and older manifest configuration, see [DESIGN.md](DESIGN.md).
The [annotated Compose example](examples/compose.generated.yaml) shows gateway
namespaces. Extra firewall rules live in those namespaces; Docker still manages
its normal host bridge/NAT rules.
