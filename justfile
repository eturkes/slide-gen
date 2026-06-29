# slide-gen quality gates — MoonBit native backend.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
# Recipes prepend ~/.moon/bin so non-interactive shells find the toolchain.

export PATH := env_var('HOME') / '.moon' / 'bin' + ':' + env_var('PATH')

target := 'native'

# List recipes.
default:
    @just --list

# Format all MoonBit sources in place.
fmt:
    moon fmt

# Type-check without codegen.
check:
    moon check --target {{target}}

# Build the native binary.
build:
    moon build --target {{target}}

# Run the test suite; e2e tests exec the built binary via SLIDE_GEN_BIN.
test: build
    SLIDE_GEN_BIN="$(realpath "$(find _build/{{target}} -name main.exe -path '*cmd/main*' -print -quit)")" moon test --target {{target}}

# Full gate sweep: format, check, build, test.
all: fmt check build test

# Run the CLI; pass program args after `--` (e.g. `just run -- --help`).
run *args:
    moon run cmd/main --target {{target}} {{args}}
