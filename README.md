# mac-workflow-probe

A probe that finds out whether a macOS machine lets a script install, configure, launch and observe
desktop apps. `probe.sh` runs 13 checks:
the machine, the user, the desktop session, installing and verifying Claude Code and Claude Desktop,
writing MCP configuration for both, launching Claude Desktop, finding its window, taking a screenshot,
and testing permission to drive the UI. Every check records pass, fail or skipped, the exit code, the
duration and the full output. A failed check does not stop the later checks.

It uses only stock macOS tools and public download URLs.

## Run it on GitHub

1. Open the Actions tab, choose the `probe` workflow, and select "Run workflow".
2. The workflow runs once per runner label in the matrix (`fail-fast` is off).
3. Each job writes a table to its job summary and uploads an artifact named `probe-<label>`.

## Run it on any Mac

```
bash probe.sh <output-dir>
```

The script installs software and writes to `/Applications` and the user's Claude config. Run it only on a
disposable machine.

## Results

The output directory holds:

- `results.json`: label, user, start and finish times, and for each check its number, name, result, exit code,
  duration and log path.
- `logs/NN-name.log`: the full output of each check.
- `screenshots/`: the screenshot from check 12.
