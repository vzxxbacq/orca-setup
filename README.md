# orca-setup

Set up an Orca development machine. Linux servers run Orca and its tools in Docker.

Supports macOS (Apple Silicon and Intel), Ubuntu 24.04 and Debian 12 (x86_64).
Run as your regular user, without `sudo`. Running `./setup.sh` alone only shows a plan.

## Install a Linux server

You need Git, Python 3.11+, and a private connection to the server, such as a LAN,
Tailscale or WireGuard. Setup installs Docker if it is missing.

```sh
git clone https://github.com/vzxxbacq/orca-setup.git
cd orca-setup
./setup.sh --tui
```

Set the server address, storage and network options, then select **Install**.
Install saves the configuration and starts the server. Open the same command later
for status, account login, pairing, configuration changes or uninstall.

- **Pairing address:** the private IP or hostname your clients use to reach the server.
- **Publish address:** a private IPv4 address on the server itself. Port 6768 listens here.
- **Network:** choose direct access, or isolated access through an existing SOCKS5 or
  HTTP CONNECT proxy. An SS link cannot be used directly.
- **Executor:** in isolated mode, choose blocked, direct or proxied Internet access.
  Add the private services it may reach.

Docker image downloads use the host's network, not the container proxy.

## Connect and sign in

In server management, choose **Pair a client**. On your Mac, open Orca → Settings →
Remote Orca Servers → Add Server and paste the offer. Use **Pair a mobile device**
for a QR code. When finished, press Enter, then `y` to leave pairing.

Pairing briefly stops Orca, but keeps Docker containers running. Orca sessions may
be interrupted. Use **Sign in to accounts** to log in on the server.

## Where files are saved

These are the defaults; setup shows the selected paths before installation.

| Files | Location |
|---|---|
| Server settings | `~/.config/orca-setup/server.toml` |
| Previous settings saved by the TUI | `~/.config/orca-setup/server.toml.backups/` |
| Generated Compose, network policy and image lock | `~/.config/orca-setup/docker/` |
| Shared projects and workspaces | `~/orca/` |
| Executor home | `~/.local/share/orca-setup/executor-home/` |

The default TUI setup mounts your whole home into Orca. Orca can read and change
files there. The executor has a separate home and shares the project directory.
Files in these mounts survive container replacement; `/tmp` does not.

**Uninstall** removes the containers and networks but keeps settings, images,
volumes and user files. **Restore configuration** loads a previous settings file;
review it and select Apply to use it.

## Update or use the command line

Update this checkout with `git pull --ff-only`. In the TUI, edit the configuration
and select the explicit image upgrade when you want a new server image.
Ordinary Apply keeps the installed image version. Upgrades may interrupt sessions.

To configure a server without the TUI, copy [orca.example.toml](orca.example.toml)
to a private file, edit it, then run:

```sh
./setup.sh --config ~/.config/orca-setup/server.toml --plan
./setup.sh --config ~/.config/orca-setup/server.toml --apply
./setup.sh --config ~/.config/orca-setup/server.toml --check
```

For a local macOS or Linux client:

```sh
./setup.sh --plan --role client
./setup.sh --apply --role client
./setup.sh --check
```

See `./setup.sh --help` for optional tools and login commands.
A check can report pending logins even when installation succeeded.

[Agent command-line manual](AGENT-OPERATIONS.md) ·
[Configuration template](orca.example.toml) ·
[Generated Docker network example](examples/compose.generated.yaml) ·
[Design reference](DESIGN.md)
