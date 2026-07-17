#!/bin/sh
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

set -eu

fail() {
  printf '%s\n' "slide-gen: install: $*" >&2
  exit 1
}

case $# in
  0)
    [ -n "${HOME:-}" ] || fail "HOME is unset; pass a destination bin directory"
    destination_input=$HOME/.local/bin
    ;;
  1) destination_input=$1 ;;
  *) fail "usage: tools/install.sh [BIN_DIR]" ;;
esac
[ -n "$destination_input" ] || fail "destination bin directory is empty"

script_dir=$(CDPATH='' cd -P "$(dirname "$0")" 2>/dev/null && pwd) ||
  fail "cannot resolve installer directory"
repo=$(CDPATH='' cd -P "$script_dir/.." 2>/dev/null && pwd) ||
  fail "cannot resolve checkout"
launcher=$repo/bin/slide-gen
stage=

cleanup() {
  if [ -n "$stage" ]; then
    rm -rf "$stage"
  fi
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ ! -f "$launcher" ] || [ ! -x "$launcher" ] || [ -L "$launcher" ]; then
  fail "tracked launcher is missing or unsafe: $launcher"
fi

# Resolve relative destinations against the caller before entering the checkout.
case $destination_input in
  /*) destination_path=$destination_input ;;
  *) destination_path=$(pwd -P)/$destination_input ;;
esac
mkdir -p "$destination_path" || fail "cannot create destination: $destination_path"
destination_dir=$(CDPATH='' cd -P "$destination_path" 2>/dev/null && pwd) ||
  fail "destination is not a directory: $destination_path"
destination=$destination_dir/slide-gen

check_destination() {
  if [ -L "$destination" ]; then
    current_target=$(readlink "$destination") ||
      fail "cannot inspect existing destination: $destination"
    [ "$current_target" = "$launcher" ] ||
      fail "refusing to replace foreign symlink: $destination -> $current_target"
  elif [ -e "$destination" ]; then
    fail "refusing to replace foreign destination: $destination"
  fi
}

# Fail before building when the public command is owned by anything else.
check_destination

install_root=$repo/.install
build_dir=$install_root/build
payload_dir=$install_root/bin
payload=$payload_dir/slide-gen
for owned_dir in "$install_root" "$build_dir" "$payload_dir"; do
  if [ -L "$owned_dir" ]; then
    fail "refusing symlinked install directory: $owned_dir"
  elif [ -e "$owned_dir" ] && [ ! -d "$owned_dir" ]; then
    fail "install path is not a directory: $owned_dir"
  fi
done
mkdir -p "$build_dir" "$payload_dir"
if [ -L "$payload" ]; then
  fail "refusing symlinked native payload: $payload"
elif [ -e "$payload" ] && [ ! -f "$payload" ]; then
  fail "native payload path is not a regular file: $payload"
fi
stage=$(mktemp -d "$install_root/.install-stage.XXXXXX") ||
  fail "cannot create native payload stage"
stage_bin=$stage/bin
candidate=$stage_bin/slide-gen
mkdir "$stage_bin"

command -v moon >/dev/null 2>&1 || fail "moon is not on PATH"
cd "$repo" || fail "cannot enter checkout: $repo"
moon install \
  --target-dir "$build_dir" \
  --bin "$stage_bin" \
  ./cmd/slide-gen

if [ ! -f "$candidate" ] || [ ! -x "$candidate" ] || [ -L "$candidate" ]; then
  fail "moon install did not produce a regular executable: $candidate"
fi

# Recheck after the build to close the ordinary check/build/link race. `ln -s`
# has no force flag, so a last-moment foreign arrival is still never clobbered.
check_destination
mv -fT "$candidate" "$payload" || fail "cannot publish native payload: $payload"
rm -rf "$stage"
stage=
if [ ! -f "$payload" ] || [ ! -x "$payload" ] || [ -L "$payload" ]; then
  fail "published native payload is not a regular executable: $payload"
fi
if [ ! -L "$destination" ]; then
  ln -s "$launcher" "$destination" ||
    fail "cannot create launcher symlink: $destination"
fi

printf '%s\n' "installed slide-gen: $destination -> $launcher"
