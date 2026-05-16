---
name: rsync-remote-test
description: Use when working in a local Linux checkout that must be synced one-way to an SSH-accessible remote development server for remote build, test, or run commands, especially when the remote has no outbound internet.
---

# Rsync Remote Test

Use this skill to keep Codex edits local while using a remote Linux host only as a build/test/run machine.

## Non-Negotiable Rules

- Edit only the local checkout. Do not edit files through `ssh`, remote shells, or remote editors.
- Sync only local -> remote. Do not rsync back from the remote.
- Use only the configured remote development directory. Do not push to production, shared deploy, or system directories.
- Do not invent fallback hosts, directories, tmux sessions, or cleanup commands. If config is missing or ambiguous, stop and ask.
- Treat remote test results as valid only after reading actual remote output.

## Setup Per Project

Run from the exact local project root:

```bash
~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh init <remote-host> <remote-dev-root> [tmux-session]
```

This creates:

- `.remote-dev.env` with `LOCAL_ROOT`, `REMOTE_HOST`, `REMOTE_ROOT`, `REMOTE_TMUX`, and `RSYNC_EXCLUDE_FILE`
- `.remote-dev.rsyncignore` with build/cache excludes

Keep both files local unless the user explicitly wants project-specific examples committed.

## Workflow

1. Inspect `.remote-dev.env` before running remote commands.
2. Edit and test locally when possible.
3. Preview sync when risk is unclear:
   ```bash
   ~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh sync --dry-run --no-delete
   ```
4. Sync explicitly with one delete policy:
   ```bash
   ~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh sync --no-delete
   ~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh sync --delete
   ```
5. Run the remote command:
   ```bash
   ~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh run -- 'cargo test'
   ```
6. In tmux mode, inspect output before reporting status:
   ```bash
   ~/.codex/skills/rsync-remote-test/scripts/remote-dev.sh log 120
   ```

## Delete Policy

The script requires exactly one of `--delete` or `--no-delete` for every sync.

- Use `--no-delete` when unsure, during first setup, or when remote build directories may include useful state.
- Use `--delete` when the remote source mirror must match local tracked/untracked source files.
- The script never uses `--delete-excluded`, so excluded build caches such as `target/` and `build/` are not removed by rsync.

## Remote Execution

- If `REMOTE_TMUX` is set, `run` verifies the session exists and sends `cd REMOTE_ROOT && <command>` to that session.
- If `REMOTE_TMUX` is empty, `run` executes through direct `ssh`.
- The script does not create tmux sessions because the user may need project-specific conda, module, CUDA, or compiler setup.

## Failure Handling

- Missing config, missing exclude file, unsafe remote root, non-root local cwd, or unknown delete behavior is a hard stop.
- If `sync --dry-run` shows surprising deletes or uploads, discuss with the user before running a real sync.
- If remote build/test fails, diagnose from the remote output and local source state. Do not patch remote files manually.
