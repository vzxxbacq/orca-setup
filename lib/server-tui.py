"""Interactive Linux server configuration; edits stay in memory until installation or apply."""

import contextlib
import copy
import curses
import datetime
import getpass
import importlib.util
import ipaddress
import json
import os
import stat
import sys
import tempfile
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("server_config", ROOT / "lib/server-config.py")
server_config = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server_config)
SCREEN_SPEC = importlib.util.spec_from_file_location("server_tui_screen", ROOT / "lib/server-tui-screen.py")
screen = importlib.util.module_from_spec(SCREEN_SPEC)
SCREEN_SPEC.loader.exec_module(screen)
MANAGE_SPEC = importlib.util.spec_from_file_location("server_manage", ROOT / "lib/server-manage.py")
manager = importlib.util.module_from_spec(MANAGE_SPEC)
MANAGE_SPEC.loader.exec_module(manager)
UI = None

CHOICE_HELP = {
    "isolated": "Proxy all Orca public TCP and DNS. A separate executor controls command network access.",
    "direct": "Use the host Internet route. Private executor access still requires LAN rules.",
    "blocked": "Block executor Internet access. Only explicitly allowed private services are reachable.",
    "proxy": "Send executor public TCP and DNS through a proxy. No direct fallback when it fails.",
    "host": "Mount your entire host home read/write into Orca, including account files. Executor shares only the workdir.",
    "dedicated": "Use a separate persistent Orca home. Existing data stays in that home; nothing is copied automatically.",
    "registry": "Pull the server image from a registry and lock its digest. Upgrades remain explicit.",
    "local": "Use an image already built or loaded on this host. Setup will not pull it.",
    "socks5": "Connect to an existing SOCKS5 endpoint. Enter its reachable IPv4 address and TCP port.",
    "http-connect": "Connect through an existing HTTP CONNECT proxy endpoint.",
    "inline": "Enter authentication here. Install or Apply stores it only in your private TOML (0600). Password input is masked.",
    "file": "Reference an existing root-owned authentication JSON file on this server.",
    "none": "Use a proxy that does not require authentication.",
    "orca": "Reuse the Orca proxy, including its authentication. No separate executor proxy is saved.",
    "separate": "Configure a different proxy endpoint and authentication for the executor.",
    "https": "Certificate-verified DNS-over-HTTPS through the proxy (recommended).",
    "tcp": "Forward DNS over TCP through the proxy.",
    "yes": "Continue with this action.",
    "no": "Keep the current settings and return.",
    "add": "Allow one private IPv4 CIDR, protocol and destination port.",
    "remove": "Remove an existing rule by name.",
    "back": "Finish this section and return.",
}
FIELD_HELP = {
    "Address clients use": "Hostname or IP your Mac uses to reach this server, for example server.example.com.",
    "Private IPv4 address on this host": "Bind port 6768 only to this host's private IPv4 address. Use an address already assigned to the host.",
    "Shared work directory": "Both Orca and executor see files here at the same path. Default: ~/orca. Custom paths in host-home mode require ~/orca to already link there.",
    "Proxy IPv4 address": "Enter a numeric IPv4 address reachable from Docker, not an ss:// link or subscription.",
    "Control network /24": "A private /24 Docker subnet that does not overlap your LAN, VPN or other Docker networks.",
    "Private executor DNS IPv4 (enter - to clear)": "Optional private DNS, reached directly. Leave empty to use the selected public DNS policy; '-' removes an existing value.",
    "Server image": "Docker image name with a tag or digest. A local source requires this image to exist on the server.",
}


def notice(message):
    if UI is None:
        print(message)
    else:
        UI.notes.append(str(message))


def field_error(label, value):
    if label in ("Address clients use", "Private IPv4 address on this host", "Proxy IPv4 address", "Server image", "Rule name") and not value:
        return "A value is required."
    try:
        if "IPv4" in label and value not in ("", "-"):
            if "CIDR" in label:
                server_config.private_cidr(value)
            else:
                server_config.address(value)
        if label == "Control network /24":
            network = ipaddress.IPv4Network(value, strict=True)
            if network.prefixlen != 24:
                return "Use a canonical /24 subnet."
            server_config.private_cidr(value)
        if label in ("Proxy port", "Destination port") and (not value.isdecimal() or not 1 <= int(value) <= 65535):
            return "Enter a port from 1 to 65535."
        if value not in ("", "-"):
            if label.startswith("Process limit") and (not value.isdecimal() or int(value) < 1):
                return "Enter a positive process count, or '-' to clear."
            if label.startswith("CPU limit") and not 0 < float(value) <= 1024:
                return "Enter a positive CPU limit (up to 1024), or '-' to clear."
    except ValueError:
        return "Enter a valid address or private network for this field."
    return ""


class TuiError(ValueError):
    pass


def scalar(value):
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=True)
    if isinstance(value, bool):
        return "true" if value else "false"
    if type(value) in (int, float):
        return str(value)
    raise ValueError("unsupported configuration value")


