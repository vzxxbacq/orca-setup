#!/usr/bin/env python3
"""Strict, non-executable server TOML. Public output never contains proxy authentication values."""

import ipaddress
import json
import math
import os
from pathlib import Path
import re
import stat
import sys

try:
    import tomllib
except ImportError:
    print("Server TOML requires Python 3.11 or newer on the setup host.", file=sys.stderr)
    sys.exit(1)

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = {
    "server": {"role", "image", "image_source", "pairing_address", "publish_address", "workdir", "task_source"},
    "network": {"mode", "control_subnet"},
    "proxy": {"type", "address", "port", "username", "password", "auth_file"},
    "dns": {"address", "transport", "tls_name"},
    "executor": {"dns", "allow"},
    "limits": {"mem_limit", "memswap_limit", "pids_limit", "cpus"},
}


class ConfigError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ConfigError(message)


def text(value):
    require(isinstance(value, str) and not any(ord(char) < 32 or ord(char) == 127 for char in value),
            "configuration strings must not contain control characters")
    return value


def address(value):
    value = text(value)
    try:
        parsed = ipaddress.IPv4Address(value)
    except ipaddress.AddressValueError:
        raise ConfigError("an address must be a canonical unicast IPv4 literal") from None
    require(0 < int(parsed) >> 24 < 224 and not parsed.is_loopback,
            "an address must be a canonical unicast IPv4 literal")
    return value


def private_cidr(value):
    try:
        network = ipaddress.IPv4Network(text(value), strict=True)
    except ValueError:
        raise ConfigError("executor rules require canonical private IPv4 CIDRs") from None
    ranges = ((10 << 24, 8), ((172 << 24) + (16 << 16), 12),
              ((192 << 24) + (168 << 16), 16), ((100 << 24) + (64 << 16), 10))
    require(any(network.subnet_of(ipaddress.IPv4Network(item)) for item in ranges),
            "executor rules require canonical private IPv4 CIDRs")
    return str(network)


def port(value):
    require(type(value) is int and 1 <= value <= 65535, "a port must be an integer between 1 and 65535")
    return value


def filename(value, parent):
    path = Path(text(value)).expanduser()
    if not path.is_absolute():
        path = parent / path
    path = path.resolve()
    require(re.fullmatch(r"/[A-Za-z0-9._/+@-]+", str(path)) is not None,
            "configuration paths must use the documented mount-safe characters")
    return str(path)


