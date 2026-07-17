#!/bin/sh
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

set -eu

fail() {
  printf '%s\n' "ci smoke: $*" >&2
  exit 1
}

script_dir=$(CDPATH='' cd -P "$(dirname "$0")" 2>/dev/null && pwd) ||
  fail "cannot resolve smoke-test directory"
repo=$(CDPATH='' cd -P "$script_dir/.." 2>/dev/null && pwd) ||
  fail "cannot resolve checkout"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/slide-gen-ci-smoke.XXXXXX") ||
  fail "cannot create scratch directory"
fixture=$tmp/repo

cleanup() {
  rm -rf "$tmp"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$fixture/tools"
cp "$repo/tools/ci.sh" "$fixture/tools/ci.sh"
printf '%s\n' base >"$fixture/visible"
printf '%s\n' base >"$fixture/assumed"
printf '%s\n' base >"$fixture/skipped"
git -C "$fixture" init -q
git -C "$fixture" add tools/ci.sh visible assumed skipped
git -C "$fixture" \
  -c user.name='slide-gen CI smoke' \
  -c user.email='slide-gen@example.invalid' \
  -c commit.gpgsign=false \
  -c core.hooksPath=/dev/null \
  commit -qm fixture

# A pre-existing ordinary worktree change is a valid baseline and stays intact.
printf '%s\n' dirty >>"$fixture/visible"
(cd "$fixture" && tools/ci.sh sh -c ':') >"$tmp/noop.out" 2>"$tmp/noop.err" ||
  fail "unchanged dirty baseline was rejected"
grep -F 'ci: tracked baseline preserved' "$tmp/noop.out" >/dev/null ||
  fail "successful wrapper omitted its preservation result"
[ ! -s "$tmp/noop.err" ] || fail "successful wrapper wrote unexpected stderr"

expect_hidden_change() {
  flag=$1
  clear_flag=$2
  path=$3
  git -C "$fixture" update-index "$flag" "$path"
  set +e
  (
    cd "$fixture"
    # Expansion belongs to the injected child shell.
    # shellcheck disable=SC2016
    tools/ci.sh sh -c 'printf "%s\n" changed >>"$1"' sh "$path"
  ) >"$tmp/$path.out" 2>"$tmp/$path.err"
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail "$flag mutation escaped with status $status"
  grep -F 'tracked HEAD/index/worktree changed during the gate' \
    "$tmp/$path.err" >/dev/null ||
    fail "$flag mutation omitted the baseline diagnostic"
  flagged=$(git -C "$fixture" ls-files -v "$path")
  case $flag:$flagged in
    --assume-unchanged:"h $path" | --skip-worktree:"S $path") ;;
    *) fail "$flag was not preserved in the real index: $flagged" ;;
  esac
  git -C "$fixture" update-index "$clear_flag" "$path"
}

expect_hidden_change --assume-unchanged --no-assume-unchanged assumed
expect_hidden_change --skip-worktree --no-skip-worktree skipped

# Switching symbolic HEAD to a detached HEAD at the same commit changes no OID,
# index entry, or worktree byte; the explicit HEAD-name fingerprint still sees it.
set +e
(
  cd "$fixture"
  # Expansion belongs to the injected child shell.
  # shellcheck disable=SC2016
  tools/ci.sh sh -c \
    'git update-ref --no-deref HEAD "$(git rev-parse --verify HEAD)"'
) >"$tmp/head.out" 2>"$tmp/head.err"
head_status=$?
set -e
[ "$head_status" -eq 1 ] || fail "symbolic HEAD change escaped with status $head_status"
grep -F 'tracked HEAD/index/worktree changed during the gate' \
  "$tmp/head.err" >/dev/null ||
  fail "symbolic HEAD change omitted the baseline diagnostic"

printf '%s\n' 'ci smoke: ok'
