---
name: rsync-remote-test
description: Use when a local Linux checkout must use an SSH-accessible remote host for build, test, run, or result retrieval.
---

# Rsync Remote Test

Use `scripts/remote-dev.sh` from the local project root. Codex edits local files only; the remote host is for build/test/run.

## Rules

- No remote edits. Do not patch files through `ssh`, remote shells, or remote editors.
- No automatic two-way merge. Every transfer is explicit and directional.
- Local -> remote: `push` / `push-path`, filtered by `.remote-dev.pushignore`.
- Remote -> local: `pull` / `pull-path` / `pull-git-metadata`, filtered by `.remote-dev.pullignore`.
- `REMOTE_PULL_PATHS` are pull-only: they can be pulled from remote and are excluded from later pushes.
- If config, path, host, tmux, delete policy, or dry-run output is unclear, stop and ask.

## Setup

Bootstrap an empty local checkout from an existing remote tree:

```bash
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh init <remote-host> <remote-root> [tmux-session]
```

Bind an existing local checkout:

```bash
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh bind <remote-host> <remote-root> [tmux-session]
```

Generated local config:

```bash
PUSH_EXCLUDE_FILE=.remote-dev.pushignore
PULL_EXCLUDE_FILE=.remote-dev.pullignore
REMOTE_PULL_PATHS=
```

## Commands

```bash
# Bootstrap pull, remote -> local. Real pull requires a bootstrap-clean directory.
remote-dev.sh pull --dry-run
remote-dev.sh pull

# Source push, local -> remote. Pick one delete policy.
remote-dev.sh push --dry-run --no-delete
remote-dev.sh push --no-delete
remote-dev.sh push --delete

# Narrow source push, local -> remote.
remote-dev.sh push-path --dry-run --no-delete --path src
remote-dev.sh push-path --no-delete --path src

# Pull-only remote result paths, remote -> local same relative path.
# First set, for example: REMOTE_PULL_PATHS=results,examples/run/results
remote-dev.sh pull-path --dry-run --path results
remote-dev.sh pull-path --path results

# Remote execution.
remote-dev.sh run -- 'cargo test'
remote-dev.sh log 120

# Explicit Git metadata repair only.
# First set, for example: REMOTE_PULL_PATHS=third_party/.git
remote-dev.sh pull-git-metadata --dry-run --path third_party
remote-dev.sh pull-git-metadata --path third_party
```

## Safety Notes

- `pull-path` requires an exact `REMOTE_PULL_PATHS` match and does not delete unless `--delete` is explicit.
- `push` excludes all `REMOTE_PULL_PATHS`; `push-path` rejects pull-only paths and excludes pull-only children.
- `push` / `push-path` require exactly one of `--delete` or `--no-delete`.
- `rsync` uses `--no-owner --no-group` and keeps permissions, including executable bits.
- `pull-git-metadata` backs up local metadata, excludes locks/hooks, and keeps root `.git` blocked unless `--root-git` is explicit.