def serialize(data):
    """Write the supported TOML tables without changing existing values or exposing them."""
    result = ["# Managed with orca-setup. Edit this file on the server; keep it private.", ""]
    for name in server_config.SCHEMA:
        section = data.get(name)
        if not section:
            continue
        if not isinstance(section, dict):
            raise TypeError("invalid table")
        result.append("[" + name + "]")
        for key, value in section.items():
            if not isinstance(value, (dict, list)):
                result.append(key + " = " + scalar(value))
        result.append("")
        for key, value in section.items():
            if isinstance(value, dict):
                result.append("[" + name + "." + key + "]")
                for nested, item in value.items():
                    result.append(nested + " = " + scalar(item))
                result.append("")
            elif isinstance(value, list):
                for item in value:
                    if not isinstance(item, dict):
                        raise TypeError("invalid array of tables")
                    result.append("[[" + name + "." + key + "]]")
                    for nested, entry in item.items():
                        result.append(nested + " = " + scalar(entry))
                    result.append("")
    return "\n".join(result) + "\n"


def configuration_path(path):
    path = Path(path).expanduser()
    if path.is_symlink():
        raise TuiError("configuration cannot be a symbolic link")
    path = path.resolve()
    if path.exists():
        info = path.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise TuiError("configuration must be a regular file owned by the current user")
    return path


def backup_directory(path):
    path = Path(path)
    return path.with_name(path.name + ".backups")


def check_backup_directory(directory):
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise TuiError("backup directory must be a private directory owned by the current user (0700)")


def read_owned_file(path, private=False):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 1024 * 1024
                or (private and stat.S_IMODE(info.st_mode) not in (0o600, 0o400))):
            raise TuiError("configuration backup must be a caller-owned regular file, at most 1 MiB, with private permissions")
        content = source.read(1024 * 1024 + 1)
        if len(content) > 1024 * 1024:
            raise TuiError("configuration is larger than 1 MiB")
        return content


def validate_candidate(temporary, path):
    public, auth = server_config.load(temporary, logical_path=path)
    workdir = Path(public.get("workdir") or Path.home() / "orca").resolve()
    if any(value is not None for value in auth.values()) and path.is_relative_to(workdir):
        raise TuiError("inline credentials must be outside the shared workdir")
    directory = backup_directory(path)
    data_root = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share").expanduser()
    executor_home = (data_root / "orca-setup/executor-home").resolve()
    for exposed in (workdir, executor_home):
        if directory.is_relative_to(exposed) or exposed.is_relative_to(directory):
            raise TuiError("configuration backups must be outside the executor home and shared workdir")
    return public


@contextlib.contextmanager
def staged_configuration(path, data):
    """Validate a private draft without writing the selected config or its directory."""
    with tempfile.TemporaryDirectory(prefix="orca-config-") as directory:
        temporary = Path(directory) / "draft.toml"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(serialize(data))
        validate_candidate(temporary, path)
        yield temporary


def save(path, data):
    """Validate first, back up exact previous bytes, then atomically replace the TOML."""
    path = configuration_path(path)
    with staged_configuration(path, data) as candidate:
        payload = candidate.read_bytes()
        previous = read_owned_file(path) if path.exists() else None
        if previous == payload:
            return None
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        temporary = None
        backup = None
        try:
            with tempfile.NamedTemporaryFile(mode="wb", dir=path.parent, delete=False) as output:
                temporary = output.name
                os.fchmod(output.fileno(), 0o600)
                output.write(payload)
                output.flush()
                os.fsync(output.fileno())
            if previous is not None:
                directory = backup_directory(path)
                directory.mkdir(mode=0o700, exist_ok=True)
                check_backup_directory(directory)
                stamp = datetime.datetime.now(datetime.UTC).strftime("%Y%m%dT%H%M%S%fZ-")
                with tempfile.NamedTemporaryFile(mode="wb", prefix=stamp, suffix=".toml", dir=directory, delete=False) as output:
                    backup = Path(output.name)
                    os.fchmod(output.fileno(), 0o600)
                    output.write(previous)
                    output.flush()
                    os.fsync(output.fileno())
            os.replace(temporary, path)
            temporary = None
            return backup
        finally:
            if temporary is not None:
                os.unlink(temporary)


def list_backups(path):
    directory = backup_directory(path)
    if not directory.exists() and not directory.is_symlink():
        return []
    check_backup_directory(directory)
    return sorted((item for item in directory.glob("*.toml") if not item.is_symlink() and item.is_file()), reverse=True)


def load_backup(path, backup):
    path = configuration_path(path)
    if backup.parent != backup_directory(path):
        raise TuiError("select a backup belonging to this configuration")
    check_backup_directory(backup.parent)
    content = read_owned_file(backup, private=True)
    try:
        data = tomllib.loads(content.decode("utf-8"))
    except (UnicodeError, tomllib.TOMLDecodeError):
        raise TuiError("backup contains invalid TOML (values hidden)") from None
    with staged_configuration(path, data):
        pass
    return data


