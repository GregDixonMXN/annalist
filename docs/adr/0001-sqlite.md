# ADR 0001 — SQLite for persistence

## Context

Annalist needs crash-resistant local storage for sessions, events, projects,
and file states. Candidates: SQLite, append-only JSONL, embedded KV (RocksDB-style).

## Decision

SQLite (system library, linked) with WAL mode, `synchronous=FULL`,
foreign keys on, and transactional versioned migrations in `src/db.zig`.
Observed events are persisted incrementally while recording. Per-project
operation locks coordinate recording and maintenance; the shared index uses
a bounded busy timeout for writer contention.

## Alternatives

- JSONL logs: simple but queries (timelines, counts) become full scans; no transactions.
- Embedded KV: heavier dependency, worse ad-hoc querying.

## Consequences

- SQLite helpers and domain operations share explicit transaction boundaries.
- Transactions prevent partially committed logical updates; WAL is not a
  substitute for backups or protection against storage corruption.
- Requires SQLite headers at build time and the shared library at runtime.
  The validated release target is Linux x86-64.
