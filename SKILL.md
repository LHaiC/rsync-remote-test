---
name: rsync-remote-test
description: Use when a local Linux checkout needs an SSH-accessible remote build/test/run host, including remote-first bootstrap, one-way source sync, and safe retrieval of remote result artifacts.
---

# Rsync Remote Test

Use this skill to bootstrap a local checkout from an SSH-accessible remote development tree, then keep Codex edits local while using the remote Linux host as a build/test/run machine.

## Non-Negotiable Rules

- Edit only the local checkout. Do not edit files through `ssh`, remote shells, or remote editors.
- After bootstrap, sync only local -> remote. Remote -> local is allowed only through the explicit bootstrap `pull` command.
- Remote run outputs may be fetched only through `fetch-artifacts` and only from configured artifact paths.
- Use only the configured remote development directory. Do not push to production, shared deploy, or system directories.
- Do not invent fallback hosts, directories, tmux sessions, or cleanup commands. If config is missing or ambiguous, stop and ask.
- Treat remote test results as valid only after reading actual remote output.

## Setup Per Project

Run from the exact local project root. If the remote tree already has the project and the local tree is empty, use:

```bash
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh init <remote-host> <remote-dev-root> [tmux-session]
```

`init` creates `.remote-dev.env` and `.remote-dev.rsyncignore`, then runs one bootstrap pull from remote -> local. The real pull is allowed only when the local directory is empty or contains only those two config files.

If the local tree already has source files and only needs binding, use:

```bash
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh bind <remote-host> <remote-dev-root> [tmux-session]
```

Keep generated config files local unless the user explicitly wants project-specific examples committed.

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
   ~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh sync --dry-run --no-delete
   ```
6. Sync explicitly with one delete policy:
   ```bash
   ~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh sync --no-delete
   ~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh sync --delete
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

## Delete Policy

`pull` never deletes local files and has no delete option. `sync` requires exactly one of `--delete` or `--no-delete`. `fetch-artifacts` does not delete unless `--delete` is explicit.

- Use `--no-delete` when unsure, during first setup, or when remote build directories may include useful state.
- Use `--delete` when the remote source mirror must match local tracked/untracked source files.
- The script never uses `--delete-excluded`, so excluded build caches such as `target/` and `build/` are not removed by rsync.
- Rsync uses `--no-owner --no-group` to avoid cross-account group metadata noise such as `.f.....g...`; it does not use `--no-perms`, so executable bits still transfer.

## Artifact Fetch

Set `REMOTE_ARTIFACT_PATHS` in `.remote-dev.env` before fetching remote outputs:

```bash
REMOTE_ARTIFACT_PATHS=results,logs,outputs,pr/test/results
```

Rules:

- Entries must be relative directories under `REMOTE_ROOT`.
- Fetched files land under `LOCAL_ROOT/remote_artifacts/<entry>/`.
- Whole source roots such as `pr`, `sta`, `.git`, `.`, absolute paths, parent traversal, globs, and whitespace are rejected.
- `remote_artifacts/` is excluded from local -> remote source sync.

## Remote Execution

- If `REMOTE_TMUX` is set, `run` verifies the session exists and sends `cd REMOTE_ROOT && <command>` to that session.
- If `REMOTE_TMUX` is empty, `run` executes through direct `ssh`.
- The script does not create tmux sessions because the user may need project-specific conda, module, CUDA, or compiler setup.

## Failure Handling

- Missing config, missing exclude file, unsafe remote root, non-root local cwd, dirty bootstrap pull target, empty artifact allowlist, unsafe artifact path, or unknown delete behavior is a hard stop.
- If `sync --dry-run` shows surprising deletes or uploads, discuss with the user before running a real sync.
- If `fetch-artifacts --dry-run` shows source files or unexpected deletes, stop and discuss instead of widening the allowlist.
- If remote build/test fails, diagnose from the remote output and local source state. Do not patch remote files manually.