def restore_configuration(path, data):
    backups = list_backups(path)
    if not backups:
        UI.page("No configuration backups yet", "The previous TOML is backed up automatically before Install or Apply replaces it. No files were changed.")
        return data
    choice = UI.choose("Restore configuration", [
        (str(index), item.name, "Load this previous TOML into the editor. Review it, then Install or Apply to save and deploy. The running server and image lock stay unchanged until then.")
        for index, item in enumerate(backups)
    ], "Newest first (UTC). Authentication values remain hidden.")
    restored = load_backup(path, backups[int(choice)])
    UI.page("Backup ready for review", "Only the editor will change. Install or Apply will back up the current TOML before saving this version.\n\n" + storage_text(path, restored))
    return restored


def preview_plan(path, data):
    path = configuration_path(path)
    with staged_configuration(path, data):
        pass
    # Resolve against the real TOML before placing the private draft in a temporary directory.
    draft = copy.deepcopy(data)
    for settings, key in ((draft.get("server", {}), "workdir"), (draft.get("proxy", {}), "auth_file"),
                          (draft.get("executor", {}).get("proxy", {}), "auth_file")):
        if key in settings:
            settings[key] = server_config.filename(settings[key], path.parent)
    with tempfile.TemporaryDirectory(prefix="orca-preview-") as directory:
        temporary = Path(directory) / "preview.toml"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as output, staged_configuration(path, draft) as candidate:
            output.write(candidate.read_bytes())
        return UI.run([str(ROOT / "setup.sh"), "--config", str(temporary), "--plan"])


def ask(label, current="", choices=None):
    if UI is not None:
        if choices:
            detail = "\n".join(UI.notes)
            items = [(value, value.replace("-", " ").capitalize(), CHOICE_HELP.get(value, label)) for value in choices]
            if label == "Orca network":
                items = [(value, title, "Orca connects directly. The isolated executor is disabled." if value == "direct" else help_text)
                         for value, title, help_text in items]
            value = UI.choose(label, items, current=choices.index(str(current)) if str(current) in choices else 0,
                              detail=detail)
        else:
            value = str(current)
            while True:
                value = UI.prompt(label, value, help_text=FIELD_HELP.get(label, ""))
                error = field_error(label, value)
                if not error:
                    break
                UI.notes = [error]
        UI.notes.clear()
        return value
    while True:
        hint = "/".join(choices) if choices else ""
        default = str(current) if current != "" else ""
        shown = " [" + default + "]" if default else ""
        value = input(label + (" (" + hint + ")" if hint else "") + shown + ": ").strip()
        value = value or default
        if choices is None or value in choices:
            return value
        print("Choose one of: " + ", ".join(choices))


def confirm(message):
    return ask(message, "no", ("yes", "no")) == "yes"


def auth_settings(proxy):
    existing = "inline" if "password" in proxy or "username" in proxy else "file" if "auth_file" in proxy else "none"
    choice = ask("Proxy authentication", existing, ("none", "inline", "file"))
    if choice == "inline":
        username = ask("Proxy username", proxy.get("username", ""))
        password = (UI.prompt("Proxy password", secret=True, help_text="Input is masked. Enter keeps the saved password; Esc cancels this section.")
                    if UI else getpass.getpass("Proxy password (hidden; Enter keeps existing): "))
        if not password:
            password = proxy.get("password", "")
        if not username or not password:
            notice("Both proxy authentication fields are required; authentication was not changed.")
            return
        proxy.pop("auth_file", None)
        proxy.update(username=username, password=password)
    elif choice == "file":
        path = ask("External root-owned authentication JSON file", proxy.get("auth_file", ""))
        if not path:
            notice("A file path is required; authentication was not changed.")
            return
        proxy.pop("username", None)
        proxy.pop("password", None)
        proxy["auth_file"] = path
    else:
        proxy.pop("username", None)
        proxy.pop("password", None)
        proxy.pop("auth_file", None)


def proxy_settings(proxy):
    proxy["type"] = ask("Proxy type", proxy.get("type", "socks5"), ("socks5", "http-connect"))
    proxy["address"] = ask("Proxy IPv4 address", proxy.get("address", ""))
    while True:
        value = ask("Proxy port", proxy.get("port", 1080))
        if value.isdecimal() and 1 <= int(value) <= 65535:
            proxy["port"] = int(value)
            break
        notice("Enter a port from 1 to 65535.")
    auth_settings(proxy)


