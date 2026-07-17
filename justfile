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
    uv run --locked --only-dev ruff format tools decks/*/figures.py

# Type-check MoonBit; lint + format-check every tracked Python authoring source.
check:
    moon check --target {{target}}
    uv run --locked --only-dev ruff check tools decks/*/figures.py
    uv run --locked --only-dev ruff format --check tools decks/*/figures.py
    shellcheck bin/slide-gen tools/*.sh

# Build the native binary.
build:
    moon build --target {{target}}

# Run MoonBit + Python suites; SLIDE_GEN_LIVE=1 opts into Codex.
test: build
    SLIDE_GEN_BIN="$(realpath "$(/usr/bin/find _build/{{target}} -name slide-gen.exe -path '*cmd/slide-gen*' -print -quit)")" moon test --target {{target}}
    uv run --locked --no-dev python -m unittest discover -s tools -p '*_test.py'

# Install the checkout-bound launcher; override SLIDE_GEN_INSTALL_BIN as needed.
install:
    tools/install.sh "${SLIDE_GEN_INSTALL_BIN:-${HOME}/.local/bin}"

# Exercise local moon install, launcher safety, cwd/argv/status/signal forwarding,
# idempotence, and payload independence from _build.
install-smoke:
    tools/install_smoke.sh

# Exercise the tracked-baseline wrapper against dirty and hidden-index states.
ci-smoke:
    tools/ci_smoke.sh

# Full gate sweep: format, check, build, tests, and shell acceptance smokes.
all: fmt check build test install-smoke ci-smoke

# Deterministic tracked-baseline gate: cold-cache capable, read-only, no live spend.
ci:
    tools/ci.sh just _ci-gates

[private]
_ci-gates:
    moon fmt --check
    uv sync --locked --all-groups
    uv run --locked --all-groups --no-sync ruff check tools decks/*/figures.py
    uv run --locked --all-groups --no-sync ruff format --check tools decks/*/figures.py
    shellcheck bin/slide-gen tools/*.sh
    tools/ci_smoke.sh
    tools/moon_deps.sh
    moon check --target {{target}} --deny-warn
    moon check --target {{target}} --frozen --deny-warn
    moon build --target {{target}} --frozen --deny-warn
    env -u SLIDE_GEN_LIVE -u SLIDE_GEN_LIVE_RUN_ROOT -u SLIDE_GEN_LIVE_RUN_PROJECT -u SLIDE_GEN_RENDER_CLI_LIVE -u SLIDE_GEN_RENDER_DOM_LIVE -u SLIDE_GEN_RENDER_RASTER_LIVE -u SLIDE_GEN_RENDER_PDF_LIVE SLIDE_GEN_BIN="$(pwd -P)/_build/{{target}}/debug/build/cmd/slide-gen/slide-gen.exe" moon test --target {{target}} --frozen --deny-warn
    uv run --locked --all-groups --no-sync python -m unittest discover -s tools -p '*_test.py'
    moon build --target {{target}} --release --frozen --deny-warn
    mkdir -p .install/ci-tmp
    TMPDIR="$(pwd -P)/.install/ci-tmp" tools/install_smoke.sh

# Probe DOM parity, repeatable rasters, and lossless PDF assembly on the live surface.
render-probe: build
    SLIDE_GEN_RENDER_DOM_LIVE=1 moon test --target {{target}} -f '*live Chromium DOM probe*'
    SLIDE_GEN_RENDER_RASTER_LIVE=1 moon test --target {{target}} -f '*live Chromium raster*'
    SLIDE_GEN_RENDER_PDF_LIVE=1 moon test --target {{target}} -f '*live rendered PDF*'

# Render both committed decks twice through the CLI and prove byte stability.
live-render: build
    SLIDE_GEN_BIN="$(realpath "$(/usr/bin/find _build/{{target}} -name slide-gen.exe -path '*cmd/slide-gen*' -print -quit)")" SLIDE_GEN_RENDER_CLI_LIVE=1 moon test --target {{target}} -f '*render CLI repeats both committed six-page decks byte identically*'

# Token-spending installed end-to-end proof in an isolated nested checkout.
live-run:
    tools/ci.sh tools/live_run.sh

# Run the CLI; pass program args after `--` (e.g. `just run -- --help`).
run *args:
    moon run cmd/slide-gen --target {{target}} {{args}}
