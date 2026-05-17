---
name: rsync-remote-test
description: Use when a local Linux checkout needs an SSH-accessible remote build/test/run host, including remote-first bootstrap, controlled push/pull transfer, and safe retrieval of remote results.
---

# Rsync Remote Test

Use this skill to bootstrap a local checkout from an SSH-accessible remote development tree, then keep Codex edits local while using the remote Linux host as a build/test/run machine.

## Non-Negotiable Rules

- Edit only the local checkout. Do not edit files through `ssh`, remote shells, or remote editors.
- Do not do automatic two-way merge. Every transfer must name a direction and path.
- Local -> remote source transfer uses `push`/`push-path` and `.remote-dev.pushignore`.
- Remote -> local transfer uses `pull`, `pull-path`, `fetch-artifacts`, or `pull-git-metadata` and `.remote-dev.pullignore`.
- `pull-path` is allowed only for paths listed in `REMOTE_PULL_PATHS`; `fetch-artifacts` is allowed only for paths listed in `REMOTE_ARTIFACT_PATHS`.
- Use only the configured remote development directory. Do not push to production, shared deploy, or system directories.
- Do not invent fallback hosts, directories, tmux sessions, or cleanup commands. If config is missing or ambiguous, stop and ask.
- Treat remote test results as valid only after reading actual remote output.

## Setup Per Project

Run from the exact local project root. If the remote tree already has the project and the local tree is empty, use:

```bash
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh init <remote-host> <remote-dev-root> [tmux-session]
```

`init` creates `.remote-dev.env`, `.remote-dev.pushignore`, and `.remote-dev.pullignore`, then runs one bootstrap pull from remote -> local. The real pull is allowed only when the local directory is empty or contains only remote-dev config files.

If the local tree already has source files and only needs binding, use:

```bash
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh bind <remote-host> <remote-dev-root> [tmux-session]
```

Keep generated config files local unless the user explicitly wants project-specific examples committed.

The generated config uses directional ignore files:

```bash
PUSH_EXCLUDE_FILE=.remote-dev.pushignore
PULL_EXCLUDE_FILE=.remote-dev.pullignore
REMOTE_PULL_PATHS=
REMOTE_ARTIFACT_PATHS=
```

## Workflow

1. Inspect `.remote-dev.env` before running remote commands.
2. For a remote-first project, preview bootstrap before pulling:
   ```bash
   ~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh pull --dry-run
   ```
3. If the local directory is bootstrap-clean, pull once:
   ```bash
   ~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh pull
   ```
4. Edit and test locally when possible.
5. Preview local -> remote sync when risk is unclear:
   ```bash
   ~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh push --dry-run --no-delete
   ```
6. Sync explicitly with one delete policy:
   ```bash
   ~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh push --no-delete
   ~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh push --delete
   ```
7. Run the remote command:
   ```bash
   ~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh run -- 'cargo test'
   ```
8. In tmux mode, inspect output before reporting status:
   ```bash
   ~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh log 120
   ```
9. If remote runs produced result artifacts, fetch only allowlisted paths:
   ```bash
   ~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh fetch-artifacts --dry-run
   ~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh fetch-artifacts
   ```

## Controlled Path Transfer

Use path transfer when a full-tree push/pull is too broad:

```bash
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh push-path --dry-run --no-delete --path src
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh push-path --no-delete --path src
```

For remote -> local path pulls, first allowlist exact relative directories:

```bash
REMOTE_PULL_PATHS=results,logs,third_party/.git
```

Then pull explicitly:

```bash
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh pull-path --dry-run --path results
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh pull-path --path results
```

Rules:

- Paths are relative directories under `LOCAL_ROOT`/`REMOTE_ROOT`; absolute paths, `.`, `..`, whitespace, and globs are rejected.
- `push-path` requires exactly one of `--delete` or `--no-delete`.
- `pull-path` does not delete unless `--delete` is explicit.
- Use `.remote-dev.pushignore` for local -> remote and `.remote-dev.pullignore` for remote -> local.

## Delete Policy

`pull` never deletes local files and has no delete option. `push` and `push-path` require exactly one of `--delete` or `--no-delete`. `pull-path` and `fetch-artifacts` do not delete unless `--delete` is explicit.

- Use `--no-delete` when unsure, during first setup, or when remote build directories may include useful state.
- Use `--delete` when the target mirror must match the source path after ignore rules.
- The script never uses `--delete-excluded`, so excluded build caches such as `target/` and `build/` are not removed by rsync.
- Rsync uses `--no-owner --no-group` to avoid cross-account group metadata noise such as `.f.....g...`; it does not use `--no-perms`, so executable bits still transfer.

## Artifact Fetch

Set `REMOTE_ARTIFACT_PATHS` in `.remote-dev.env` before fetching remote outputs:

```bash
REMOTE_ARTIFACT_PATHS=results,logs,outputs
```

Rules:

- Entries must be relative directories under `REMOTE_ROOT`.
- Fetched files land under `LOCAL_ROOT/remote_artifacts/<entry>/`.
- `.git`, `.`, absolute paths, parent traversal, globs, and whitespace are rejected.
- `remote_artifacts/` is excluded from local -> remote source sync.

## Git Metadata Repair

Use this only when remote bootstrap copied source files but excluded Git metadata needed by nested worktrees or submodules:

```bash
REMOTE_PULL_PATHS=third_party/.git
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh pull-git-metadata --dry-run --path third_party
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh pull-git-metadata --path third_party
```

Rules:

- Root `.git` is blocked unless `--root-git` is explicit.
- Local metadata is backed up before real pulls.
- Lock files and hooks are excluded.
- Remote `core.worktree` paths under `REMOTE_ROOT` are rewritten to `LOCAL_ROOT`.

## Remote Execution

- If `REMOTE_TMUX` is set, `run` verifies the session exists and sends `cd REMOTE_ROOT && <command>` to that session.
- If `REMOTE_TMUX` is empty, `run` executes through direct `ssh`.
- The script does not create tmux sessions because the user may need project-specific conda, module, CUDA, or compiler setup.

## Failure Handling

- Missing config, missing ignore file, unsafe remote root, non-root local cwd, dirty bootstrap pull target, empty pull/artifact allowlist, unsafe path, or unknown delete behavior is a hard stop.
- If `push --dry-run` or `pull-path --dry-run` shows surprising deletes or broad source movement, discuss with the user before running a real transfer.
- If `fetch-artifacts --dry-run` shows source files or unexpected deletes, stop and discuss instead of widening the allowlist.
- If remote build/test fails, diagnose from the remote output and local source state. Do not patch remote files manually.