def server_settings(data):
    server = data.setdefault("server", {})
    server["role"] = "server"
    server["pairing_address"] = ask("Address clients use", server.get("pairing_address", ""))
    server["publish_address"] = ask("Private IPv4 address on this host", server.get("publish_address", ""))
    server["workdir"] = ask("Shared work directory", server.get("workdir", "~/orca"))
    notice("Host home mode lets Orca read and write the full host home, including credentials.")
    notice("Existing dedicated-home data remains on disk; it is not automatically copied.")
    server["home_mount"] = ask("Orca home mount", server.get("home_mount", "host"), ("host", "dedicated"))
    server["internal_ssh"] = ask("Mutual internal SSH (trusted peers; remote commands use the peer's network)", "yes" if server.get("internal_ssh", False) else "no", ("no", "yes")) == "yes"
    server["image_source"] = ask("Image source", server.get("image_source", "registry"), ("registry", "local"))
    server["image"] = ask("Server image", server.get("image", "ghcr.io/vzxxbacq/orca-server:main"))


def orca_network(data):
    network = data.setdefault("network", {})
    mode = ask("Orca network", network.get("mode", "isolated"), ("isolated", "direct"))
    if mode == "direct" and data.get("proxy"):
        if not confirm("Direct mode removes the saved Orca proxy settings when Install or Apply runs. Continue"):
            return
        data.pop("proxy", None)
    if mode == "direct" and data.get("executor", {}).get("internet", "blocked") != "blocked":
        notice("Direct Orca networking disables the isolated executor and removes its proxy settings.")
        data["executor"]["internet"] = "blocked"
        data["executor"].pop("proxy", None)
    network["mode"] = mode
    if mode == "isolated":
        network["control_subnet"] = ask("Control network /24", network.get("control_subnet", "172.30.70.0/24"))
        proxy_settings(data.setdefault("proxy", {}))
        dns = data.setdefault("dns", {})
        dns["address"] = ask("Proxy DNS IPv4", dns.get("address", "1.1.1.1"))
        dns["transport"] = ask("Proxy DNS transport", dns.get("transport", "https"), ("https", "tcp"))
        dns["tls_name"] = ask("DNS TLS name", dns.get("tls_name", "cloudflare-dns.com"))


def executor_settings(data):
    if data.get("network", {}).get("mode", "direct") != "isolated":
        notice("The executor is available in isolated network mode.")
        return
    executor = data.setdefault("executor", {})
    mode = ask("Executor public access", executor.get("internet", "blocked"), ("blocked", "direct", "proxy"))
    if mode != "proxy" and executor.get("proxy"):
        if not confirm("Changing mode removes the executor proxy settings when Install or Apply runs. Continue"):
            return
        executor.pop("proxy", None)
    executor["internet"] = mode
    if mode == "proxy":
        source = ask("Executor proxy", "separate" if "proxy" in executor else "orca", ("orca", "separate"))
        if source == "orca":
            if executor.get("proxy") and not confirm("Reuse removes the separate executor proxy settings. Continue"):
                return
            executor.pop("proxy", None)
        else:
            proxy_settings(executor.setdefault("proxy", {}))
    private_dns = ask("Private executor DNS IPv4 (enter - to clear)", executor.get("dns", ""))
    if private_dns == "-":
        executor.pop("dns", None)
    elif private_dns:
        executor["dns"] = private_dns
    notice("Configure allowed private destinations in Private LAN rules.")


def lan_rules(data):
    executor = data.setdefault("executor", {})
    rules = executor.setdefault("allow", [])
    for index, rule in enumerate(rules, 1):
        notice("  {}: {} {}/{}".format(rule.get("name", "rule-" + str(index)), rule.get("cidr", ""),
                                       rule.get("protocol", "tcp"), rule.get("port", "")))
    operation = ask("LAN rule", "back", ("add", "remove", "back"))
    if operation == "add":
        name = ask("Rule name")
        cidr = ask("Private IPv4 CIDR")
        protocol = ask("Protocol", "tcp", ("tcp", "udp"))
        port = ask("Destination port")
        if name and cidr and port.isdecimal():
            rules.append({"name": name, "cidr": cidr, "protocol": protocol, "port": int(port)})
        else:
            notice("Invalid rule; no rule was added.")
    elif operation == "remove":
        name = ask("Name to remove")
        executor["allow"] = [rule for rule in rules if rule.get("name") != name]


def limit_settings(data):
    limits = data.setdefault("limits", {})
    for key, label in (("mem_limit", "Memory limit, for example 8g"),
                       ("memswap_limit", "Memory plus swap limit, for example 8g"),
                       ("pids_limit", "Process limit"), ("cpus", "CPU limit")):
        value = ask(label + " (enter - to clear)", limits.get(key, ""))
        if value == "-":
            limits.pop(key, None)
        elif value:
            try:
                limits[key] = int(value) if key == "pids_limit" else float(value) if key == "cpus" else value
            except ValueError:
                notice("Invalid numeric limit; the previous value was kept.")


