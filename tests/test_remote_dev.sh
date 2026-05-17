#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
REMOTE_DEV="$SCRIPT_DIR/scripts/remote-dev.sh"

fail() {
  printf 'test_remote_dev: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

assert_contains() {
  local file=$1 pattern=$2
  grep -Fq -- "$pattern" "$file" || fail "missing pattern '$pattern' in $file"
}

assert_not_contains() {
  local file=$1 pattern=$2
  ! grep -Fq -- "$pattern" "$file" || fail "unexpected pattern '$pattern' in $file"
}

make_fake_bin() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/rsync" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${RSYNC_LOG:?RSYNC_LOG is required}"
EOF
  chmod +x "$dir/rsync"
}

new_project() {
  local root
  root=$(mktemp -d)
  mkdir -p "$root/src" "$root/results"
  (cd "$root" && "$REMOTE_DEV" bind example-host /home/example/project >/dev/null)
  printf '%s' "$root"
}

test_bind_writes_directional_ignores() {
  local root
  root=$(mktemp -d)
  (cd "$root" && "$REMOTE_DEV" bind example-host /home/example/project >/dev/null)

  assert_file "$root/.remote-dev.env"
  assert_file "$root/.remote-dev.pushignore"
  assert_file "$root/.remote-dev.pullignore"
  assert_contains "$root/.remote-dev.env" "PUSH_EXCLUDE_FILE=.remote-dev.pushignore"
  assert_contains "$root/.remote-dev.env" "PULL_EXCLUDE_FILE=.remote-dev.pullignore"
  assert_contains "$root/.remote-dev.env" "REMOTE_PULL_PATHS="
  assert_not_contains "$root/.remote-dev.env" "REMOTE_ARTIFACT_PATHS"
}

test_pull_path_uses_allowlist_and_pull_ignore() {
  local root fakebin
  root=$(new_project)
  fakebin="$root/fakebin"
  make_fake_bin "$fakebin"
  printf '\nREMOTE_PULL_PATHS=results\n' >> "$root/.remote-dev.env"

  env RSYNC_LOG="$root/rsync.log" PATH="$fakebin:$PATH" \
    bash -c 'cd "$1" && "$2" pull-path --dry-run --path results' _ "$root" "$REMOTE_DEV"

  assert_contains "$root/rsync.log" "--exclude-from=$root/.remote-dev.pullignore"
  assert_contains "$root/rsync.log" "--no-owner"
  assert_contains "$root/rsync.log" "--no-group"
  assert_contains "$root/rsync.log" "example-host:/home/example/project/results/"
  assert_contains "$root/rsync.log" "$root/results/"
}

test_push_path_uses_push_ignore_and_delete_policy() {
  local root fakebin
  root=$(new_project)
  fakebin="$root/fakebin"
  make_fake_bin "$fakebin"

  env RSYNC_LOG="$root/rsync.log" PATH="$fakebin:$PATH" \
    bash -c 'cd "$1" && "$2" push-path --dry-run --no-delete --path src' _ "$root" "$REMOTE_DEV"

  assert_contains "$root/rsync.log" "--exclude-from=$root/.remote-dev.pushignore"
  assert_contains "$root/rsync.log" "$root/src/"
  assert_contains "$root/rsync.log" "example-host:/home/example/project/src/"
  if grep -Fxq -- "--delete" "$root/rsync.log"; then
    fail "push-path --no-delete unexpectedly passed --delete"
  fi
}

test_push_excludes_pull_only_paths() {
  local root fakebin
  root=$(new_project)
  fakebin="$root/fakebin"
  make_fake_bin "$fakebin"
  printf '\nREMOTE_PULL_PATHS=results,examples/run/results\n' >> "$root/.remote-dev.env"

  env RSYNC_LOG="$root/rsync.log" PATH="$fakebin:$PATH" \
    bash -c 'cd "$1" && "$2" push --dry-run --no-delete' _ "$root" "$REMOTE_DEV"

  assert_contains "$root/rsync.log" "--exclude=results/"
  assert_contains "$root/rsync.log" "--exclude=examples/run/results/"
  assert_not_contains "$root/rsync.log" "--exclude=remote_artifacts/"
}

