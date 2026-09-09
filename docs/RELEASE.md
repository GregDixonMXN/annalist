# Release gates · 1.0.0-rc.1

## Intended v1 scope

Local Linux coding history, observed changes, safe recovery previews, portable run bundles, manual retention, and an offline read-only dashboard. No cloud, billing, identity service, telemetry, or complete-agent-trace claims.

## Required checks

- Zig 0.15.2 Debug and ReleaseSafe compile; discovered unit tests pass.
- Isolated CLI regressions: initialization, validation, recording, exit status, signal forwarding, live event persistence, locks, import/export, corrupt-content handling, recovery safety, private new storage, and HTTP protections.
- Desktop/mobile real-browser review: empty history, populated history, search/filter, run details, file previews, guide, error handling, no overflow or script execution from captured text.
- Local optimized artifact and SHA-256; runtime dependencies documented. CI must pass on the eventual hosted repository before publication.
- Extracted archive passes CLI/HTTP/PTY checks in the minimal unprivileged Ubuntu 24.04 runtime, without a development toolchain.

All local checks above passed for this candidate; see [verification evidence](VERIFICATION.md).

## External publication gates

1. The owner must select/authorize a license and confirm distribution rights. There is no existing license file; do not imply open-source permission or choose one on their behalf.
2. Hosted CI has not been executed by local work. Run the committed workflow in the destination repository before release.
3. Signing, distribution channel, support policy, and compatibility claims beyond the tested Ubuntu 24.04 host/container remain publication decisions. The local archive is an unsigned release candidate, not a published release.

## Known technical limits

- Linux x86-64 is the validated target. macOS/Windows and cross-compilation are not promised.
- Two-second snapshots are not an audit-complete trace. Baseline snapshots contain eligible unchanged files and may contain secrets.
- No transactional whole-tree restore; pre-recovery copies mitigate partial filesystem failures. Stop other file writers first. Permission/symlink/empty-directory recovery is not supported.
- Existing storage permissions are not silently rewritten. Older binaries do not honor the operation lock.
- Shared SQLite migration/writer contention is bounded by a five-second busy timeout.
- Dashboard history/event windows and preview size are bounded; large repositories and long histories still require practical capacity validation.
- Each exported run is atomic as a bundle; a multi-run export is not an all-or-nothing batch. Failed imports may leave collectable unreferenced objects.
