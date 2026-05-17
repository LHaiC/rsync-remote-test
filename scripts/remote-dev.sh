#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE='.remote-dev.env'
DEFAULT_PUSH_EXCLUDE_FILE='.remote-dev.pushignore'
DEFAULT_PULL_EXCLUDE_FILE='.remote-dev.pullignore'

fail() {
  printf 'remote-dev: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  remote-dev.sh init <remote-host> <remote-root> [tmux-session]
  remote-dev.sh bind <remote-host> <remote-root> [tmux-session]
  remote-dev.sh pull --dry-run
  remote-dev.sh pull
  remote-dev.sh pull-path --dry-run --path <relative-path>
  remote-dev.sh pull-path [--delete] --path <relative-path>
  remote-dev.sh pull-git-metadata --dry-run --path <relative-path>
  remote-dev.sh pull-git-metadata --path <relative-path>
  remote-dev.sh pull-git-metadata --dry-run --root-git
  remote-dev.sh pull-git-metadata --root-git
  remote-dev.sh push --dry-run --delete|--no-delete
  remote-dev.sh push --delete|--no-delete
  remote-dev.sh push-path --dry-run --delete|--no-delete --path <relative-path>
  remote-dev.sh push-path --delete|--no-delete --path <relative-path>
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

validate_remote_token() {
  local name=$1 value=$2
  validate_simple_path "$name" "$value"
  case "$value" in
    -*|*[!A-Za-z0-9._@-]*) fail "$name contains unsafe characters: $value" ;;
  esac
}

