# Annalist GitHub Action

Runs one recorded command per job, exports the session bundle, and enforces
`annalist gate`. The gate exit code becomes the check result: 0 green,
2 red (policy deny), 1 red (broken session, storage, or policy file).

Linux x86_64 runners only. No Zig toolchain needed: the Action downloads the
release binary and verifies its checksum.

## Use

```yaml
jobs:
  agent:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: GregDixonMXN/annalist/.github/actions/annalist-run@v1.0.0-rc.3
        with:
          command: mkdir -p src && printf 'hello\n' > src/hello.txt
          policy_file: examples/agent-pr/annalist.policy.toml
```

## Inputs

| Input | Required | Default | Meaning |
| ----- | -------- | ------- | ------- |
| `command` | yes | — | Shell command to record. |
| `policy_file` | no | `''` | Path to an `annalist.policy.toml`. When empty, a default policy is generated. |
| `fail_on_secret` | no | `'true'` | Secret-file denial, used only when `policy_file` is empty. |
| `version` | no | `'1.0.0-rc.3'` | Release version without the leading `v`. |
| `repository` | no | `'GregDixonMXN/annalist'` | Repo hosting the releases. |

Each run uploads an `annalist-bundle` artifact (the exported session) and
writes the session id plus the gate report to the job summary.

## What the Action does

1. Downloads `annalist-<version>-linux-x86_64.tar.gz` from Releases and checks the `.sha256`.
2. `annalist init` (skipped when `.annalist/` already exists).
3. `annalist run -- sh -c "<command>"`.
4. Exports the newest session to `./annalist-bundle/`.
5. `annalist gate --session <id> --policy <file>`; nonzero fails the step.
6. Uploads the bundle artifact (always, even on gate failure).

## Demo: green check and red check

`.github/workflows/agent-pr-demo.yml` runs on pull requests touching
`examples/agent-pr/**`:

- `demo-green` creates `src/hello.txt` under the example policy: green.
- `demo-red` writes `.env` under the same policy: red (gate exit 2).

Open a PR that touches `examples/agent-pr/` and both checks appear on it.

## Making it required

Repo Settings → Branches → branch protection for `main` → Require status
checks to pass → search for `demo-green` (and `demo-red` while demoing) →
Save. A PR that writes `.env` then cannot merge until the gate passes.

## Policy reference

See the `README.md` "Policy gate" section. The example policy is
`examples/agent-pr/annalist.policy.toml`.
