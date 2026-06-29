# slide-gen — roadmap

Goal: a CLI + home for slides across `~/Projects/*`. Discover sibling projects → toggle on/off → `codex exec` generates a `deck.html`-style deck per enabled project → render to PDF. The repo is the deck home: `templates/deck.html` = style contract; `decks/<project>/` = generated output (later milestones).

Stack: **MoonBit (native backend)** — the agent-oriented bet (AGENTS.md ethos). UX = flag subcommands (no TUI). State = gitignored local. Discovery = all sibling dirs, default-off. (Decisions confirmed by owner this planning session.)

Seed: commit `0526d53` (repo init: deck.html, AGENTS/CLAUDE, `.agent` boilerplate) + this session's `templates/deck.html` move. `deck.html` is the content-stripped generalization of the **proven prototype** `~/Projects/spine-segmentation/docs/slides/` (filled deck.html + figures.py + render.py → PDF) — M2/M3 mirror it (mechanics in `memory.md`).

## Legend
- status ∈ {UNPLANNED, IN-PROGRESS (units enumerated), IMPLEMENTED (units DONE, unreviewed), REVIEWED}.
- unit status ∈ {OPEN, DONE}; `ctx:` = context-usage recorded at unit close (WORK-UNIT only).
- commit trace keys: unit `(M<m>.<u>)`, plan `(M<m> plan)`, review `(M<m> review)`. History: `git log --grep "(M1[. ]"`.

## Milestone ledger
- **M1 CLI foundation** — discovery + toggle state (no codex, no render). STATUS: **IN-PROGRESS**.
- **M2 Generation** — `codex exec` per enabled project → template-styled `deck.html` (+ figures, provenance/gaps, furigana policy). STATUS: UNPLANNED.
- **M3 Rendering** — `deck.html` → per-page PNG → PDF@72dpi; mirror prototype `render.py` (chromiumfish + raster, section count from DOM). STATUS: UNPLANNED.
- **M4 Integration / packaging / docs** — end-to-end `run`, batch over enabled set, distribution, README, quality gates. STATUS: UNPLANNED.

Plan each milestone in its own session when it becomes active (M2–M4 deferred per owner). Open cross-milestone decisions parked for their planning session: deck output path policy, codex sandbox posture (bypass vs workspace-write), furigana auto-gen vs JA+EN-only, render DSF/DPI + raster-vs-vector, codex-trust for the 20 non-trusted README projects.

---

## M1 — CLI foundation (active)

Scope: a buildable MoonBit-native CLI that discovers sibling projects under `~/Projects/` and persists an enable/disable toggle via flag subcommands. No external gates (toolchain is installable) → no BLOCKED units; deps are linear M1.1→M1.2→M1.3.

Locked design:
- **Async-from-start**: `async fn main` (native). `@fs.kind` (lstat) + later `@process` are async-only → commit now, no retrofit.
- **Deps** (pin all; async is experimental/churning): `moonbitlang/async@0.20.0` (`@fs` + `@process`); core built-ins `@argparse` (subcommands), `@quickcheck` (property tests), `@json` (state upgrade path), `@env` (argv). Pin toolchain via moonup.
- **Discovery**: parent of the slide-gen repo = `~/Projects/`; `@fs.readdir` + `@fs.kind(name, follow_symlink=false)`; candidate = `Directory` or symlink→`Directory`; exclude `slide-gen`; no recursion. Verified target set: 33 dirs + 5 symlinks = 38 entries (28 git).
- **UX**: subcommands `list | enable <name> | disable <name> | toggle <name> | status` via `@argparse`; reject `<name>` ∉ candidates.
- **State**: `Set[String]` of enabled names → newline-delimited, sorted, atomic write (temp+rename); gitignored repo-root `enabled.txt`; default-off. (`@json` struct is the upgrade path if state gains structure.)
- **Gates**: `moon fmt` · `moon check` · `moon build --target native` · `moon test`; driver = `justfile` (just present).
- **Env prereqs**: official installer (`cli.moonbitlang.com/install/unix.sh`) → `~/.moon/bin`; `apt install build-essential` (cc); native = x86_64 (verify box; ARM → wasm).
- **Binary**: `target/native/<mode>/build/main/…exe` (real ELF; dir may migrate `target/`→`_build/`) → don't hardcode, prefer `moon run`.

Units (≤200K window each):
- **M1.1 Toolchain + scaffold** [OPEN] — install+pin MoonBit + build-essential; `moon new` module `slide-gen` (`moon.mod.json` preferred-target=native; `src/main` `is-main` (hyphen), bin-name=slide-gen, `async fn main`); `moon add moonbitlang/async@0.20.0`; wire `justfile` gates (fmt/check/build/test); seed `.gitignore` (build dir + `enabled.txt` + future `decks/`); record that Serena lacks a MoonBit LSP → nav via grep/moon. **Accept**: fmt/check clean; `moon build --target native` yields the binary; `slide-gen --help` renders (argparse); `moon test` passes. ctx:
- **M1.2 Discovery** [OPEN] — sibling-enumeration module (readdir + kind, symlink-aware, no recurse, exclude self; parent = repo-parent). **Tests**: tempdir fixtures (real dirs / symlinked-dir / plain file / nested subdir) → assert exact candidate set. **Accept**: correct set on fixtures; `list` shows all (default-off). ctx:
- **M1.3 Toggle state + subcommands** [OPEN] — `Set[String]` model; newline file read (split/trim/drop-empty) + write (sorted, atomic); `list/enable/disable/toggle/status`; validate name ∈ candidates; persist across runs. **Tests**: `@quickcheck` roundtrip serialize→parse→eq with a **constrained** name generator (valid dir-name chars, no `/`/`\n` — unconstrained `String` breaks the newline format, a real finding); blackbox enable/disable/toggle/unknown-name/persist-across-invocations; `inspect` goldens on serialize + `list` output. **Accept**: state persists; subcommands mutate correctly; unknown rejected; property + blackbox + gates pass. ctx:

Close: all units DONE → M1 IMPLEMENTED → next session MILESTONE-REVIEW (1M context).

## M1 risks / watch
- `async@0.20.0` experimental → API churn (`write_file`/`kind` carry deprecations) → pin + lean on `inspect` snapshots to catch drift on upgrade.
- Native needs cc (build-essential) + x86_64; verify the box (ARM → wasm fallback).
- Config-format migration in flight (`moon.pkg.json`→DSL; `target/`→`_build/`) → prefer `moon run`, don't hardcode paths.
- `x/fs.is_dir` follows symlinks + has no lstat → use async `@fs.kind(.,follow_symlink=false)`, not `x/fs`.
- Serena has no MoonBit LSP → symbol nav via grep + `moon check`/`mooninfo`.