normalize_relative_path() {
  local path=$1
  while [ "${path%/}" != "$path" ]; do
    path=${path%/}
  done
  [ -n "$path" ] || return 1
  contains_space "$path" && return 1
  case "$path" in
    /*|.|..|*..*|*"'"*|*'?'*|*'['*|*']'*) return 1 ;;
  esac
  printf '%s' "$path"
}

require_relative_path_value() {
  local name=$1 value=$2 normalized
  if ! normalized=$(normalize_relative_path "$value") || [ "$normalized" != "$value" ]; then
    fail "$name must be a normalized relative path: $value"
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
  LOCAL_ROOT=
  REMOTE_HOST=
  REMOTE_ROOT=
  REMOTE_TMUX=
  PUSH_EXCLUDE_FILE=
  PULL_EXCLUDE_FILE=
  REMOTE_PULL_PATHS=

  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) key=${line%%=*}; value=${line#*=} ;; *) fail "invalid config line: $line" ;; esac
    case "$key" in
      LOCAL_ROOT) LOCAL_ROOT=$value ;;
      REMOTE_HOST) REMOTE_HOST=$value ;;
      REMOTE_ROOT) REMOTE_ROOT=$value ;;
      REMOTE_TMUX) REMOTE_TMUX=$value ;;
      PUSH_EXCLUDE_FILE) PUSH_EXCLUDE_FILE=$value ;;
      PULL_EXCLUDE_FILE) PULL_EXCLUDE_FILE=$value ;;
      REMOTE_PULL_PATHS) REMOTE_PULL_PATHS=$value ;;
      *) fail "unknown config key: $key" ;;
    esac
  done < "$CONFIG_FILE"

  : "${LOCAL_ROOT:?LOCAL_ROOT is required in $CONFIG_FILE}"
  : "${REMOTE_HOST:?REMOTE_HOST is required in $CONFIG_FILE}"
  : "${REMOTE_ROOT:?REMOTE_ROOT is required in $CONFIG_FILE}"
  : "${PUSH_EXCLUDE_FILE:?PUSH_EXCLUDE_FILE is required in $CONFIG_FILE}"
  : "${PULL_EXCLUDE_FILE:?PULL_EXCLUDE_FILE is required in $CONFIG_FILE}"

  validate_simple_path LOCAL_ROOT "$LOCAL_ROOT"
  validate_remote_token REMOTE_HOST "$REMOTE_HOST"
  require_relative_path_value PUSH_EXCLUDE_FILE "$PUSH_EXCLUDE_FILE"
  require_relative_path_value PULL_EXCLUDE_FILE "$PULL_EXCLUDE_FILE"
  [ -z "$REMOTE_TMUX" ] || validate_remote_token REMOTE_TMUX "$REMOTE_TMUX"
  validate_remote_root

  local cwd
  cwd=$(pwd -P)
  [ "$cwd" = "$LOCAL_ROOT" ] || fail "run from LOCAL_ROOT exactly: $LOCAL_ROOT"
}

require_push_ignore() {
  [ -f "$LOCAL_ROOT/$PUSH_EXCLUDE_FILE" ] || fail "missing push ignore file: $PUSH_EXCLUDE_FILE"
}

require_pull_ignore() {
  [ -f "$LOCAL_ROOT/$PULL_EXCLUDE_FILE" ] || fail "missing pull ignore file: $PULL_EXCLUDE_FILE"
}

write_default_push_ignore() {
  cat > "$DEFAULT_PUSH_EXCLUDE_FILE" <<'EOF'
.git/
.remote-dev.env
.remote-dev.pushignore
.remote-dev.pullignore
target/
build/
install/
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

write_default_pull_ignore() {
  cat > "$DEFAULT_PULL_EXCLUDE_FILE" <<'EOF'
.git/
*.lock
index.lock
hooks/***
target/
build/
install/
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

write_project_config() {
  [ "$#" -ge 2 ] || { usage; fail "bind requires <remote-host> <remote-root> [tmux-session]"; }
  [ "$#" -le 3 ] || { usage; fail "too many bind arguments"; }
  [ ! -e "$CONFIG_FILE" ] || fail "$CONFIG_FILE already exists"
  [ ! -e "$DEFAULT_PUSH_EXCLUDE_FILE" ] || fail "$DEFAULT_PUSH_EXCLUDE_FILE already exists"
  [ ! -e "$DEFAULT_PULL_EXCLUDE_FILE" ] || fail "$DEFAULT_PULL_EXCLUDE_FILE already exists"

  local local_root remote_host remote_root remote_tmux
  local_root=$(pwd -P)
  remote_host=$1
  remote_root=$2
  remote_tmux=${3:-}

  validate_simple_path LOCAL_ROOT "$local_root"
  validate_remote_token REMOTE_HOST "$remote_host"
  REMOTE_ROOT=$remote_root
  validate_remote_root
  [ -z "$remote_tmux" ] || validate_remote_token REMOTE_TMUX "$remote_tmux"

  cat > "$CONFIG_FILE" <<EOF
LOCAL_ROOT=$local_root
REMOTE_HOST=$remote_host
REMOTE_ROOT=$remote_root
REMOTE_TMUX=$remote_tmux
PUSH_EXCLUDE_FILE=$DEFAULT_PUSH_EXCLUDE_FILE
PULL_EXCLUDE_FILE=$DEFAULT_PULL_EXCLUDE_FILE
REMOTE_PULL_PATHS=
EOF
  write_default_push_ignore
  write_default_pull_ignore
  printf 'Created %s, %s, and %s\n' "$CONFIG_FILE" "$DEFAULT_PUSH_EXCLUDE_FILE" "$DEFAULT_PULL_EXCLUDE_FILE"
}

rsync_base_args() {
  printf '%s\0' rsync -az --no-owner --no-group --human-readable --info=stats2,progress2
}


path_in_list() {
  local needle=$1 list=$2 raw normalized
  local IFS=','
  local -a entries
  read -r -a entries <<< "$list"
  for raw in "${entries[@]}"; do
    normalized=$(normalize_relative_path "$raw" 2>/dev/null || true)
    [ -n "$normalized" ] || continue
    [ "$needle" = "$normalized" ] && return 0
  done
  return 1
}

build_pull_only_excludes() {
  local push_root=$1 raw protected suffix
  PULL_ONLY_EXCLUDES=()
  [ -n "$REMOTE_PULL_PATHS" ] || return 0

  local IFS=','
  local -a entries
  read -r -a entries <<< "$REMOTE_PULL_PATHS"
  for raw in "${entries[@]}"; do
    protected=$(normalize_relative_path "$raw" 2>/dev/null || true)
    [ -n "$protected" ] || continue

    if [ -z "$push_root" ]; then
      PULL_ONLY_EXCLUDES+=(--exclude="$protected/")
      continue
    fi

    if [ "$push_root" = "$protected" ] || [[ "$push_root" == "$protected/"* ]]; then
      fail "push path is pull-only: $push_root"
    fi
    if [[ "$protected" == "$push_root/"* ]]; then
      suffix=${protected#"$push_root"/}
      PULL_ONLY_EXCLUDES+=(--exclude="$suffix/")
    fi
  done
}

cmd_bind() {
  write_project_config "$@"
}

local_bootstrap_clean() {
  local found
  found=$(find "$LOCAL_ROOT" -mindepth 1 -maxdepth 1 \
    ! -name "$CONFIG_FILE" \
    ! -name "$DEFAULT_PUSH_EXCLUDE_FILE" \
    ! -name "$DEFAULT_PULL_EXCLUDE_FILE" \
    -print -quit)
  [ -z "$found" ]
}

cmd_pull() {
  load_config
  require_pull_ignore
  local dry_run=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1 ;;
      *) usage; fail "unknown pull option: $1" ;;
    esac
    shift
  done

  if [ "$dry_run" -eq 0 ] && ! local_bootstrap_clean; then
    fail "local directory is not bootstrap-clean; only remote-dev config files may exist before pull"
  fi

  local -a args
  mapfile -d '' -t args < <(rsync_base_args)
  [ "$dry_run" -eq 1 ] && args+=(--dry-run)
  args+=(--exclude-from="$LOCAL_ROOT/$PULL_EXCLUDE_FILE")
  args+=("$REMOTE_HOST:${REMOTE_ROOT%/}/" "$LOCAL_ROOT/")
  "${args[@]}"
}

parse_path_transfer_args() {
  DRY_RUN=0
  DELETE_MODE=0
  REQUESTED_PATH=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --delete) DELETE_MODE=1 ;;
      --path)
        [ "$#" -ge 2 ] || fail "--path requires a value"
        REQUESTED_PATH=$2
        shift
        ;;
      *) usage; fail "unknown path transfer option: $1" ;;
    esac
    shift
  done
  [ -n "$REQUESTED_PATH" ] || fail "--path is required"
}

pull_relative_path() {
  local remote_rel=$1 local_rel=$2 dry_run=$3 delete_mode=$4 ignore_file=$5
  local -a args
  mapfile -d '' -t args < <(rsync_base_args)
  [ "$dry_run" -eq 1 ] && args+=(--dry-run)
  [ "$delete_mode" -eq 1 ] && args+=(--delete)
  [ -n "$ignore_file" ] && args+=(--exclude-from="$LOCAL_ROOT/$ignore_file")
  args+=("$REMOTE_HOST:${REMOTE_ROOT%/}/$remote_rel/" "$LOCAL_ROOT/$local_rel/")
  [ "$dry_run" -eq 1 ] || mkdir -p "$LOCAL_ROOT/$local_rel"
  "${args[@]}"
}

cmd_pull_path() {
  load_config
  require_pull_ignore
  parse_path_transfer_args "$@"
  local normalized
  if ! normalized=$(normalize_relative_path "$REQUESTED_PATH"); then
    fail "invalid pull path: $REQUESTED_PATH"
  fi
  [ -n "$REMOTE_PULL_PATHS" ] || fail "REMOTE_PULL_PATHS is empty"
  path_in_list "$normalized" "$REMOTE_PULL_PATHS" || fail "pull path is not allowlisted: $normalized"
  pull_relative_path "$normalized" "$normalized" "$DRY_RUN" "$DELETE_MODE" "$PULL_EXCLUDE_FILE"
}

cmd_init() {
  [ "$#" -ge 2 ] || { usage; fail "init requires <remote-host> <remote-root> [tmux-session]"; }
  [ "$#" -le 3 ] || { usage; fail "too many init arguments"; }
  write_project_config "$@"
  cmd_pull
}

cmd_push() {
  load_config
  require_push_ignore
  local dry_run=0 delete_mode=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1 ;;
      --delete|--no-delete)
        [ -z "$delete_mode" ] || fail "choose exactly one of --delete or --no-delete"
        delete_mode=$1
        ;;
      *) usage; fail "unknown push option: $1" ;;
    esac
    shift
  done
  [ -n "$delete_mode" ] || fail "choose exactly one of --delete or --no-delete"

  local -a args
  mapfile -d '' -t args < <(rsync_base_args)
  [ "$dry_run" -eq 1 ] && args+=(--dry-run)
  [ "$delete_mode" = '--delete' ] && args+=(--delete)
  build_pull_only_excludes ''
  args+=("${PULL_ONLY_EXCLUDES[@]}")
  args+=(--exclude-from="$LOCAL_ROOT/$PUSH_EXCLUDE_FILE")
  args+=("$LOCAL_ROOT/" "$REMOTE_HOST:${REMOTE_ROOT%/}/")
  "${args[@]}"
}

parse_push_path_args() {
  DRY_RUN=0
  DELETE_POLICY=''
  REQUESTED_PATH=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --delete|--no-delete)
        [ -z "$DELETE_POLICY" ] || fail "choose exactly one of --delete or --no-delete"
        DELETE_POLICY=$1
        ;;
      --path)
        [ "$#" -ge 2 ] || fail "--path requires a value"
        REQUESTED_PATH=$2
        shift
        ;;
      *) usage; fail "unknown push-path option: $1" ;;
    esac
    shift
  done
  [ -n "$REQUESTED_PATH" ] || fail "--path is required"
  [ -n "$DELETE_POLICY" ] || fail "choose exactly one of --delete or --no-delete"
}

cmd_push_path() {
  load_config
  require_push_ignore
  parse_push_path_args "$@"

  local normalized
  if ! normalized=$(normalize_relative_path "$REQUESTED_PATH"); then
    fail "invalid push path: $REQUESTED_PATH"
  fi
  [ -d "$LOCAL_ROOT/$normalized" ] || fail "push path must be an existing local directory: $normalized"

  local -a args
  mapfile -d '' -t args < <(rsync_base_args)
  [ "$DRY_RUN" -eq 1 ] && args+=(--dry-run)
  [ "$DELETE_POLICY" = '--delete' ] && args+=(--delete)
  build_pull_only_excludes "$normalized"
  args+=("${PULL_ONLY_EXCLUDES[@]}")
  args+=(--exclude-from="$LOCAL_ROOT/$PUSH_EXCLUDE_FILE")
  args+=("$LOCAL_ROOT/$normalized/" "$REMOTE_HOST:${REMOTE_ROOT%/}/$normalized/")
  "${args[@]}"
}

backup_path() {
  local path=$1 ts
  [ -e "$path" ] || return 0
  ts=$(date +%Y%m%d%H%M%S)
  cp -a "$path" "$path.backup.$ts"
}

check_remote_git_locks() {
  local metadata_path=$1
  ssh "$REMOTE_HOST" "find $(single_quote "$metadata_path") \\( -name '*.lock' -o -name 'index.lock' \\) -print -quit | grep -q . && exit 1 || exit 0" || \
    fail "remote git metadata has lock files: $metadata_path"
}

rsync_git_metadata_dir() {
  local remote_rel=$1 local_rel=$2 dry_run=$3
  local -a args
  mapfile -d '' -t args < <(rsync_base_args)
  [ "$dry_run" -eq 1 ] && args+=(--dry-run)
  args+=(--exclude=*.lock --exclude=index.lock --exclude=hooks/***)
  args+=("$REMOTE_HOST:${REMOTE_ROOT%/}/$remote_rel/" "$LOCAL_ROOT/$local_rel/")
  [ "$dry_run" -eq 1 ] || mkdir -p "$LOCAL_ROOT/$local_rel"
  "${args[@]}"
}

rsync_child_gitfiles() {
  local target=$1 dry_run=$2
  [ -n "$target" ] || return 0
  local -a args
  mapfile -d '' -t args < <(rsync_base_args)
  [ "$dry_run" -eq 1 ] && args+=(--dry-run)
  args+=(--include=*/ --include=*/.git --exclude=*)
  args+=("$REMOTE_HOST:${REMOTE_ROOT%/}/$target/" "$LOCAL_ROOT/$target/")
  "${args[@]}"
}

