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
- **Deps** (pin all; async is experimental/churning): `moonbitlang/async@0.20.0` (`@fs` + `@process`); core built-ins `@argparse` (subcommands), `@quickcheck` (sample-gen tests), `@json` (state upgrade path), `@env` (argv). Pin toolchain via the installer version arg / `MOONBIT_INSTALL_VERSION` + record `moon version` (moonup unverified/not-installed → verify first).
- **Discovery**: parent of the slide-gen repo = `~/Projects/`; `@fs.readdir` (bare names) → stat each via `@fs.kind(parent/name, follow_symlink=false)` (FULL path — `kind` resolves a bare name against cwd, not the scanned parent); candidate = `Directory`, or symlink→`Directory` (2nd `kind(parent/name)` following the link); exclude `slide-gen`; skip dotfile dirs + broken symlinks; no recursion. Verified set (post self-exclude): 33 dirs + 5 symlinks = 38 (28 git); raw `~/Projects/` = 34 dirs + 5 symlinks = 39.
- **UX**: subcommands `list | enable <name> | disable <name> | toggle <name> | status` via `@argparse`; reject `<name>` ∉ candidates.
- **State**: `Set[String]` of enabled names → newline-delimited, sorted; atomic write = unique temp in the SAME dir → `rename` over `enabled.txt` (last-writer-wins; single-user → no lock; fsync if the async API exposes it); missing file = empty set; gitignored repo-root `enabled.txt`; default-off. (`@json` struct is the upgrade path if state gains structure.)
- **Gates**: `moon fmt` · `moon check` · `moon build --target native` · `moon test`; driver = `justfile` (just present).
- **Env prereqs**: official installer (`cli.moonbitlang.com/install/unix.sh`) → `~/.moon/bin`; `apt install build-essential` (cc); native supports x86_64 + aarch64 (box verified x86_64) → no wasm fallback (async `@fs`/`@process` are native-only).
- **Binary**: a real native ELF under the build tree (`target/` or `_build/` — exact path unverified across moon versions) → locate empirically after `moon build --target native`; prefer `moon run`, never hardcode.

Units (≤200K window each):
- **M1.1 Toolchain + scaffold** [OPEN] — install MoonBit (installer, pinned version) + build-essential; record `moon version`. Scaffold SAFELY into this existing repo — `moon new slide-gen` from cwd nests `slide-gen/slide-gen/` → verify `moon new .` in-place, else scaffold in a temp dir + move `src/`+`moon.mod.json` in. Module `slide-gen` (`moon.mod.json` preferred-target=native; `src/main` `is-main` (hyphen), bin-name=slide-gen, `async fn main`); `moon add moonbitlang/async@0.20.0`; wire `justfile` gates (fmt/check/build/test); seed `.gitignore` (`target/` + `_build/` + `enabled.txt` + future `decks/`) BEFORE the first build/state artifact; record that Serena lacks a MoonBit LSP → nav via grep/moon. **Accept**: fmt/check clean; `moon build --target native` yields the binary; `slide-gen --help` renders (argparse); `moon test` passes. ctx:
- **M1.2 Discovery** [OPEN] — sibling-enumeration module (readdir + full-path kind, symlink-aware, no recurse, exclude self; parent = repo-parent). **Tests**: tempdir fixtures (real dir / symlink→dir / symlink→file / broken symlink / plain file / dotfile-dir / nested subdir / cwd ≠ scanned parent) → assert exact candidate set. **Accept**: correct set on fixtures; `list` shows all (default-off). ctx:
- **M1.3 Toggle state + subcommands** [OPEN] — `Set[String]` model; newline file read (split on `\n`, strip only the line terminator + drop empty lines — do NOT trim name content: legal POSIX names can hold leading/trailing spaces) + write (sorted, atomic). Name policy: at discovery skip names with `\n`/`/`/control chars or leading/trailing whitespace (unrepresentable in the line format) → serialize stays total over candidates. `list/enable/disable/toggle/status`; `enable`/`toggle` validate name ∈ candidates; `disable` + `status` also handle STALE names (project deleted/renamed post-enable) → `disable <stale>` removes it, `status` flags entries ∉ candidates. **Tests**: `@quickcheck` sample-gen roundtrip serialize→parse→eq with a **constrained** name generator matching that policy (real finding: unconstrained `String` breaks the newline format); blackbox enable/disable/toggle/unknown-name/stale-disable/persist-across-invocations; `inspect` goldens on serialize + `list` output. **Accept**: state persists; subcommands mutate correctly; unknown rejected; stale removable; sample + blackbox + gates pass. ctx:

Close: all units DONE → M1 IMPLEMENTED → next session MILESTONE-REVIEW (1M context).

## M1 risks / watch
- `async@0.20.0` experimental → API churn (`write_file`/`kind` carry deprecations) → pin + lean on `inspect` snapshots to catch drift on upgrade.
- Native needs cc (build-essential); supports x86_64 + aarch64 (box verified x86_64) — wasm is NOT a fallback (async `@fs`/`@process` are native-only).
- Config-format migration in flight (`moon.pkg.json`→DSL; `target/`→`_build/`) → prefer `moon run`, don't hardcode paths.
- `x/fs.is_dir` follows symlinks + has no lstat → use async `@fs.kind(.,follow_symlink=false)`, not `x/fs`.
- Serena has no MoonBit LSP → symbol nav via grep + `moon check`/`mooninfo`.
