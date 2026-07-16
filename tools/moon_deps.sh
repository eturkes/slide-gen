#!/bin/sh
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

set -eu

fail() {
  printf '%s\n' "moon deps: $*" >&2
  exit 1
}

version=0.20.0
checksum=be5ddf8a570e812ce9bdfd5199181c36bf25339cb05e5bdccf143761a19ea5cf
url=https://download.mooncakes.io/user/moonbitlang/async/0.20.0.zip

command -v moon >/dev/null 2>&1 || fail "moon is not on PATH"
command -v curl >/dev/null 2>&1 || fail "curl is not on PATH"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is not on PATH"
[ -n "${MOON_HOME:-${HOME:-}}" ] || fail "HOME and MOON_HOME are unset"
moon_home=${MOON_HOME:-$HOME/.moon}
index=$moon_home/registry/index/user/moonbitlang/async.index
cache_dir=$moon_home/registry/cache/moonbitlang/async
archive=$cache_dir/$version.zip
tmp=

cleanup() {
  if [ -n "$tmp" ]; then
    rm -f "$tmp"
  fi
}

trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Exactly one matching version and checksum must exist. This lets warm/offline
# gates reuse the registry while rejecting a duplicate or rewritten entry.
registry_entry_ok() {
  [ -f "$index" ] || return 1
  counts=$(awk -v version="\"version\": \"$version\"" \
    -v checksum="\"checksum\": \"$checksum\"" '
      index($0, version) { versions += 1; if (index($0, checksum)) exact += 1 }
      END { print versions + 0, exact + 0 }
    ' "$index") || return 1
  [ "$counts" = "1 1" ]
}

if ! registry_entry_ok; then
  moon update
fi
registry_entry_ok || fail "registry does not contain the pinned async@$version checksum"

mkdir -p "$cache_dir" || fail "cannot create MoonBit package cache"
if [ ! -f "$archive" ] ||
  ! printf '%s  %s\n' "$checksum" "$archive" | sha256sum -c - >/dev/null 2>&1; then
  tmp=$(mktemp "$cache_dir/.async-$version.XXXXXX") ||
    fail "cannot create package download"
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL \
    -o "$tmp" "$url"
  printf '%s  %s\n' "$checksum" "$tmp" | sha256sum -c - >/dev/null
  chmod 0644 "$tmp"
  mv -fT "$tmp" "$archive"
  tmp=
fi

printf '%s  %s\n' "$checksum" "$archive" | sha256sum -c -