def load(path):
    path = Path(path).expanduser().resolve()
    try:
        with path.open("rb") as source:
            metadata = os.fstat(source.fileno())
            require(stat.S_ISREG(metadata.st_mode) and metadata.st_size <= 1024 * 1024,
                    "configuration must be a regular file no larger than 1 MiB")
            data = tomllib.load(source)
    except (tomllib.TOMLDecodeError, UnicodeError):
        raise ConfigError("invalid TOML syntax (values are hidden)") from None
    require(set(data) <= set(SCHEMA), "unknown TOML section")
    for section, fields in SCHEMA.items():
        table = data.setdefault(section, {})
        require(isinstance(table, dict) and set(table) <= fields, "unknown key or invalid TOML table")
    server, network, proxy, dns, executor, limits = (data[key] for key in SCHEMA)
    require(server.get("role", "server") == "server", "server TOML supports the Linux server role only")
    mode = network.get("mode", "isolated" if proxy else "direct")
    require(mode in ("direct", "isolated"), "network.mode must be direct or isolated")
    require(mode == "isolated" or not proxy, "a proxy table requires isolated network mode")
    public = {"role": "server", "network_mode": mode}
    for key in ("pairing_address", "publish_address", "workdir", "image", "task_source"):
        if key in server:
            public[key] = text(server[key])
    if "publish_address" in public:
        address(public["publish_address"])
    if "workdir" in public:
        # A relative workdir is relative to the TOML, not the caller's current directory.
        public["workdir"] = filename(public["workdir"], path.parent)
    if "task_source" in public:
        require(public["task_source"] in ("", "linear"), "unsupported server.task_source")
    image_source = server.get("image_source", "registry")
    require(image_source in ("registry", "local"), "server.image_source must be registry or local")
    public["image_source"] = image_source
    if "image" in public:
        require(bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/:@+-]*", public["image"])), "invalid server.image reference")
    require(image_source != "local" or bool(public.get("image")), "a local image requires server.image")
    defaults = {}
    for line in (ROOT / "manifest/server-network.env").read_text().splitlines():
        if line and not line.startswith("#"):
            key, value = line.split("=", 1)
            defaults[key] = value
    public.update({"proxy_type": proxy.get("type", defaults["proxy_type"]),
                   "proxy_address": proxy.get("address", defaults["proxy_address"]),
                   "proxy_port": str(port(proxy.get("port", int(defaults["proxy_port"])))),
                   "dns_address": address(dns.get("address", defaults["dns_address"])),
                   "dns_transport": dns.get("transport", defaults["dns_transport"]),
                   "dns_tls_name": text(dns.get("tls_name", defaults["dns_tls_name"])),
                   "executor_dns": text(executor.get("dns", "")),
                   "control_subnet": private_cidr(network.get("control_subnet", defaults["control_subnet"]))})
    require(public["control_subnet"].endswith("/24"), "network.control_subnet must be a private /24")
    require(public["proxy_type"] in ("socks5", "http-connect"), "unsupported proxy.type")
    require(public["dns_transport"] in ("tcp", "https"), "unsupported dns.transport")
    require(bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", public["dns_tls_name"])), "invalid dns.tls_name")
    if mode == "isolated":
        public["proxy_address"] = address(public["proxy_address"])
    if public["executor_dns"]:
        private_cidr(address(public["executor_dns"]) + "/32")
    inline = "username" in proxy or "password" in proxy
    require(not (inline and "auth_file" in proxy), "inline proxy credentials and proxy.auth_file are mutually exclusive")
    auth = None
    public["proxy_auth_file"] = ""
    public["proxy_inline_auth"] = "yes" if inline else "no"
    if inline:
        require(metadata.st_uid == os.getuid() and stat.S_IMODE(metadata.st_mode) in (0o600, 0o400),
                "inline credentials require a caller-owned configuration with mode 0600 or 0400")
        require(not path.is_relative_to(ROOT) or path == ROOT / "orca.toml",
                "inline credentials belong outside the checkout or in the ignored root orca.toml")
        auth = {key: proxy.get(key) for key in ("username", "password")}
        require(all(isinstance(value, str) and 1 <= len(value) <= 255 and
                    all(32 <= ord(char) <= 126 for char in value) for value in auth.values()),
                "proxy credentials require 1-255 printable ASCII characters per field")
        public["proxy_auth_file"] = "/run/secrets/orca_proxy_auth"
    elif "auth_file" in proxy:
        public["proxy_auth_file"] = filename(proxy["auth_file"], path.parent)
    rules = executor.get("allow", [])
    require(isinstance(rules, list), "executor.allow must be an array of tables")
    public["allow"] = []
    names = set()
    for index, rule in enumerate(rules, 1):
        require(isinstance(rule, dict) and set(rule) <= {"name", "cidr", "protocol", "port"}, "invalid executor rule fields")
        name = text(rule.get("name", "rule-" + str(index)))
        require(bool(re.fullmatch(r"[A-Za-z0-9_-]+", name)) and name not in names, "executor rule names must be unique identifiers")
        names.add(name)
        require(rule.get("protocol", "tcp") in ("tcp", "udp"), "executor protocol must be tcp or udp")
        public["allow"].append("\t".join((name, private_cidr(rule.get("cidr")), rule.get("protocol", "tcp"), str(port(rule.get("port"))))))
    public["limits"] = []
    for key, value in limits.items():
        if key in ("mem_limit", "memswap_limit"):
            require(bool(re.fullmatch(r"[0-9]+[bkmg]?", text(value))), "invalid memory limit")
        elif key == "pids_limit":
            require(type(value) is int and value >= 64, "pids_limit must be an integer of at least 64")
        else:
            require(type(value) in (int, float) and math.isfinite(value) and value > 0, "cpus must be a positive finite number")
        public["limits"].append(key + "=" + str(value))
    # This also checks that every emitted scalar has a safe, single-line representation.
    for value in public.values():
        if isinstance(value, str):
            text(value)
    return public, auth


def main():
    require(len(sys.argv) >= 3, "usage: server-config.py public|secret|check-mounts FILE [DIRECTORY ...]")
    public, auth = load(sys.argv[2])
    if sys.argv[1] == "check-mounts":
        if auth is not None:
            path = Path(sys.argv[2]).resolve()
            require(not any(path.is_relative_to(Path(directory).resolve()) for directory in sys.argv[3:]),
                    "inline proxy TOML must be outside application data mounts and the shared workdir")
        return
    require(len(sys.argv) == 3, "unexpected configuration arguments")
    if sys.argv[1] == "public":
        for key, value in public.items():
            if isinstance(value, list):
                for item in value:
                    print(key + "\t" + item)
            else:
                print(key + "\t" + value)
    elif sys.argv[1] == "secret":
        require(auth is not None, "the configuration has no inline proxy credentials")
        # This channel must be piped directly to the private gateway publisher/checker, never logged or evaluated.
        print(json.dumps(auth))
    else:
        raise ConfigError("unknown configuration operation")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError, AttributeError) as error:
        message = str(error) if isinstance(error, ConfigError) else "invalid server configuration (values are hidden)"
        print("ERROR: " + message, file=sys.stderr)
        sys.exit(1)