def storage_values(path, data):
    """Public storage locations shared by the preview and deployment review."""
    user_home = Path.home()
    config_root = Path(os.environ.get("XDG_CONFIG_HOME") or user_home / ".config").expanduser()
    data_root = Path(os.environ.get("XDG_DATA_HOME") or user_home / ".local/share").expanduser()
    docker_dir = config_root / "orca-setup/docker"
    dedicated_home = data_root / "orca-setup/home"
    executor_home = data_root / "orca-setup/executor-home"
    settings = data.get("server", {})
    workdir = Path(settings.get("workdir") or "~/orca").expanduser()
    if not workdir.is_absolute():
        workdir = Path(path).parent / workdir
    locations = {
        "Configuration": str(path),
        "Configuration backups": str(backup_directory(path)),
        "Generated Compose": str(docker_dir / "compose.yaml"),
        "Image lock": str(docker_dir / "image.lock"),
        "Generated network data": str(docker_dir / "network"),
    }
    if settings.get("home_mount", "dedicated") == "host":
        locations["Orca home"] = str(user_home) + " (full host home, writable)"
        locations["Previous dedicated home"] = str(dedicated_home) + " (kept; not automatically merged)"
    else:
        locations["Orca home"] = str(dedicated_home) + " (dedicated persistent home)"
    locations.update({
        "Shared workdir": str(workdir.resolve()),
        "Executor home": str(executor_home) + " (separate from host home)",
        "Proxy authentication": "private Docker volume(s), plus the selected TOML when inline",
        "/tmp": "temporary; the container image root is read-only",
    })
    return locations


def storage_text(path, data):
    return "Storage locations:\n" + "\n".join(f"  {label + ':':24} {value}" for label, value in storage_values(path, data).items())


def storage_summary(path, data):
    print(storage_text(path, data))


def preview_values(section, path, data):
    """Explicit public-field allowlist; never render raw TOML or authentication values."""
    server = data.get("server", {})
    network = data.get("network", {})
    proxy = data.get("proxy", {})
    dns = data.get("dns", {})
    executor = data.get("executor", {})
    mode = network.get("mode", "isolated" if proxy else "direct")
    defaults = dict(line.split("=", 1) for line in (ROOT / "manifest/server-network.env").read_text().splitlines()
                    if line and not line.startswith("#"))

    def endpoint(settings):
        return (str(settings.get("address") or "not set") + ":" + str(settings.get("port", defaults["proxy_port"]))
                + " (" + settings.get("type", defaults["proxy_type"]) + ")")

    def authentication(settings):
        if "username" in settings or "password" in settings:
            return "inline (hidden)"
        return "external file (hidden)" if "auth_file" in settings else "none"

    if section == "server":
        storage = storage_values(path, data)
        return {
            "Client address": server.get("pairing_address") or "not set",
            "Listen": (server.get("publish_address") or "not set") + ":6768",
            "Internal SSH": "enabled (trusted peers)" if server.get("internal_ssh", False) else "disabled",
            "Home mount": server.get("home_mount", "dedicated"),
            "Orca home": storage["Orca home"],
            "Shared workdir": storage["Shared workdir"],
            "Image source": server.get("image_source", "registry"),
            "Image": server.get("image", "ghcr.io/vzxxbacq/orca-server:main"),
        }
    if section == "network":
        result = {"Orca network": mode}
        if mode == "direct":
            return {**result, "Public traffic": "host route", "Executor": "disabled"}
        return {**result, "Proxy endpoint": endpoint(proxy), "Authentication": authentication(proxy),
                "DNS": dns.get("address", defaults["dns_address"]),
                "DNS transport": dns.get("transport", defaults["dns_transport"]),
                "DNS TLS name": dns.get("tls_name", defaults["dns_tls_name"]),
                "Control subnet": network.get("control_subnet", defaults["control_subnet"])}
    if section == "executor":
        if mode != "isolated":
            return {"Executor": "disabled (Orca network is direct)"}
        access = executor.get("internet", "blocked")
        result = {"Public access": access}
        if access == "proxy":
            settings = executor.get("proxy", proxy)
            result.update({"Proxy source": "separate" if "proxy" in executor else "reuse Orca proxy",
                           "Proxy endpoint": endpoint(settings), "Authentication": authentication(settings)})
        result["DNS"] = (executor["dns"] + " (private, direct)" if executor.get("dns") else
                         "blocked" if access == "blocked" else
                         dns.get("address", defaults["dns_address"]) + (" (through proxy)" if access == "proxy" else " (direct)"))
        result["LAN rules"] = str(len(executor.get("allow", [])))
        return result
    if section == "lan":
        result = {"Executor": "enabled" if mode == "isolated" else "disabled; rules are inactive"}
        rules = executor.get("allow", [])
        result["Allowed destinations"] = str(len(rules))
        for index, rule in enumerate(rules, 1):
            result["Rule " + rule.get("name", "rule-" + str(index))] = (
                rule.get("cidr", "not set") + " " + rule.get("protocol", "tcp") + "/" + str(rule.get("port", "not set")))
        return result
    if section == "limits":
        limits = data.get("limits", {})
        return {label: str(limits.get(key, "not set (Docker default)")) for key, label in (
            ("mem_limit", "Memory"), ("memswap_limit", "Memory + swap"), ("pids_limit", "Processes"), ("cpus", "CPUs"))}
    if section == "paths":
        return storage_values(path, data)
    if section == "auth":
        return {"Sign-in": "interactive inside the running server", "Accounts": "gh, codex, claude, agy, linear",
                "Login status": "not checked by this preview"}
    return {"Listen": (server.get("publish_address") or "not set") + ":6768",
            "Internal SSH": "enabled (trusted peers)" if server.get("internal_ssh", False) else "disabled",
            "Home mount": server.get("home_mount", "dedicated"), "Orca network": mode,
            "Executor": executor.get("internet", "blocked") if mode == "isolated" else "disabled",
            "LAN rules": str(len(executor.get("allow", []))), "Configuration": str(path)}


