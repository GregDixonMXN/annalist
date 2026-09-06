# ADR 0001 — SQLite for persistence

## Context

Annalist needs crash-resistant local storage for sessions, events, projects,
and file states. Candidates: SQLite, append-only JSONL, embedded KV (RocksDB-style).

## Decision

SQLite (system library, linked) with WAL mode, `synchronous=NORMAL`,
foreign keys on, and explicit versioned migrations in `src/db.zig`.

## Alternatives

- JSONL logs: simple but queries (timelines, counts) become full scans; no transactions.
- Embedded KV: heavier dependency, worse ad-hoc querying.

## Consequences

- All SQL lives in `db.zig` behind typed helpers; callers never write raw SQL.
- A corrupted session row cannot corrupt other sessions (row-granular, WAL).
- Requires libsqlite3 on the build machine. Acceptable: present by default on
  all target platforms.
