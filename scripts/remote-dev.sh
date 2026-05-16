#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE='.remote-dev.env'
DEFAULT_EXCLUDE_FILE='.remote-dev.rsyncignore'

fail() {
  printf 'remote-dev: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  remote-dev.sh init <remote-host> <remote-root> [tmux-session]
  remote-dev.sh sync --dry-run --delete|--no-delete
  remote-dev.sh sync --delete|--no-delete
  remote-dev.sh run -- '<remote command>'
  remote-dev.sh log [lines]
EOF
}

contains_space() {
  case "$1" in
    *[[:space:]]*) return 0 ;;
    *) return 1 ;;
  esac
}

single_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"
}

validate_simple_path() {
  local name=$1 value=$2
  [ -n "$value" ] || fail "$name is empty"
  if contains_space "$value"; then
    fail "$name must not contain whitespace: $value"
  fi
}

validate_remote_root() {
  validate_simple_path REMOTE_ROOT "$REMOTE_ROOT"
  case "$REMOTE_ROOT" in
    /*) ;;
    *) fail "REMOTE_ROOT must be absolute: $REMOTE_ROOT" ;;
  esac
  case "${REMOTE_ROOT%/}" in
    ''|'/'|'/home'|'/tmp'|'/srv'|'/var'|'/usr'|'/opt'|'/root')
      fail "REMOTE_ROOT is too broad or unsafe: $REMOTE_ROOT"
      ;;
  esac
}

load_config() {
  [ -f "$CONFIG_FILE" ] || fail "missing $CONFIG_FILE; run init from the project root"
  # shellcheck disable=SC1090
  source "./$CONFIG_FILE"
  : "${LOCAL_ROOT:?LOCAL_ROOT is required in $CONFIG_FILE}"
  : "${REMOTE_HOST:?REMOTE_HOST is required in $CONFIG_FILE}"
  : "${REMOTE_ROOT:?REMOTE_ROOT is required in $CONFIG_FILE}"
  : "${RSYNC_EXCLUDE_FILE:?RSYNC_EXCLUDE_FILE is required in $CONFIG_FILE}"
  REMOTE_TMUX=${REMOTE_TMUX:-}

  validate_simple_path LOCAL_ROOT "$LOCAL_ROOT"
  validate_simple_path REMOTE_HOST "$REMOTE_HOST"
  validate_simple_path RSYNC_EXCLUDE_FILE "$RSYNC_EXCLUDE_FILE"
  validate_remote_root

  local cwd
  cwd=$(pwd -P)
  [ "$cwd" = "$LOCAL_ROOT" ] || fail "run from LOCAL_ROOT exactly: $LOCAL_ROOT"
  [ -f "$LOCAL_ROOT/$RSYNC_EXCLUDE_FILE" ] || fail "missing exclude file: $RSYNC_EXCLUDE_FILE"
}

write_default_excludes() {
  cat > "$DEFAULT_EXCLUDE_FILE" <<'EOF'
.git/
.remote-dev.env
.remote-dev.rsyncignore
target/
build/
cmake-build-*/
node_modules/
.venv/
__pycache__/
.pytest_cache/
.mypy_cache/
.ruff_cache/
.cache/
.DS_Store
EOF
}

cmd_init() {
  [ "$#" -ge 2 ] || { usage; fail "init requires <remote-host> <remote-root> [tmux-session]"; }
  [ "$#" -le 3 ] || { usage; fail "too many init arguments"; }
  [ ! -e "$CONFIG_FILE" ] || fail "$CONFIG_FILE already exists"
  [ ! -e "$DEFAULT_EXCLUDE_FILE" ] || fail "$DEFAULT_EXCLUDE_FILE already exists"

  local local_root remote_host remote_root remote_tmux
  local_root=$(pwd -P)
  remote_host=$1
  remote_root=$2
  remote_tmux=${3:-}

  validate_simple_path LOCAL_ROOT "$local_root"
  validate_simple_path REMOTE_HOST "$remote_host"
  REMOTE_ROOT=$remote_root
  validate_remote_root
  if contains_space "$remote_tmux"; then
    fail "REMOTE_TMUX must not contain whitespace: $remote_tmux"
  fi

  cat > "$CONFIG_FILE" <<EOF
LOCAL_ROOT=$local_root
REMOTE_HOST=$remote_host
REMOTE_ROOT=$remote_root
REMOTE_TMUX=$remote_tmux
RSYNC_EXCLUDE_FILE=$DEFAULT_EXCLUDE_FILE
EOF
  write_default_excludes
  printf 'Created %s and %s\n' "$CONFIG_FILE" "$DEFAULT_EXCLUDE_FILE"
}

cmd_sync() {
  load_config
  local dry_run=0 delete_mode=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1 ;;
      --delete|--no-delete)
        [ -z "$delete_mode" ] || fail "choose exactly one of --delete or --no-delete"
        delete_mode=$1
        ;;
      *) usage; fail "unknown sync option: $1" ;;
    esac
    shift
  done
  [ -n "$delete_mode" ] || fail "choose exactly one of --delete or --no-delete"

  local -a args
  args=(rsync -az --human-readable --info=stats2,progress2)
  [ "$dry_run" -eq 1 ] && args+=(--dry-run)
  [ "$delete_mode" = '--delete' ] && args+=(--delete)
  args+=(--exclude-from="$LOCAL_ROOT/$RSYNC_EXCLUDE_FILE")
  args+=("$LOCAL_ROOT/" "$REMOTE_HOST:${REMOTE_ROOT%/}/")
  "${args[@]}"
}

require_command_after_dashdash() {
  [ "$#" -ge 2 ] || { usage; fail "run requires -- '<remote command>'"; }
  [ "$1" = '--' ] || { usage; fail "put remote command after --"; }
  shift
  [ "$#" -gt 0 ] || fail "remote command is empty"
  printf '%s' "$*"
}

cmd_run() {
  load_config
  local remote_cmd
  remote_cmd=$(require_command_after_dashdash "$@")
  local cd_cmd="cd $(single_quote "$REMOTE_ROOT") && $remote_cmd"

  if [ -n "$REMOTE_TMUX" ]; then
    ssh "$REMOTE_HOST" "tmux has-session -t $REMOTE_TMUX" || fail "tmux session not found on $REMOTE_HOST: $REMOTE_TMUX"
    ssh "$REMOTE_HOST" "tmux send-keys -t $REMOTE_TMUX \"$cd_cmd\" C-m"
    printf 'Sent command to %s tmux session %s. Use log to inspect output.\n' "$REMOTE_HOST" "$REMOTE_TMUX"
  else
    ssh "$REMOTE_HOST" "$cd_cmd"
  fi
}

cmd_log() {
  load_config
  [ -n "$REMOTE_TMUX" ] || fail "REMOTE_TMUX is empty; log only works in tmux mode"
  local lines=${1:-120}
  case "$lines" in
    ''|*[!0-9]*) fail "lines must be a positive integer" ;;
  esac
  [ "$lines" -gt 0 ] || fail "lines must be a positive integer"
  ssh "$REMOTE_HOST" "tmux capture-pane -pt $REMOTE_TMUX -S -$lines"
}

main() {
  [ "$#" -gt 0 ] || { usage; exit 2; }
  local subcommand=$1
  shift
  case "$subcommand" in
    init) cmd_init "$@" ;;
    sync) cmd_sync "$@" ;;
    run) cmd_run "$@" ;;
    log) cmd_log "$@" ;;
    -h|--help|help) usage ;;
    *) usage; fail "unknown subcommand: $subcommand" ;;
  esac
}

main "$@"