def section_preview(section, path, data, saved, saved_exists):
    current = preview_values(section, path, data)
    previous = preview_values(section, path, saved) if saved_exists else {}
    state = "Unsaved edits (* changed)" if data != saved else "Saved TOML" if saved_exists else "Not saved yet"
    lines = ["CONFIGURATION PREVIEW", state, ""]
    for label, value in current.items():
        changed = saved_exists and previous.get(label) != value
        lines.append(("* " if changed else "") + label + ": " + value)
        if changed and label in previous:
            lines.append("  Saved: " + previous[label])
    for label in sorted(previous.keys() - current.keys()):
        lines.append("* " + label + ": removed / inactive")
    # Credential-only edits must be visible as a change, without revealing either value.
    def auth_values(settings):
        return tuple(settings.get(key) for key in ("username", "password", "auth_file"))
    if saved_exists and section in ("network", "executor"):
        def selected_proxy(config):
            if section == "network":
                return config.get("proxy", {})
            return config.get("executor", {}).get("proxy", config.get("proxy", {}))
        if auth_values(selected_proxy(data)) != auth_values(selected_proxy(saved)):
            lines.append("* Proxy authentication changed (hidden)")
    lines.extend(("", "Configuration only; running state is not checked."))
    return "\n".join(lines)


def deployment_preview(state):
    lines = ["INSTALLED DEPLOYMENT", "Client: " + state.get("pairing-address", "not set") + ":6768",
             "Listen: " + state.get("publish-address", "not set") + ":6768", "Port: " + state["port"],
             "Docker project: " + state.get("project", "unknown"), ""]
    lines.append("Orca process: " + state.get("orca-process", "unavailable (container stopped or legacy deployment)"))
    for service in manager.SERVICES:
        if service in state["services"]:
            lines.append(service + ": " + state["services"][service]["status"])
    if not state["services"]:
        lines.append("No installed containers found.")
    if state["error"]:
        lines.append(state["error"])
    lines.extend(("", "Compose: " + state["compose"], "Client access and pairing must be verified from your Mac."))
    return "\n".join(lines)


def manage_deployment():
    selection = 0
    actions = [
        ("refresh", "Refresh status", "Read container state and check the published TCP port from this host."),
        ("pair", "Pair a client", "Maintenance pairing: show a client link without restarting Docker. Orca sessions may be interrupted."),
        ("pair-mobile", "Pair a mobile device", "Maintenance pairing: show a mobile QR code and link without restarting Docker. Orca sessions may be interrupted."),
        ("auth", "Sign in to accounts", "Sign in to Codex, Claude, GitHub and other supported accounts inside the running server."),
        ("orca-start", "Start Orca process", "Start Orca inside the running container. No containers or gateways are restarted."),
        ("orca-stop", "Stop Orca process", "Keep containers running. Orca connections and Orca-owned sessions may be interrupted."),
        ("orca-restart", "Restart Orca process", "Restart only Orca. Independent workers remain running; Orca-owned sessions may be interrupted."),
        ("start", "Start deployment", "Start containers from the applied Compose and locked image. Does not apply TOML edits or pull a new image."),
        ("stop", "Stop deployment", "Stop the deployed containers. Files, configuration and images are retained."),
        ("restart", "Restart deployment", "Restart the applied deployment. Running sessions are interrupted."),
        ("check", "Check readiness", "Run the read-only setup readiness report for the applied deployment."),
        ("configure", "Edit configuration", "Return to configuration previews, settings, image selection and upgrades."),
        ("uninstall", "Uninstall server", "Remove this deployment's containers and networks. Keep configuration, backups, images and all user data."),
        ("quit", "Quit", "Leave the server in its current state and close this interface."),
    ]
    state = manager.snapshot()
    while True:
        UI.stage = "SERVER / MANAGEMENT"
        UI.status = "Status unavailable" if state["error"] else state["services"].get("orca-server", {}).get("state", "Not running")
        try:
            choice = UI.choose("Manage your Orca server", actions, "Pair a device, sign in, or manage the installed server", selection,
                               preview=lambda section, state=state: (manager.MAINTENANCE_PAIRING_NOTICE + "\n\n" if section in ("pair", "pair-mobile") else "") + deployment_preview(state))
        except screen.Cancelled:
            return "quit"
        try:
            selection = next(i for i, item in enumerate(actions) if item[0] == choice)
            if choice in ("configure", "quit"):
                return choice
            if choice == "auth":
                account = ask("Sign in inside the running server", "back", ("gh", "codex", "claude", "agy", "linear", "back"))
                if account != "back":
                    UI.run([str(ROOT / "setup.sh"), "--auth-" + account])
            elif choice == "check":
                UI.run([str(ROOT / "setup.sh"), "--check", "--role", "server"])
            elif choice == "uninstall":
                if not UI.confirm("Uninstall this server?", deployment_preview(state) +
                                  "\n\nREMOVE\nThis deployment's containers and networks. Running sessions will stop."
                                  "\n\nKEEP\nYour home, workdir, accounts, configuration, backups, images and volumes."
                                  "\n\nAfter uninstall, you can install again using your saved settings.", yes_label="Yes, uninstall"):
                    continue
                code = UI.run([sys.executable, str(ROOT / "lib/server-manage.py"), "uninstall"])
                if code == 0:
                    UI.page("Server uninstalled", "Containers and networks were removed. Your files and saved configuration were retained.\n\n"
                            "Previous deployment: " + str(manager.compose_file().with_name("compose.uninstalled.yaml")) +
                            "\n\nYou can install again from the configuration page.")
                    return "uninstalled"
            elif choice in ("pair", "pair-mobile"):
                if UI.confirm("Start maintenance pairing?", manager.MAINTENANCE_PAIRING_NOTICE, yes_label="Yes, pair"):
                    UI.run([sys.executable, str(ROOT / "lib/server-manage.py"), choice])
            elif choice in ("orca-start", "orca-stop", "orca-restart"):
                if choice != "orca-start" and not confirm("Stop Orca connections and possibly Orca-owned sessions? Containers and independent workers stay running."):
                    continue
                UI.run([sys.executable, str(ROOT / "lib/server-manage.py"), choice])
            elif choice in ("start", "stop", "restart"):
                if choice in ("stop", "restart") and not confirm({
                    "stop": "Stop the installed server?", "restart": "Restart and interrupt current sessions?",
                }[choice]):
                    continue
                UI.run([sys.executable, str(ROOT / "lib/server-manage.py"), choice])
            state = manager.snapshot()
        except screen.Cancelled:
            continue


