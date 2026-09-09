# Install Annalist

## Linux release archive

The validated environment is Ubuntu 24.04 x86-64, including an unprivileged minimal-container run without developer libraries. The binary links system glibc and `libsqlite3.so.0`; it is not a static or cross-platform executable. Each archive includes `RUNTIME.txt` with its build environment and linked-library information. Zig is **not** needed to run a prebuilt archive. See [verification evidence](VERIFICATION.md).

From the directory containing the archive and its checksum:

```sh
sha256sum -c annalist-1.0.0-rc.1-linux-x86_64.tar.gz.sha256
tar -xzf annalist-1.0.0-rc.1-linux-x86_64.tar.gz
cd annalist-1.0.0-rc.1-linux-x86_64
install -Dm755 annalist "$HOME/.local/bin/annalist"
"$HOME/.local/bin/annalist" version
```

Ensure `$HOME/.local/bin` is on your PATH. If the loader reports `libsqlite3.so.0` missing, install your distribution's SQLite runtime package (`libsqlite3-0` on Ubuntu). A checksum verifies integrity against the accompanying checksum file; it is not a publisher signature. This candidate is unsigned.

## Build from source

Install Zig 0.15.2, a C toolchain, and SQLite development headers. Then:

```sh
zig build -Doptimize=ReleaseSafe
install -Dm755 zig-out/bin/annalist "$HOME/.local/bin/annalist"
```

To test and generate your own archive, run `sh scripts/check.sh`. Set `ZIG` to the Zig executable's absolute path when it is not on PATH.

## First run

Use a disposable project for the example command:

```sh
cd /path/to/your/test-project
annalist init
# Review .annalist/config.toml and add .annalist/ to .gitignore.
annalist run -- sh -c 'printf "hello\n" > example.txt'
annalist sessions
annalist ui
```

Open `http://127.0.0.1:8901`; stop the server with Ctrl+C. In a real project, replace the example with your normal coding command. Read [privacy and recording boundaries](../README.md#privacy-and-recording-boundaries) before recording private work.

## Upgrade, remove, and troubleshoot

- **Upgrade:** stop running recordings, the UI, and maintenance commands. Back up the user-level index and each project's `.annalist/` before replacing the binary. Do not downgrade an index without checking schema compatibility; use the backup if needed.
- **Remove:** remove only the installed binary to uninstall. Existing histories remain in their documented storage locations. Delete those separately only when you intentionally want to erase the recordings.
- **Command not found:** use the absolute installed path or add `$HOME/.local/bin` to PATH.
- **Not an Annalist project:** run `annalist init` at the project root.
- **Project busy:** another recording or maintenance command holds the lock. Stop it normally; a leftover lock filename alone does not hold the OS lock.
- **Dashboard port in use:** choose a different `[ui] port` in `.annalist/config.toml` and restart the UI.
- **Recovery refuses:** inspect the reported conflict, run `annalist doctor`, and preview again. `--force` permits overwriting later edits but does not bypass missing content or unsafe paths.
- **Recording interrupted:** run `annalist doctor` when no recorder is active. Use `doctor --fix` to finalize stale runs; it cannot recover events that were never observed.
