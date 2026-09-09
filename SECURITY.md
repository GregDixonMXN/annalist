# Security

Annalist is a local recorder, not a sandbox. The wrapped command retains its normal filesystem and network access. The dashboard is a read-only loopback service and should not be exposed through a reverse proxy or bound to a public interface.

## Protecting recorded work

Recorded file contents, command arguments, and exported bundles can contain sensitive material. Filename exclusions reduce accidental capture but do not detect all secrets. There is no automatic argument redaction or at-rest encryption. Review [recording boundaries and backups](README.md#privacy-and-recording-boundaries) before use.

Keep `.annalist/` out of source control. Back up both the user-level database and per-project objects. Stop other file writers before recovery and review `annalist rewind <id> --dry-run` before applying changes. Retained recovery copies are not a replacement for independent backups.

## Reporting a vulnerability

Use the repository's private vulnerability-reporting channel if the owner has enabled it. Otherwise, contact the repository owner privately before publishing exploit details. No public security inbox or response-time commitment has been configured for this release candidate.

Provide the version, operating system, minimal synthetic reproduction, expected behavior, and observed result. Do not attach a real recorder database, export bundle, source-code capture, credential, or personal path when a synthetic fixture demonstrates the issue.