test_push_path_blocks_or_excludes_pull_only_paths() {
  local root fakebin
  root=$(new_project)
  fakebin="$root/fakebin"
  make_fake_bin "$fakebin"
  mkdir -p "$root/examples/run/results"
  printf '\nREMOTE_PULL_PATHS=results,examples/run/results\n' >> "$root/.remote-dev.env"

  if env RSYNC_LOG="$root/blocked.log" PATH="$fakebin:$PATH" \
    bash -c 'cd "$1" && "$2" push-path --dry-run --no-delete --path results' _ "$root" "$REMOTE_DEV" 2>"$root/err.log"; then
    fail "push-path accepted a pull-only path"
  fi
  assert_contains "$root/err.log" "push path is pull-only: results"

  env RSYNC_LOG="$root/rsync.log" PATH="$fakebin:$PATH" \
    bash -c 'cd "$1" && "$2" push-path --dry-run --no-delete --path examples/run' _ "$root" "$REMOTE_DEV"

  assert_contains "$root/rsync.log" "--exclude=results/"
}

test_pull_path_rejects_unallowlisted_path() {
  local root fakebin
  root=$(new_project)
  fakebin="$root/fakebin"
  make_fake_bin "$fakebin"
  printf '\nREMOTE_PULL_PATHS=results\n' >> "$root/.remote-dev.env"

  if env RSYNC_LOG="$root/rsync.log" PATH="$fakebin:$PATH" \
    bash -c 'cd "$1" && "$2" pull-path --dry-run --path src' _ "$root" "$REMOTE_DEV" 2>"$root/err.log"; then
    fail "pull-path accepted an unallowlisted path"
  fi
  assert_contains "$root/err.log" "pull path is not allowlisted: src"
}

test_fetch_artifacts_is_removed() {
  local root
  root=$(new_project)
  if (cd "$root" && "$REMOTE_DEV" fetch-artifacts --dry-run) 2>"$root/err.log"; then
    fail "fetch-artifacts was accepted"
  fi
  assert_contains "$root/err.log" "unknown subcommand: fetch-artifacts"
}


test_config_does_not_execute_shell_code() {
  local root marker
  root=$(mktemp -d)
  marker="$root/pwned"
  cat > "$root/.remote-dev.env" <<EOF
LOCAL_ROOT=$root
REMOTE_HOST=example-host
REMOTE_ROOT=/home/example/project
PUSH_EXCLUDE_FILE=.remote-dev.pushignore
PULL_EXCLUDE_FILE=.remote-dev.pullignore
REMOTE_PULL_PATHS=results
MALICIOUS=\$(touch "$marker")
EOF
  : > "$root/.remote-dev.pullignore"

  if (cd "$root" && "$REMOTE_DEV" pull-path --dry-run --path results) >/dev/null 2>"$root/err.log"; then
    fail "config with unknown executable line was accepted"
  fi
  [ ! -e "$marker" ] || fail "config executed shell code"
  assert_contains "$root/err.log" "unknown config key: MALICIOUS"
}

test_remote_tokens_reject_shell_metacharacters() {
  local root
  root=$(mktemp -d)
  if (cd "$root" && "$REMOTE_DEV" bind 'host;touch-pwned' /home/example/project) 2>"$root/err.log"; then
    fail "bind accepted unsafe remote host"
  fi
  assert_contains "$root/err.log" "REMOTE_HOST contains unsafe characters"

  if (cd "$root" && "$REMOTE_DEV" bind example-host /home/example/project 'dev;touch-pwned') 2>"$root/err2.log"; then
    fail "bind accepted unsafe tmux session"
  fi
  assert_contains "$root/err2.log" "REMOTE_TMUX contains unsafe characters"
}

test_bind_writes_directional_ignores
test_pull_path_uses_allowlist_and_pull_ignore
test_push_path_uses_push_ignore_and_delete_policy
test_push_excludes_pull_only_paths
test_push_path_blocks_or_excludes_pull_only_paths
test_pull_path_rejects_unallowlisted_path
test_fetch_artifacts_is_removed
test_config_does_not_execute_shell_code
test_remote_tokens_reject_shell_metacharacters

printf 'ok remote-dev tests\n'
