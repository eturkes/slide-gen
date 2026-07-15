# slide-gen quality gates — MoonBit native backend.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
# Recipes prepend ~/.moon/bin so non-interactive shells find the toolchain.

export PATH := env_var('HOME') / '.moon' / 'bin' + ':' + env_var('PATH')

target := 'native'

# List recipes.
default:
    @just --list

# Format MoonBit + authoring-time Python sources in place.
fmt:
    moon fmt
    uv run --locked --only-dev ruff format tools

# Type-check MoonBit; lint + format-check the Python sidecar.
check:
    moon check --target {{target}}
    uv run --locked --only-dev ruff check tools
    uv run --locked --only-dev ruff format --check tools

# Build the native binary.
build:
    moon build --target {{target}}

# Run MoonBit + Python suites; SLIDE_GEN_LIVE=1 opts into Codex.
test: build
    SLIDE_GEN_BIN="$(realpath "$(find _build/{{target}} -name main.exe -path '*cmd/main*' -print -quit)")" moon test --target {{target}}
    uv run --locked --no-dev python -m unittest discover -s tools -p '*_test.py'

# Full gate sweep: format, check, build, test.
all: fmt check build test

# Run the CLI; pass program args after `--` (e.g. `just run -- --help`).
run *args:
    moon run cmd/main --target {{target}} {{args}}
