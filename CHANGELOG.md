# Changelog

## 1.0.0-rc.1

### Product

- Redesigned offline dashboard with searchable run history, outcome filters, before/after file previews, responsive layouts, and first-run guidance.
- Recovery previews with required-content validation and retained pre-recovery copies.
- Clear recording, privacy, backup, and retention boundaries in the CLI and documentation.
- Linux x86-64 release archive, checksums, and automated release verification.

### Reliability and security

- Persist observed file events during live recordings; serialize recording and maintenance per project.
- Validate stored content hashes and publish blobs atomically.
- Transactional migrations and imports, validated bundle metadata, and staged bundle exports.
- Refuse unsafe recovery paths and symlink traversal; replace individual files atomically.
- Private defaults for newly created recorder storage and common secret-filename exclusions.
- Harden loopback HTTP access and render recorded text without interpreting it as markup.
- Forward termination to wrapped process groups and preserve interactive terminal input.
- Reject out-of-range imported dates and render malformed existing history without crashing.
- Retry interrupted content capture without inventing deletions or missing file-version references.
- Keep live history readable and make retention previews match actual removal counts.

### Compatibility

- Requires Zig 0.15.2 to build and system SQLite at runtime.
- Retains the existing SQLite/blob layout; back up both the index and project data before upgrading.
- Do not run older Annalist versions concurrently against the same project.
- This candidate is a local recorder, not an audit-complete trace or whole-project backup. See [release limits](docs/RELEASE.md).
