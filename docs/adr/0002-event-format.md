# ADR 0002 — Event format

## Context

Everything observed becomes an event that must stay readable for years and
feed the CLI, the JSON API, and the dashboard without per-consumer logic.

## Decision

One `events` table, one row per observation:

- `seq` (per-session order), `ts` (epoch millis), `type` (string, versioned by
  convention: `file_created`, `session_started`, …)
- `path` / `prev_path` (rename support), `prev_hash` / `new_hash`
  (content-addressed snapshots, nullable), `size`
- Generic views can display event names, but bundle imports validate supported
  types and their metadata before accepting rows. New types need an explicit
  validation and compatibility decision.

## Alternatives

- Typed tables per event class: faster queries per class, but schema churn
  on every new observation type.
- Nested JSON blobs: flexible but unqueryable without JSON1 and harder to
  keep stable.

## Consequences

- The table can represent new types without a schema migration, but this
  release does not record network traffic, tool calls, or token usage.
- `prev_hash`/`new_hash` never store contents — only the blob store does.
