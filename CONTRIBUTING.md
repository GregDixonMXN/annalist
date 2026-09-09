# Development

Use Linux x86-64, Zig 0.15.2, a C toolchain, SQLite development headers, and Python 3. On Debian/Ubuntu the system dependencies are `build-essential libsqlite3-dev python3`.

```sh
sh scripts/check.sh
```

Set `ZIG=/absolute/path/to/zig` if Zig is not on PATH. The script checks both build modes and runs the extracted release binary against isolated CLI, HTTP, and terminal fixtures. `sh scripts/package.sh` builds the archive without the full test suite.

With Docker available, verify the archive without a development toolchain:

```sh
sh scripts/check-container.sh dist/annalist-1.0.0-rc.1-linux-x86_64.tar.gz
```

This builds a pinned Ubuntu 24.04 test environment, then runs the packaged regressions as an unprivileged user with networking disabled and read-only mounts. Only tests and release artifacts are mounted; recorder data is not. Python is used by the test harness, not by Annalist.

## Code map

- `src/session.zig`, `record.zig`, `scan.zig`: process supervision and observed file changes.
- `src/db.zig`, `store.zig`: the shared index and per-project content store.
- `src/rewind.zig`, `safe_fs.zig`: validated recovery and pre-recovery copies.
- `src/import.zig`, `export.zig`: portable completed-run bundles.
- `src/server.zig`, `src/ui/index.html`: the read-only loopback dashboard.
- `tests/`: isolated regressions; `docs/adr/`: design decisions.

## Changes

Keep data migrations transactional, filesystem mutations preflighted, and captured text untrusted. Add regression coverage for changes to recording, recovery, bundle validation, HTTP parsing, and process supervision. Test with temporary HOME/XDG/project directories; never use a developer's real history as a fixture. Preserve unrelated work and avoid adding captured source, command arguments, local histories, or credentials to the repository.

Release changes must update the CLI version, package version, changelog, and [verification evidence](docs/VERIFICATION.md) together. The CI workflow verifies artifacts but does not publish a release. Distribution licensing is not granted by this development guide.
