# ADR 0003 — Snapshot storage

## Context

Rewind needs before/after contents of changed files without copying the repo
on every change, without ballooning disk, and without ever risking user data.

## Decision

Content-addressed blobs under `.annalist/objects/xx/rest` (SHA-256):

- Session start seeds blobs for all files under the size limit (deduplicated).
- Each change event stores after-blobs; before-blobs resolve from the seed.
- Files over 10 MB record metadata only (no hash) — explicit, never silent.
- Symlinks record target identity, not followed contents.
- Overwrite via exclusive create; identical content stored once.

## Alternatives

- Full repo copy per session: simple, unbounded disk.
- Deltas only: smaller, but reconstruction needs full chains; corruption in
  one link breaks history.

## Consequences

- Every observed version is retrievable today (`inspect --file` proves it);
  rewind later is a checkout operation, not a research project.
- `.annalist/` grows with unique content; `annalist doctor` (future) can GC
  unreferenced blobs.
