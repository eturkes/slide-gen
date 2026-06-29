# Memory — slide-gen

Cross-session context + learned facts (agent-agnostic; read by Claude + Codex). Record only what git log / roadmap don't already hold.

## Project
- License `Apache-2.0 WITH LLVM-exception`. Per-source header when `.mbt`/scripts land: `SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception`.
- Stack + M1 plan + decision rationale live in `roadmap.md` — don't restate here.

## Prototype reference — `~/Projects/spine-segmentation/docs/slides/` (proven end-to-end; M2/M3 mirror it)
- `render.py`: runs figures.py → ONE tall chromiumfish screenshot → PIL slices into pages → PDF@72dpi (page pt == px). Section count MUST come from deck DOM (`querySelectorAll`), NOT source regex — the template header comment contains a literal `<section…>` → regex over-counts.
- `deck.html`: hand-authored content in the template CSS (`<ruby>` furigana, three-tier JA/furigana/EN). → M2's value-add = automate that authoring via `codex exec`.
- `figures.py`: matplotlib figures from COMMITTED numbers; reads no `data/`, no PHI. `figure_example.py`: reads the Read-denied `data/` tree → a HUMAN runs it once, the PNG is committed (raw-data figures can't be agent-generated under deny rules).
- Assets may carry non-Apache licenses (e.g. CC BY-SA from source datasets) → per-asset caption attribution. Render intermediates (`page_*.png`, `_deck_full.png`) gitignored.
- Provenance: every number traces to project run-notes → M2 should cite sources + emit a gaps list (low-hallucination).

## MoonBit reference (native; pre-1.0 → pin toolchain + deps)
- Install: `curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash` → `~/.moon/bin` (moon, moonc, moonfmt…). moonup = version pin. Native needs `build-essential` (cc) + x86_64.
- Core built-ins (no dep): `@argparse` (clap-like subcommands), `@quickcheck` (Arbitrary/samples property tests; no fuzzer), `@json` (derive ToJson/FromJson), `@env.args()`. No TOML lib → newline state file.
- Subprocess + fs are async-only (`moonbitlang/async`): `@process.collect_output_merged → (Int, &@io.Data)`; `@fs.{read_file, write_file(CreateOrTruncate), readdir, kind(.,follow_symlink=false)→FileKind}`. `&@io.Data` is NOT a String → call `.text()`/`.binary()`.
- Gotchas: `"is-main"` (hyphen, not `is_main`); native binary at `target/native/<mode>/build/main/…exe` (dir migrating →`_build/` → prefer `moon run`, don't hardcode); `moonrun` runs wasm/js only, never native ELFs; async + `@argparse` APIs churn → use `inspect` snapshots to catch drift on upgrade; `x/fs.is_dir` follows symlinks + lacks lstat → use async `@fs.kind`. Serena has no MoonBit LSP → grep + `moon check`/`mooninfo` for nav.

## Env (verified)
- codex headless: model per `~/.codex/config.toml` (gpt-5.5, xhigh). Invoke = stdin-from-file (backtick-safe); `-o` captures the final MESSAGE only, not artifacts → M2 must have codex WRITE the deck to a path, then read it back.
- chromiumfish (headless Chromium via playwright-core) + Noto Sans CJK JP both present → render stack ready for M3. `img2pdf` installed via `uv tool` this session (alternative to PIL for the PDF step).
