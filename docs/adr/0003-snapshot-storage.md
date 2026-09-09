# ADR 0003 — Snapshot storage

## Context

Rewind needs before/after contents of changed files without copying the repo
on every change, without ballooning disk, and without ever risking user data.

## Decision

Content-addressed blobs under `.annalist/objects/xx/rest` (SHA-256):

- Session start seeds eligible regular files under the size limit (deduplicated).
- Each change event stores after-blobs; before-blobs resolve from the seed.
- Files over 10 MiB record metadata only (no stored content hash).
- Symlinks record target identity, not followed contents.
- Verify content on reads; publish new objects using synchronized temporary
  files and atomic rename. Existing corrupt objects fail validation.

## Alternatives

- Full repo copy per session: simple, unbounded disk.
- Deltas only: smaller, but reconstruction needs full chains; corruption in
  one link breaks history.

## Consequences

- Only successfully captured regular-file content is recoverable. Polling can
  miss short-lived changes, and unreadable or oversized files have limits.
- `.annalist/` grows with unique content; `annalist doctor --gc` collects
  unreferenced blobs when the project is not recording.
- Rewind validates required content and safe destinations before mutation,
  retains pre-recovery copies, and replaces individual files atomically.
  Whole-tree recovery is not an atomic filesystem transaction.
