#!/bin/sh
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

set -eu

fail() {
  printf '%s\n' "install smoke: $*" >&2
  exit 1
}

script_dir=$(CDPATH='' cd -P "$(dirname "$0")" 2>/dev/null && pwd) ||
  fail "cannot resolve smoke-test directory"
repo=$(CDPATH='' cd -P "$script_dir/.." 2>/dev/null && pwd) ||
  fail "cannot resolve checkout"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/slide-gen-install.XXXXXX") ||
  fail "cannot create scratch directory"
payload=$repo/.install/bin/slide-gen
native_backup=$repo/.install/bin/slide-gen.native-smoke
child=

cleanup() {
  set +e
  if [ -n "$child" ]; then
    kill -KILL "$child" 2>/dev/null
    wait "$child" 2>/dev/null
  fi
  if [ -e "$native_backup" ]; then
    rm -f "$payload"
    mv "$native_backup" "$payload"
  fi
  rm -rf "$tmp"
}
trap cleanup 0 HUP INT TERM

# A foreign public destination must fail before clobbering even one byte.
foreign_bin=$tmp/foreign-bin
mkdir -p "$foreign_bin"
printf '%s\n' "foreign destination" >"$foreign_bin/slide-gen"
if (
  cd "$repo"
  SLIDE_GEN_INSTALL_BIN=$foreign_bin just install
) >"$tmp/foreign.out" 2>"$tmp/foreign.err"; then
  fail "foreign destination was accepted"
fi
[ "$(sed -n '1p' "$foreign_bin/slide-gen")" = "foreign destination" ] ||
  fail "foreign destination changed"

# Real local install + an idempotent rerun create exactly the checkout launcher
# symlink and a repo-local native payload named slide-gen.
public_bin=$tmp/public-bin
outside=$tmp/outside
mkdir -p "$outside"
(
  cd "$repo"
  SLIDE_GEN_INSTALL_BIN=$public_bin just install
  SLIDE_GEN_INSTALL_BIN=$public_bin just install
)
installed=$public_bin/slide-gen
[ -L "$installed" ] || fail "public command is not a symlink"
[ "$(readlink "$installed")" = "$repo/bin/slide-gen" ] ||
  fail "public symlink does not target this checkout"
if [ ! -f "$payload" ] || [ ! -x "$payload" ] || [ -L "$payload" ]; then
  fail "native payload is missing or unsafe"
fi

version=$(cd "$outside" && "$installed" --version) ||
  fail "installed --version failed outside the checkout"
[ "$version" = "0.1.0" ] ||
  fail "unexpected installed version: $version"
(cd "$outside" && "$installed" list >/dev/null) ||
  fail "installed command did not find its checkout"

# The installed copy is independent of MoonBit's ordinary build tree.
(cd "$repo" && moon clean)
[ ! -e "$repo/_build" ] || fail "moon clean left _build behind"
(cd "$outside" && "$installed" list >/dev/null) ||
  fail "installed command depends on _build"

# Replace only the ignored payload with /bin/sh to test the launcher's exec
# boundary precisely: cwd, tricky argv, child status, and TERM all flow through.
mv "$payload" "$native_backup"
cp /bin/sh "$payload"
# Expansion belongs to the injected child shell, not this smoke process.
# shellcheck disable=SC2016
probe_script='printf "%s|%s|<%s>|<%s>|<%s>\n" "$PWD" "$#" "$1" "$2" "$3"; exit "$4"'
set +e
probe=$(
  cd "$outside" &&
    "$installed" -c "$probe_script" marker "a b" "*" "" 37
)
probe_status=$?
set -e
[ "$probe_status" -eq 37 ] || fail "child status was not forwarded: $probe_status"
[ "$probe" = "$repo|4|<a b>|<*>|<>" ] ||
  fail "cwd/argv were not forwarded exactly: $probe"

ready=$tmp/signal-ready
# Expansion belongs to the injected child shell.
# shellcheck disable=SC2016
signal_script='trap "exit 73" TERM; : >"$1"; while :; do sleep 1; done'
(
  cd "$outside" || exit 99
  exec "$installed" -c "$signal_script" marker "$ready"
) &
child=$!
attempt=0
while [ ! -f "$ready" ]; do
  kill -0 "$child" 2>/dev/null || fail "signal probe exited before readiness"
  attempt=$((attempt + 1))
  [ "$attempt" -lt 100 ] || fail "signal probe readiness timed out"
  sleep 0.05
done
kill -TERM "$child"
set +e
wait "$child"
signal_status=$?
set -e
child=
[ "$signal_status" -eq 73 ] ||
  fail "TERM did not reach the exec'd child exactly: $signal_status"

rm -f "$payload"
mv "$native_backup" "$payload"
version=$(cd "$outside" && "$installed" --version) ||
  fail "restored native payload failed"
[ "$version" = "0.1.0" ] || fail "restored version changed"

printf '%s\n' "install smoke: ok"
