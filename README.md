# Annalist

**A required check for AI-written PRs.** Record what your coding agent changed, gate it against policy, fail the PR when it writes secrets.

```yaml
- uses: GregDixonMXN/annalist/.github/actions/annalist-run@v1.0.0-rc.3
  with:
    command: mkdir -p src && printf 'hello\n' > src/hello.txt
    policy_file: examples/agent-pr/annalist.policy.toml
```

`command:` is any shell argv. `policy_file:` sets allow_paths, deny_globs, max_files_changed. Exit 0 green, 2 deny, 1 broken. Mark the check required under branch protection and a `.env`-writing PR cannot merge. Linux x86_64 runners only; the recorder samples every 2s; file contents are stored unredacted — review exclusions first.

**Proof.** Same policy, two jobs on one PR: [green — `src/hello.txt` passes](https://github.com/GregDixonMXN/annalist/actions/runs/34377464392/job/102553767965), [red — `.env` denied, gate exit 2](https://github.com/GregDixonMXN/annalist/actions/runs/34377464392/job/102553768346). The red is the product working, not a broken build.
**A clear history. A way back.**

Annalist is a local coding-work recorder. Wrap a coding agent or command, review observed file changes in a private loopback dashboard, and preview recovery before restoring touched files. No account, telemetry, cloud dependency, or network assets.

**1.0.0-rc.3 · Linux release candidate.** This is not a sandbox, full filesystem backup, or complete execution trace.

See [installation](docs/INSTALL.md), [release notes](CHANGELOG.md), and [security](SECURITY.md). Linux x86-64 is the supported release target; other platforms are not yet validated.

## Get running

If you have the Linux release archive, follow the [binary installation instructions](docs/INSTALL.md). Building from source:

Requires Linux x86-64, Zig **0.15.2**, a C toolchain, and SQLite development headers/library. On Debian/Ubuntu, install `build-essential libsqlite3-dev`; obtain Zig from [ziglang.org](https://ziglang.org/download/).

```sh
zig build -Doptimize=ReleaseSafe
install -Dm755 zig-out/bin/annalist "$HOME/.local/bin/annalist"
cd /path/to/your/project
annalist init
# Add .annalist/ to your project's .gitignore and review exclusions first.
annalist run -- codex
annalist ui
```

Open **http://127.0.0.1:8901**. Keep the terminal running; Ctrl+C stops the dashboard. Use `annalist run -- claude` or any other command instead of Codex. Interactive stdin/stdout/stderr are inherited, not saved as transcripts. The wrapped command's exit status is propagated; an incomplete recording also returns nonzero.

The dashboard offers command/ID search, outcome filters, run details, changed-file versions, and recovery instructions. It is read-only. Refresh to see newly recorded runs. It shows the newest 1,000 runs and first 10,000 events per run; use the CLI for full history. Text previews are limited to 256 KiB per version.

## Review and recover

```sh
annalist sessions
annalist inspect 1
annalist inspect 1 --json
annalist inspect 1 --file src/main.zig
annalist diff 1 2
annalist rewind 1 --dry-run
annalist rewind 1
```

Stop agents and editors before recovery. A full rewind restores **only paths touched by that run** to their pre-run state. `rewind 1 5` restores those paths to their state at event sequence 5. It is not a whole-project checkout. Later edits cause refusal; `--force` overrides that guard, not missing-content or unsafe-path checks. Symlink traversal is refused. All required content is validated before file mutation, and current touched files are copied into `.annalist/recovery/<timestamp>-<id>/`, with an adjacent JSON manifest recording absent paths. Individual writes are atomic; a multi-file recovery is **not** an atomic transaction. If I/O fails mid-recovery, use the retained copies and manifest to restore current work. Keep an independent backup.

## Privacy and recording boundaries

**File contents and command arguments can contain secrets. No automatic redaction or encryption is provided.** Eligible baseline file contents are stored even if the run never changes them. Review exclusions before the first run. Do not pass credentials as arguments. Protect exports as source-code archives.

- Annalist samples files every two seconds and once after the command exits. Short-lived edits can be missed; rename inference is based on matching content.
- Files over 10 MiB have metadata only. Symlink contents, permission history, empty directories, subprocess traces, terminal transcripts, and changes outside the project cannot be recovered.
- Annalist itself does not send telemetry. The command it wraps can access the network and filesystem normally.
- Default exclusions include `.git`, `.annalist`, dependency/build directories, `.env`/`.env.*`, `*.pem`, `*.key`, SSH private-key filenames, `.ssh`, and `.aws`. This is filename filtering, not secret detection. **Git ignore rules are not loaded.**
- New files created by Annalist default to owner-only access. Existing histories keep their existing permissions: inspect and restrict them yourself if needed.

Additional project-relative exclusions in `.annalist/config.toml`:

```toml
[ignore]
patterns = ["private/**", "*.log", "credentials.json"]

[ui]
port = 8901
```

The supported glob subset is `*`/`?` within a segment, exact relative paths, and trailing `/**` for a subtree. Default filename exclusions apply at any depth; custom patterns are relative to the project root. Avoid complex Git-style glob rules. Always test exclusions on synthetic data if unsure.

## Storage and backups

| Location | Contains |
| --- | --- |
| Project `.annalist/config.toml` | Project identity and settings |
| Project `.annalist/objects/` | Content-addressed file versions |
| Project `.annalist/recovery/` | Pre-recovery copies and manifests |
| `$XDG_DATA_HOME/annalist/annalist.db` | Shared session/event index |
| `~/.local/share/annalist/annalist.db` | Index fallback when XDG_DATA_HOME is unset |

Do not commit `.annalist/`. Back up **both** the project `.annalist/` and user-level database. Stop Annalist commands before a filesystem backup and include any `-wal`/`-shm` SQLite sidecars. A SQLite online backup is another supported way to copy the index. Copying only the index loses file content; copying only project objects loses the session index.

Portable completed-run bundles:

```sh
annalist export 1 --out ../run-1
annalist export --all --out ../history-bundles
# In another initialized project:
annalist import ../run-1
```

The output destination must not exist. Each individual bundle is staged then published locally only after all required blobs have been verified/copied. `--all` creates one subdirectory per run; earlier completed bundles remain if a later run fails. Import one bundle directory at a time. Imports verify hashes and commit rows transactionally, assign fresh IDs, and use the destination's current workstream. Failed imports may leave unreferenced verified objects; `doctor --gc` can collect those. `import --force` adds another copy, not an overwrite. Back up first when upgrading; the current SQLite and blob layout is preserved.

## Policy gate

```sh
annalist gate --session 1 --policy annalist.policy.toml
# exit 0 pass, exit 2 policy deny, exit 1 broken session/storage/policy
```

```toml
allow_paths = ["src/", "docs/", "tests/"]
deny_globs = [".env", ".env.*", "*.pem", "**/secrets/**"]
max_files_changed = 80
fail_on_secret = true
```

With no policy file the secret defaults still apply. Unknown keys are an error. The gate refuses unfinished sessions, fails when the index is corrupt or session content is missing, verifies the session exports, then prints a one-screen report of created/modified/deleted files and denials. Because the recorder ignores secrets, the gate also scans the working tree for secret-glob matches: a run that writes `.env` records no event for it, but still fails the gate.

## Maintenance

```sh
annalist branch experiment       # workstream label, not a Git branch
annalist sessions --branch main
annalist doctor                 # index integrity, stale runs, missing/corrupt objects
annalist doctor --fix           # mark interrupted runs left by a killed supervisor
annalist doctor --gc            # delete unreferenced objects
annalist policy --set-max-age 30
annalist prune --older-than 30 --dry-run
annalist prune --older-than 30
```

Retention is manual; policy does not schedule deletion. Prune removes old completed runs and unreferenced objects. Pre-recovery copies are not automatically pruned. Recording and CLI maintenance are mutually exclusive per project; a busy error means another command still holds the operation lock. After a crash, run `doctor` before recovery. Never run an older binary concurrently against the same project: older versions do not honor the new operation lock.

## Verify and package

```sh
sh scripts/check.sh
```

This checks formatting, unit tests in Debug and ReleaseSafe, CLI/HTTP/terminal regressions, and the same flows from the extracted release archive. Tests create isolated temporary HOME/XDG/project fixtures and never open your recorder index. Packaging produces a local archive and SHA-256 checksum under `dist/`; it does not publish. See [contributing](CONTRIBUTING.md), [release gates](docs/RELEASE.md), and [verification evidence](docs/VERIFICATION.md).
