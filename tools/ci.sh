#!/bin/sh
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

set -eu

fail() {
  printf '%s\n' "ci: $*" >&2
  exit 1
}

[ "$#" -gt 0 ] || fail "usage: tools/ci.sh COMMAND [ARG ...]"

script_dir=$(CDPATH='' cd -P "$(dirname "$0")" 2>/dev/null && pwd) ||
  fail "cannot resolve script directory"
repo=$(CDPATH='' cd -P "$script_dir/.." 2>/dev/null && pwd) ||
  fail "cannot resolve checkout"
cd "$repo" || fail "cannot enter checkout"

command -v git >/dev/null 2>&1 || fail "git is not on PATH"
command -v setsid >/dev/null 2>&1 || fail "setsid is not on PATH"
[ "${GIT_DIR+x}" != x ] || fail "refusing ambient GIT_DIR"
[ "${GIT_WORK_TREE+x}" != x ] || fail "refusing ambient GIT_WORK_TREE"
[ "${GIT_INDEX_FILE+x}" != x ] || fail "refusing ambient GIT_INDEX_FILE"
[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] ||
  fail "checkout is not a Git worktree"
git_top_input=$(git rev-parse --show-toplevel 2>/dev/null) ||
  fail "cannot resolve Git worktree root"
git_top=$(CDPATH='' cd -P "$git_top_input" 2>/dev/null && pwd) ||
  fail "cannot canonicalize Git worktree root"
[ "$git_top" = "$repo" ] ||
  fail "script checkout is not the Git worktree root: $git_top"
if [ -L .install ]; then
  fail "refusing symlinked CI scratch root: $repo/.install"
elif [ -e .install ] && [ ! -d .install ]; then
  fail "CI scratch root is not a directory: $repo/.install"
fi
mkdir -p .install
scratch=$(mktemp -d "$repo/.install/ci-baseline.XXXXXX") ||
  fail "cannot create baseline scratch directory"
before=$scratch/before
after=$scratch/after
gate_pid=
signal_name=
signal_status=

trap 'rm -rf "$scratch"' 0

# ShellCheck cannot see calls embedded in the signal trap strings.
# shellcheck disable=SC2317,SC2329
forward_signal() {
  signal_name=$1
  signal_status=$2
  if [ -n "$gate_pid" ]; then
    kill -s "$signal_name" -- "-$gate_pid" 2>/dev/null || true
  fi
}

trap 'forward_signal HUP 129' HUP
trap 'forward_signal INT 130' INT
trap 'forward_signal TERM 143' TERM

# Preserve Git-observable tracked state, not merely a clean/dirty bit. HEAD plus
# staged entries and persistent index flags close index holes. Worktree content
# is diffed through a private index copy with every assume-unchanged and
# skip-worktree bit cleared; those flags otherwise hide later mutations from
# ordinary status/diff. The real index stays untouched. Untracked and ignored
# files are outside the promised baseline and may be populated.
snapshot() {
  destination=$1
  mkdir "$destination" || return 1
  git rev-parse --verify HEAD >"$destination/head" || return 1
  git symbolic-ref -q HEAD >"$destination/head-name" || {
    symbolic_status=$?
    [ "$symbolic_status" -eq 1 ] || return 1
    printf '%s\n' '(detached)' >"$destination/head-name" || return 1
  }
  git ls-files --stage -z >"$destination/index" || return 1
  git ls-files -v -z >"$destination/index-flags" || return 1
  git ls-files -f -z >"$destination/fsmonitor-flags" || return 1
  git status --porcelain=v1 -z --untracked-files=no >"$destination/status" ||
    return 1
  index_input=$(git rev-parse --git-path index) || return 1
  case $index_input in
    /*) ;;
    *) index_input=$repo/$index_input ;;
  esac
  private_index=$destination/private-index
  tracked_paths=$destination/tracked-paths
  cp "$index_input" "$private_index" || return 1
  git ls-files -z >"$tracked_paths" || return 1
  GIT_INDEX_FILE=$private_index git update-index \
    --no-assume-unchanged -z --stdin <"$tracked_paths" || return 1
  GIT_INDEX_FILE=$private_index git update-index \
    --no-skip-worktree -z --stdin <"$tracked_paths" || return 1
  GIT_INDEX_FILE=$private_index git update-index \
    -q --unmerged --really-refresh || return 1
  GIT_INDEX_FILE=$private_index git diff \
    --binary \
    --full-index \
    --no-ext-diff \
    --no-textconv \
    --no-renames \
    --ignore-submodules=none \
    -- >"$destination/worktree" || return 1
  rm -f "$private_index" "$tracked_paths" || return 1
}

snapshot "$before" || fail "could not capture the initial tracked baseline"

set +e
setsid "$@" &
gate_pid=$!
if [ -n "$signal_name" ]; then
  kill -s "$signal_name" -- "-$gate_pid" 2>/dev/null || true
fi
wait "$gate_pid"
gate_status=$?
set -e

if [ -n "$signal_status" ]; then
  while kill -0 "$gate_pid" 2>/dev/null; do
    set +e
    wait "$gate_pid"
    set -e
  done
  gate_status=$signal_status
fi
gate_pid=

if ! snapshot "$after"; then
  fail "could not capture the final tracked baseline"
fi
baseline_changed=false
for component in head head-name index index-flags fsmonitor-flags status worktree; do
  if ! cmp -s "$before/$component" "$after/$component"; then
    baseline_changed=true
  fi
done
if [ "$baseline_changed" = true ]; then
  printf '%s\n' \
    "ci: tracked HEAD/index/worktree changed during the gate; files were left untouched for inspection" >&2
  git status --short --untracked-files=no >&2 || true
  exit 1
fi

if [ -n "$signal_status" ]; then
  gate_status=$signal_status
fi
if [ "$gate_status" -eq 0 ]; then
  printf '%s\n' "ci: tracked baseline preserved"
fi
exit "$gate_status"
