# slide-gen

`slide-gen` generates, validates, and renders presentation decks from projects
next to this checkout. It is a Debian/Linux, checkout-bound application: the
repository is both the program home and the long-lived deck home, not a
standalone binary distribution.

```text
~/Projects/
├── slide-gen/
├── rehab/
└── another-project/
```

Discovery reads direct sibling directories and directory symlinks. It never
auto-adds names to `enabled.txt`; enabled state is exactly the ignored,
persisted set, including any stale names whose sibling has disappeared.

## Setup

Building and installing require MoonBit's native toolchain, a C toolchain, and
[`just`](https://github.com/casey/just). Generation expects Git, an authenticated
Codex CLI, GNU `timeout`, [`uv`](https://docs.astral.sh/uv/), Python 3.11 or
newer, and ChromiumFish. Rendering requires GNU `timeout`, uv, ChromiumFish,
`fontconfig`, and the exact `Noto Sans CJK JP` font. If Git snapshots fail,
generation continues without its tracked-write tripwire.

The deterministic developer gate additionally uses Git, curl, ShellCheck, GNU
coreutils, and util-linux. Browser/live verification uses Poppler. `just
install` installs none of these external tools; canonical verified CI versions
are pinned in [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

From the checkout:

```sh
just install
export PATH="$HOME/.local/bin:$PATH" # when that directory is not already on PATH
slide-gen --version
```

`just install` builds `.install/bin/slide-gen` and links the checkout's
`bin/slide-gen` launcher into `~/.local/bin`. Override the destination with
`SLIDE_GEN_INSTALL_BIN=/absolute/bin just install`. Re-running it is safe for
the same checkout; it refuses to replace a foreign file or symlink. The checkout
must remain at the installed path.

After updating the checkout, rebuild the native payload. The developer gate is
optional for an operator update:

```sh
git pull --ff-only
just ci      # optional developer verification
just install
```

## Use

> [!WARNING]
> `generate` and `run` invoke `codex exec` with
> `--dangerously-bypass-approvals-and-sandbox`. Operate inside real external
> containment. Preview the exact invocation and full prompt with
> `slide-gen generate --dry-run NAME` before spending tokens. Each project can
> trigger up to two token-consuming Codex invocations; a batch can do this for
> every enabled project. The harness pins neither model nor reasoning effort -
> the active Codex configuration controls behavior, cost, and output.

```sh
slide-gen list
slide-gen enable rehab
slide-gen status
slide-gen generate --dry-run rehab
slide-gen run rehab
```

Named `generate` and `run` accept any current sibling, whether enabled or not.
Omitting the name processes the enabled set sequentially. A named `render`
reads any suitable existing deck bundle under `decks/NAME`; neither a current
source sibling nor Git tracking is required.

| Command | Effect |
| --- | --- |
| `slide-gen list` | List discoverable siblings. |
| `slide-gen status` | Show enabled, disabled, and stale enabled names. |
| `slide-gen enable NAME` | Enable one current sibling. |
| `slide-gen disable NAME` | Disable a current or stale enabled name. |
| `slide-gen toggle NAME` | Flip a current sibling, or clear a stale enabled name. |
| `slide-gen generate [NAME]` | Generate one deck or the enabled set through Codex. |
| `slide-gen generate --dry-run [NAME]` | Print exact generation plans without Codex spend. |
| `slide-gen render NAME` | Render one existing deck; there is no render batch mode. |
| `slide-gen run [NAME]` | Generate, then render one sibling or the enabled set. |

`run` intentionally has no dry-run: generation can be previewed, but rendering
not-yet-generated content cannot. Batch work runs current siblings in
discovery/codepoint order, appends stale enabled names in sorted order,
continues after item failures, and exits 1 if any item failed. Batch reports
remain on stdout even on exit 1; named runtime failures use stderr. An empty
enabled set succeeds with a zero-item summary. Exit 2 is a command-line parse
error; other runtime failures exit 1.

## State and output

```text
enabled.txt                         ignored local selection
enabled.txt.tmp                     transient fixed-path state write
decks/<project>/                    review, then commit manually if desired
  deck.html
  provenance.json
  gaps.md
  figures.py                        conditional
  assets/*.png                      conditional
decks/.partial/<project>/           ignored generation stage
decks/.previous/<project>/          ignored publication recovery backup
renders/<project>/                  ignored derived output
  page_01.png ...
  deck.pdf
renders/.partial/<project>/         ignored render stage
renders/.previous/<project>/        ignored publication recovery backup
renders/.locks/<project>.lock       ignored advisory project lease
.install/                           ignored native payload/build/CI scratch
```

Enabled-state mutations use one fixed temporary file and no writer lock.
Concurrent `enable`, `disable`, or `toggle` operations are unsupported.

A successful generation publishes the three mandatory bundle files; figure
code and PNG assets appear only when the deck uses figures. Success means no
blocking `[MUST]` findings. Advisory `[SHOULD]` warnings and disclosed gaps may
remain, and are printed for human review.

A successful render publishes 2560x1440 RGB page images and a PDF mapping one
pixel to one point at 72 dpi. `img2pdf` is invoked with no-recompression
options. Runtime validation checks PNG IHDR fields, closed layout, and only the
PDF's `%PDF-` prefix; explicit Poppler live gates prove page structure and
lossless image streams. Rendering does not recheck source provenance or rerun
`figures.py`.

## Failure and recovery

Generation stages a complete replacement bundle, validates the raw bundle,
postprocesses furigana, and validates the final bundle. It retries that whole
flow once. A final failed stage remains under `decks/.partial/` for inspection;
the next attempt erases it.

Failures before render invalidation preserve the previous deck/render pair. A
successful generation invalidates both the live and recovery render, then
replaces the entire deck bundle. Standalone `generate` therefore removes an
existing PDF until `render` runs again. If deck promotion fails after
invalidation, the old or recovered deck may remain with no render. A crash
between live-to-backup and stage-to-live renames can temporarily remove the
live bundle until the next operation performs recovery.

A direct render failure retains the previous complete render. `run` is not an
atomic deck-plus-PDF transaction: generation failure skips rendering, while a
post-generation render failure leaves the new deck published and
`renders/PROJECT` absent. The command reports that phase-specific partial
failure. Per-project advisory locks coordinate participating `slide-gen`
processes only.

## Safety and review

Codex may read anything and, under bypass, can write anywhere the surrounding
environment permits. After each producer or postprocessor, the harness compares
Git snapshots of tracked files in this checkout. A detected tracked change
blocks publication but is left in place. If either snapshot fails, the check is
disabled. It cannot see sibling, ignored, untracked, non-Git, or
outside-checkout writes and never rolls changes back.

Review every byte under `decks/<project>/` before committing or pushing it,
including HTML, verbatim provenance quotes, gaps, Python, and PNG pixels. Review
or delete retained failed stages under `decks/.partial/` and
`renders/.partial/` too: ignored files are not a privacy boundary. There is no
deterministic secret or PHI filter. The provenance validator proves only that a
literal quote occurs in its cited line slice - not that a claim is true,
well-supported, correctly attributed, or free of cherry-picking. Furigana
checks surface structural and analyzer disagreements; they do not replace a
fluent human review.

Realpath, `lstat`, and publication checks are portable path-based defenses, not
handle-based confinement. A hostile concurrent actor can race them; advisory
locks protect only cooperating slide-gen processes. Chromium runs with
`--no-sandbox`. Static-markup validation and a dead network proxy are defense in
depth, not a browser security boundary. Render bytes are repeatable only on a
fixed browser/font/tool surface, not across arbitrary machines.

## Development and verification

```sh
just ci            # deterministic; format-check only; tracked baseline guard
just all           # local sweep; formats sources in place
just render-probe  # real Chromium DOM/raster/PDF probes; no Codex
just live-render   # render both published decks twice; no Codex
just live-run      # token spend: installed generate-to-PDF proof
SLIDE_GEN_LIVE=1 just test # token spend: two-project live generation fixture
```

> [!CAUTION]
> Live gating checks whether `SLIDE_GEN_LIVE` is present, so even
> `SLIDE_GEN_LIVE=0` activates Codex and `just all` inherits it. Unset the
> variable before `just test` or `just all`. `just ci` strips every live switch.
> The two-project live fixture may make four Codex invocations after retries.
> `just live-run` is independently explicit and may make two Codex invocations
> if its one-project generation needs the production retry.

`just ci` syncs the locked Python environment, runs one MoonBit dependency
bootstrap step designed to work from cold caches, verifies the downloaded
dependency archive, then uses frozen/deny-warning gates. It builds release
output and exercises the same non-frozen `moon install` path used by operators,
plus the launcher in repo-local scratch.

The wrapper captures Git-observable HEAD, staged entries, persistent index
flags, status, and index-to-worktree changes before and after the gate. Existing
staged or unstaged work is allowed; a gate-induced tracked change fails and is
left for inspection. Every untracked file - including ignored dependencies,
build output, and install caches - is outside that promise.

Local `just ci` uses the locally installed MoonBit, uv, just, and ShellCheck.
GitHub CI runs only `just ci` with `contents: read`, disabled checkout
credentials, full-SHA-pinned actions, and explicit checksums for MoonBit, uv,
just, ShellCheck, and the MoonBit package archive on the canonical Ubuntu
stack. Codex and Chromium gates stay explicit local jobs because they require
authentication, spend, and the fixed browser/font surface.

The two-project `SLIDE_GEN_LIVE=1 just test` fixture proves generation only.
`just live-run` instead copies the prospective nonignored tree into a clean
nested Git checkout under `.install/`, installs its launcher into a hidden
sibling bin, and invokes one enabled-set `run` from outside that checkout. It
independently revalidates the final bundle and render layout, uses Poppler to
require ordered 2560x1440-point lossless page images at 72 dpi, and leaves
rasterized inspection pages at the printed scratch path. The outer
tracked-baseline wrapper proves the source checkout unchanged.

Licensed under [Apache-2.0 WITH LLVM-exception](LICENSE).