def configuration_actions(installed):
    """Installation and editing have distinct menus; account/lifecycle actions live in management."""
    actions = [
        ("server", "Server & storage", "Client address, private listen address, shared workdir, home mount and Docker image."),
        ("network", "Orca network & proxy", "Choose direct or isolated networking. Configure the upstream proxy and DNS."),
        ("executor", "Executor Internet", "Block public access, connect directly, or use an independent or shared proxy."),
        ("lan", "Private LAN rules", "Allow specific private CIDRs and ports for execution commands."),
        ("limits", "Resource limits", "Optional memory, swap, process and CPU limits."),
        ("paths", "File locations", "See where TOML, generated Compose, network files and persistent container data live."),
        ("restore", "Restore configuration", "Load a previous automatic backup for review. Install or Apply saves and deploys it; current settings are backed up first."),
        ("plan", "Preview plan", "Preview the current edits using a private temporary TOML. Does not save or change the deployment."),
    ]
    if installed:
        actions.extend([
            ("apply", "Apply changes", "Automatically back up and save the current edits, update the deployment and return to management. May interrupt sessions."),
            ("upgrade", "Apply & upgrade image", "Explicitly adopt the latest configured image and apply. Running sessions may be interrupted."),
            ("back", "Back to management", "Return to server management. Unsaved edits require confirmation before being discarded."),
        ])
    else:
        actions.extend([
            ("apply", "Install & start server", "Validate and automatically save the current edits, backing up any previous TOML. Install missing components and start the selected image. Management opens automatically when setup succeeds."),
            ("quit", "Quit", "Leave installation. Unsaved edits can be discarded; saved settings remain on disk."),
        ])
    return actions


def deployment_review(path, data):
    lines = []
    for section, title in (("server", "SERVER"), ("network", "ORCA NETWORK"), ("executor", "EXECUTOR NETWORK"),
                           ("lan", "PRIVATE ACCESS"), ("limits", "RESOURCE LIMITS"), ("paths", "FILE LOCATIONS")):
        lines.extend((title, *[label + ": " + value for label, value in preview_values(section, path, data).items()], ""))
    return "\n".join(lines)