repair_core_worktrees() {
  local metadata_root=$1 cfg worktree suffix local_worktree
  [ -d "$metadata_root" ] || return 0
  while IFS= read -r -d '' cfg; do
    worktree=$(git config -f "$cfg" --get core.worktree 2>/dev/null || true)
    case "$worktree" in
      "$REMOTE_ROOT"/*)
        suffix=${worktree#"$REMOTE_ROOT"/}
        local_worktree="$LOCAL_ROOT/$suffix"
        git config -f "$cfg" core.worktree "$local_worktree"
        ;;
    esac
  done < <(find "$metadata_root" -type f -name config -print0)
}

validate_git_tree() {
  local target=$1 root child
  root="$LOCAL_ROOT${target:+/$target}"
  git -C "$root" status -sb
  git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || true
  git -C "$root" rev-parse --short HEAD 2>/dev/null || true
  [ -n "$target" ] || return 0
  while IFS= read -r -d '' child; do
    git -C "$(dirname "$child")" status -sb
  done < <(find "$root" -mindepth 2 -maxdepth 2 -type f -name .git -print0 2>/dev/null)
}

cmd_pull_git_metadata() {
  load_config
  local dry_run=0 root_git=0 target=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1 ;;
      --root-git) root_git=1 ;;
      --path)
        [ "$#" -ge 2 ] || fail "--path requires a value"
        target=$2
        shift
        ;;
      *) usage; fail "unknown pull-git-metadata option: $1" ;;
    esac
    shift
  done

  if [ "$root_git" -eq 1 ]; then
    [ -z "$target" ] || fail "use either --root-git or --path, not both"
    target=''
  else
    [ -n "$target" ] || fail "--path is required unless --root-git is used"
    if [ "$target" = '.' ]; then
      fail "project root git metadata requires --root-git"
    fi
    if ! target=$(normalize_relative_path "$target"); then
      fail "invalid git metadata path: $target"
    fi
    [ -n "$REMOTE_PULL_PATHS" ] || fail "REMOTE_PULL_PATHS is empty"
    path_in_list "$target/.git" "$REMOTE_PULL_PATHS" || fail "git metadata path is not allowlisted: $target/.git"
  fi

  local remote_meta local_meta
  remote_meta="${REMOTE_ROOT%/}${target:+/$target}/.git"
  local_meta="$LOCAL_ROOT${target:+/$target}/.git"
  check_remote_git_locks "$remote_meta"

  if [ "$dry_run" -eq 0 ]; then
    backup_path "$local_meta"
    if [ -n "$target" ]; then
      while IFS= read -r -d '' gitfile; do
        backup_path "$gitfile"
      done < <(find "$LOCAL_ROOT/$target" -mindepth 2 -maxdepth 2 -type f -name .git -print0 2>/dev/null)
    fi
  fi

  rsync_git_metadata_dir "${target:+$target/}.git" "${target:+$target/}.git" "$dry_run"
  rsync_child_gitfiles "$target" "$dry_run"

  if [ "$dry_run" -eq 0 ]; then
    repair_core_worktrees "$local_meta"
    validate_git_tree "$target"
  fi
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
    bind) cmd_bind "$@" ;;
    pull) cmd_pull "$@" ;;
    pull-path) cmd_pull_path "$@" ;;
    pull-git-metadata) cmd_pull_git_metadata "$@" ;;
    push|sync) cmd_push "$@" ;;
    push-path) cmd_push_path "$@" ;;
    run) cmd_run "$@" ;;
    log) cmd_log "$@" ;;
    -h|--help|help) usage ;;
    *) usage; fail "unknown subcommand: $subcommand" ;;
  esac
}

main "$@"
