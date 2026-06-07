# Contributing

Thanks for considering a contribution. This project moves real data with `rsync --delete`, so the bar for changes is "tested and explained."

## Before you start

- Open an issue first for anything non-trivial — especially changes to the guards or the drift logic. The [design](docs/DESIGN.md) and [red-team history](docs/RED-TEAM.md) explain *why* things are the way they are; a change that looks like simplification may be removing a guard added for a real reason.

## Development

The runnable scripts live as **templates** in `templates/*.tmpl` with `@@TOKENS@@` for machine-specific paths. The installer renders them; the test suite renders them into sandboxes. Edit the **templates**, never a rendered copy.

## Running the tests

```bash
tests/run-tests.sh
```

53 checks, all in disposable `/private/tmp` sandboxes — they never touch your real vault, memory, or settings. Every change must keep the suite green, and new behavior needs a new test. The suite also exercises `install.sh`/`uninstall.sh` against a sandboxed `~/.claude`.

Please also run [`shellcheck`](https://www.shellcheck.net/) on any shell you touch:

```bash
shellcheck templates/*.tmpl install.sh uninstall.sh tests/*.sh tests/lib/*.sh
```

## Conventions

- **Target macOS bash 3.2** (`/bin/bash`) and BSD userland. No bashisms that need 4.x; no GNU-only flags.
- **Absolute binary paths** in the security-critical script (`/usr/bin/rsync`, `/bin/realpath`, …) — this is deliberate and audited; don't replace them with bare names.
- **The invariant that matters most:** no change may introduce a code path that writes to the memory *source* directory. If your PR touches `mirror-memory.sh`, state explicitly in the description that it does not.

## Good first issues

**Linux support** is the big one: it means revisiting the openrsync pin (Linux has GNU rsync — different `--delete` ordering and exit codes, notably the benign `24`) and the BSD-specific `realpath`/`stat -f` calls. A clean, well-tested port would be a flagship contribution.

## PR checklist

- [ ] Edited templates, not rendered scripts
- [ ] `tests/run-tests.sh` passes; added a test for new behavior
- [ ] `shellcheck` clean
- [ ] No new write path to the memory source directory
- [ ] Updated docs if behavior changed