def session(window, path, data, recovery_error=None):
    global UI
    UI = screen.Screen(window, path)
    saved = copy.deepcopy(data)
    selection = 0
    installed = manager.compose_file().is_file()
    editors = {"server": server_settings, "network": orca_network, "executor": executor_settings,
               "lan": lan_rules, "limits": limit_settings}
    try:
        if recovery_error:
            UI.page("Configuration needs recovery", recovery_error + "\n\nUse Restore configuration to review a backup, or edit the settings. Install/Apply will preserve the existing file in a backup before replacing it.")
        if installed:
            outcome = manage_deployment()
            if outcome == "quit":
                return
            installed = outcome != "uninstalled"
        while True:
            actions = configuration_actions(installed)
            selection = min(selection, len(actions) - 1)
            dirty = data != saved
            UI.status = "Recovery required" if recovery_error else "Unsaved edits" if dirty else "Saved configuration" if path.exists() else "New configuration"
            UI.stage = "SERVER / EDIT CONFIGURATION" if installed else "INSTALL / CONFIGURATION"
            UI.notes.clear()
            try:
                choice = UI.choose("Edit your server configuration" if installed else "Set up your Orca server", actions,
                                   "Apply saves automatically; previous settings can be restored" if installed else "Review each section, then Install; configuration saves automatically", selection,
                                   preview=lambda section, data=data, saved=saved, recovery_error=recovery_error:
                                   section_preview(section, path, data, saved, path.is_file() and not recovery_error))
            except screen.Cancelled:
                choice = "back" if installed else "quit"
            selection = next(i for i, item in enumerate(actions) if item[0] == choice)
            try:
                if choice in ("quit", "back"):
                    question = "Discard unsaved edits and return to management?" if installed else "Discard unsaved edits and quit?"
                    if dirty and not confirm(question):
                        continue
                    if not installed:
                        return
                    outcome = manage_deployment()
                    if outcome == "quit":
                        return
                    installed = outcome != "uninstalled"
                    data = copy.deepcopy(saved)
                    selection = 0
                elif choice in editors:
                    draft = copy.deepcopy(data)
                    UI.stage = "EDIT / " + actions[selection][1].upper()
                    editors[choice](draft)
                    if UI.notes:
                        UI.page("Section updated", "\n".join(UI.notes))
                    data = draft
                elif choice == "paths":
                    UI.page("Where your files are saved", storage_text(path, data))
                elif choice == "restore":
                    data = restore_configuration(path, data)
                elif choice == "plan":
                    preview_plan(path, data)
                else:
                    UI.stage = "DEPLOYMENT / REVIEW & CONFIRM"
                    action = "upgrade" if choice == "upgrade" else "apply" if installed else "install"
                    title = {"install": "Install and start this server?", "apply": "Apply these changes?", "upgrade": "Apply and upgrade the image?"}[action]
                    review = deployment_review(path, data)
                    if action in ("apply", "upgrade"):
                        review = "Running sessions may be interrupted.\n\n" + review
                    if not UI.confirm(title, review, yes_label="Yes, " + action):
                        continue
                    backup = save(path, data)
                    saved = copy.deepcopy(data)
                    recovery_error = None
                    UI.status = "Saved configuration"
                    options = ["--apply", "--upgrade-image"] if choice == "upgrade" else ["--apply"]
                    code = UI.run([str(ROOT / "setup.sh"), "--config", str(path), *options])
                    if code != 0:
                        UI.page("Deployment did not complete", "The configuration was saved, but setup did not complete. Review the output and retry, or use Restore configuration to load a previous version.\n\n"
                                + ("Previous configuration: " + str(backup) if backup else "Backups: " + str(backup_directory(path))))
                    if code == 0 and choice in ("apply", "upgrade"):
                        installed = True
                        selection = 0
                        outcome = manage_deployment()
                        if outcome == "quit":
                            return
                        installed = outcome != "uninstalled"
            except screen.Cancelled:
                continue
            except (OSError, ValueError, TypeError, KeyError) as error:
                message = str(error) if isinstance(error, (server_config.ConfigError, TuiError)) else "Configuration could not be saved or validated (values hidden)."
                try:
                    UI.page("Action could not be completed", message + "\n\nReview the relevant section and retry. Install/Apply keeps previous configurations in the backup directory.")
                except screen.Cancelled:
                    pass
    finally:
        UI = None


def load_configuration(path):
    data = {"server": {"role": "server", "home_mount": "host"}, "network": {"mode": "isolated"}}
    if path.exists():
        try:
            server_config.load(path)
            return tomllib.loads(path.read_text()), None
        except (server_config.ConfigError, UnicodeError):
            return data, "The current TOML could not be validated (values hidden). It has not been changed."
    return data, None


def main(path):
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise ValueError("the interface requires an interactive terminal")
    if os.environ.get("TERM", "dumb") in ("", "dumb", "unknown"):
        raise TuiError("a capable terminal is required; connect with ssh -t and a valid TERM")
    path = configuration_path(path)
    data, recovery_error = load_configuration(path)
    curses.wrapper(session, path, data, recovery_error)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2 or os.getuid() == 0:
            raise ValueError("run as a regular user with one configuration path")
        main(sys.argv[1])
    except (EOFError, KeyboardInterrupt, screen.Cancelled):
        print("\nExited; unsaved edits were not written.")
    except (OSError, ValueError, TypeError, KeyError, curses.error) as error:
        message = str(error) if isinstance(error, TuiError) else "unable to open server configuration or terminal (values hidden)"
        print("ERROR: " + message, file=sys.stderr)
        sys.exit(1)
