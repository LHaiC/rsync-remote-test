# rsync-remote-test

A minimal Codex skill for local editing with remote build/test execution over SSH.

## Use

Bind an existing local checkout:

```bash
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh bind example-host /home/example/project
```

Or bootstrap an empty local checkout from a remote tree:

```bash
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh init example-host /home/example/project
```

Push local source to the remote test tree:

```bash
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh push --dry-run --no-delete
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh push --no-delete
```

Run a remote command:

```bash
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh run -- 'make test'
```

Pull only allowlisted remote paths:

```bash
# in .remote-dev.env
REMOTE_PULL_PATHS=results

~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh pull-path --dry-run --path results
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh pull-path --path results
```

## Safety

- Edit locally only; do not patch files through SSH.
- Every transfer has one direction and one explicit command.
- `push`/`push-path` use `.remote-dev.pushignore`.
- `pull`/`pull-path`/`fetch-artifacts` use `.remote-dev.pullignore`.
- Remote-to-local path pulls require `REMOTE_PULL_PATHS` or `REMOTE_ARTIFACT_PATHS`.
- No automatic bidirectional merge.
- No fallback host, path, tmux session, or cleanup behavior.
