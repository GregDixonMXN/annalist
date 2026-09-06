# Blackbox

> Blackbox is a local-first flight recorder for autonomous coding agents.

Blackbox observes what the operating system sees, rather than trusting the AI agent's own description of what it did.

## Status: v0.3 working

## Requirements

- Zig 0.15.x (`zig version`)
- libsqlite3 (ships with virtually all Linux/macOS systems)
- Linux x86_64 primary; platform code isolated in `src/platform/` (planned)

## Quick start

```bash
zig build
./zig-out/bin/blackbox init
./zig-out/bin/blackbox run -- sh -c "echo hello > hello.txt"
./zig-out/bin/blackbox sessions
./zig-out/bin/blackbox inspect 001
./zig-out/bin/blackbox inspect 001 --file hello.txt
./zig-out/bin/blackbox ui   # http://127.0.0.1:8901
```

## Commands

- `blackbox init` — initialize `.blackbox/` (identity only; history lives in `~/.local/share/blackbox/`)
- `blackbox run -- <command>` — record a session (inherits stdio, forwards signals to the whole process group, propagates exit code)
- `blackbox sessions` — table of sessions
- `blackbox inspect <id> [--json] [--file <path>]` — metadata, timeline, before/after/diff per file
- `blackbox diff <a> <b>` — per-session change sets (what each run created/modified/deleted/renamed)
- `blackbox rewind <session> [seq] [--force]` — undo a session (pre-session state) or restore state at event seq; refuses on post-session changes without --force; not recorded
- `blackbox export <session>|--all [--out <dir>]` — portable bundles (manifest.json + content blobs)
- `blackbox branch [name]` — named workstreams; `sessions [--branch <name>]` filters
- `blackbox policy [--set-max-age <days>]` / `blackbox prune [--dry-run] [--older-than <days>]` — retention
- `blackbox doctor [--fix] [--gc]` — integrity check, stale-session repair, orphan-blob collection
- `blackbox ui` — loopback-only dashboard + read-only JSON API

## Configuration (`blackbox.toml`… `.blackbox/config.toml`)

```toml
[ignore]
patterns = ["*.log", "tmp/**"]

[ui]
port = 8901
```

Defaults ignore `.git`, `node_modules`, `zig-out`, `target`, `build`, `dist`, caches.

## Architecture

```
src/
  main.zig      entry + dispatch
  cli.zig       parsing, help
  log.zig       BLACKBOX_LOG=debug|info|warn|error (stderr)
  config.zig    init, identity, ignore/UI config
  db.zig        SQLite layer, migrations, prepared statements
  session.zig   supervisor: spawn, signals, timing, exit codes
  record.zig    recorder: baseline, polling, diff, rename pairing
  scan.zig      walker, stat+hash
  store.zig     content-addressed blobs
  events.zig    event queue + queries
  diff.zig      LCS line diffs
  git.zig       best-effort branch/HEAD/dirty
  views.zig     sessions/inspect rendering
  server.zig    loopback HTTP + JSON API
  ui/index.html embedded dashboard (no build step)
```

Decisions: `docs/adr/`.

## Privacy

Entirely local-first. No telemetry, no accounts, no sync. The UI binds
127.0.0.1 only. Secrets are never recorded (only file metadata + contents
of project files the agent itself touches). Nothing leaves the machine.

## Current limitations (honest)

- Filesystem observation is scan-based (2s poll + final pass), not inotify —
  sub-second create/delete cycles can coalesce.
- Child-process *trees* of the agent are killed as a group on interrupt but
  not individually recorded yet (no ptrace/eBPF in v0.1).
- Timestamps render in UTC.
- No `rewind` yet — but every observed version is already stored and
  retrievable, so rewind is a checkout operation away.
