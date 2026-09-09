# Release verification

## 1.0.0-rc.1 · 2026-09-09

Completed locally on Ubuntu 24.04 x86-64 with Zig 0.15.2.

| Check | Result |
| --- | --- |
| Debug | 24 unit tests, 43 integration checks, 2 real PTY checks passed |
| ReleaseSafe | 24 unit tests, 43 integration checks, 2 real PTY checks passed |
| Chromium and HTTP | 35 checks passed; zero browser JavaScript errors |
| Extracted release on the build host | Checksum, archive structure, executable/version/help, 43 integration and 2 PTY checks passed |
| Extracted release in minimal Ubuntu 24.04 | Same package checks, 43 integration and 2 PTY checks passed |
| Repository hygiene | Zig formatting, shell syntax, local documentation links, and `git diff --check` passed |

The container check uses the pinned image in `tests/runtime.Dockerfile`, system SQLite, and Python for the test harness. It has no Zig or C build toolchain. Tests run as UID/GID 65534 with networking disabled, a read-only root, and only tests/artifacts mounted read-only. No developer history is mounted.

Verified ReleaseSafe executable SHA-256:

```text
f09f3ff7214f502d7aba492771b175ef855422967d055526f99bbcf0194fb23f
```

The archive includes this executable, installation and release documentation, and `RUNTIME.txt`. Its adjacent `.sha256` file covers the finalized archive, including the completed verification report.

## Exercised behavior

- Live event persistence, command exit status, signal forwarding, terminal input, Ctrl+C, and foreground restoration.
- Maintenance exclusion during recording, unreadable-file handling, content-write retries, symlink metadata, and accurate prune previews.
- Export/import round trips, transactional rejection of malformed bundles, out-of-range timestamps, and defensive date/duration rendering for malformed existing history.
- Corrupt/missing object detection, recovery preflight, symlink escape refusal, later-edit conflicts, and retained pre-recovery copies.
- Offline dashboard, desktop/mobile containment, hostile filename rendering, valid double-dot filenames, before/after previews, preview caps, search, empty/error states, and retry.
- Loopback authority and cross-site protections, malformed URL decoding, and the absolute slow-header deadline.

All fixtures use synthetic projects and isolated HOME/XDG locations. No developer recorder database is used by the release checks.

## Reproduce

```sh
sh scripts/check.sh
```

The script tests Debug and ReleaseSafe, packages the release, verifies its checksum and contents, and runs CLI/HTTP/PTY regressions from the extracted archive. Set `ZIG=/absolute/path/to/zig` if needed.

To also verify the packaged runtime without developer libraries, with Docker available:

```sh
sh scripts/check-container.sh dist/annalist-1.0.0-rc.1-linux-x86_64.tar.gz
```

For real-browser checks, install Playwright 1.62.1 and Chromium in a development environment:

```sh
npm install --no-save --package-lock=false playwright@1.62.1
npx playwright install chromium
node tests/dashboard.cjs zig-out/bin/annalist
```

`CHROMIUM_EXECUTABLE_PATH` can select an already installed Chromium-compatible browser. The browser test uses synthetic data and prints the temporary directory containing screenshots and its JSON report.

## Scope

The minimal-container check verifies the Ubuntu 24.04 userspace with the host's Linux kernel; it is not a multi-distribution or full virtual-machine certification. Hosted CI has not been executed. The artifact is unsigned and is not published by these checks. See [release gates](RELEASE.md).
