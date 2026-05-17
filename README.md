# rsync-remote-test

Minimal Codex skill for local editing with remote build/test/run over SSH.

## Usage

```bash
# bind an existing local checkout
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh bind example-host /home/example/project

# push local source to the remote host
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh push --dry-run --no-delete
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh push --no-delete

# run remotely
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh run -- 'make test'

# pull an allowlisted result path back to the same local path
# in .remote-dev.env: REMOTE_PULL_PATHS=results
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh pull-path --dry-run --path results
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh pull-path --path results
```

For Codex behavior rules, see `SKILL.md`.
