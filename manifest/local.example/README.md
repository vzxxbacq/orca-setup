# Local overlay example

Copy this directory to `manifest/local/` (git-ignored) to add organization- or device-specific settings
without changing the tracked manifest:

```sh
cp -R manifest/local.example manifest/local
```

- `baseline.tsv`, `agents.tsv`, `orca-skills.tsv`: same columns as the files in `manifest/`. A row whose
  first column matches a shipped row replaces it in place; any other row is appended.
- `orca-settings.json`: deep-merged over `manifest/orca-settings.json` (objects merge, arrays and values replace).
- `server-mounts.tsv` (not in this example): more directories to mount into the Linux server container, same columns
  as `manifest/server-mounts.tsv`.
- `server-limits.env`: container limits for the Linux server (`--role server`); a key here replaces the same key in
  `manifest/server-limits.env`. Only the keys listed there are accepted.
- `server-network.env`: existing HTTP CONNECT/SOCKS5 endpoint and DNS/control network settings, used only with
  `--network-mode isolated`. Replace the documentation proxy address on the target device. No credentials allowed.
- `server-network-allow.tsv`: explicit private IPv4 CIDR, protocol and port exceptions for the LAN-only executor;
  empty until you add target-specific rules (DESIGN.md section 3.3.3).
- `Dockerfile.example`: rename it to `Dockerfile` to build organization-specific tools on top of the Linux server's
  locked image; setup.sh then runs the result instead (DESIGN.md section 3.3.2). Without it nothing is built.

Everything here is a placeholder. Never put credentials in the overlay: authentication stays interactive.
