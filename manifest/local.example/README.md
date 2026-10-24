# Local overlay example

Copy this directory to `manifest/local/` (git-ignored) to add organization- or device-specific settings
without changing the tracked manifest:

```sh
cp -R manifest/local.example manifest/local
```

- `baseline.tsv`, `agents.tsv`, `orca-skills.tsv`: same columns as the files in `manifest/`. A row whose
  first column matches a shipped row replaces it in place; any other row is appended.
- `orca-settings.json`: deep-merged over `manifest/orca-settings.json` (objects merge, arrays and values replace).

Everything here is a placeholder. Never put credentials in the overlay: authentication stays interactive.
