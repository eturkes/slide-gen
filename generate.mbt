// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Wall-clock ceiling (seconds) for a single `codex exec` deck-generation run,
/// enforced by wrapping the invocation in the `timeout` binary. Deck authoring
/// is a heavy multi-file agent task, so the default is generous; the live
/// harness (M2.3b) overrides it as needed.
pub let default_timeout_secs : Int = 1800

///|
/// Resolved filesystem plan for generating `project`'s deck, derived from the
/// repo `root`. `cwd` (the repo parent) is codex's working root and the
/// provenance source base, so sibling sources are cited parent-relative;
/// `source_dir` is the project being documented; `template` is the style
/// contract; `stage_dir` is the temporary bundle codex writes into; `deck_dir`
/// is the committed home the staged bundle is promoted to once it validates.
priv struct GenPlan {
  project : String
  cwd : String
  source_dir : String
  template : String
  stage_dir : String
  deck_dir : String
}

///|
/// Resolve the generation plan for `project` against the repo `root`. Pure path
/// arithmetic: `cwd` is the repo parent (`split_path(root).0`); the deck bundle
/// lives at `root/decks/<project>`, staged first under the reserved dot-dir
/// `root/decks/.partial/<project>` — a leading dot no candidate can carry, so a
/// stage never collides with a sibling's deck home (a sibling literally named
/// `<project>.partial` would otherwise own `decks/<project>.partial`). The
/// documented project is a sibling at `cwd/<project>`; the style contract is the
/// shipped `root/templates/deck.html`. Joins are `//`-safe, so a filesystem-root
/// or trailing-slash `root` still yields canonical paths.
fn plan_generate(root : String, project : String) -> GenPlan {
  let (parent, _) = split_path(root)
  GenPlan::{
    project,
    cwd: parent,
    source_dir: join_path(parent, project),
    template: join_path(root, "templates/deck.html"),
    stage_dir: join_path(root, "decks/.partial/\{project}"),
    deck_dir: join_path(root, "decks/\{project}"),
  }
}

///|
/// Join a directory `base` and a relative `child` with a single separator:
/// trailing slashes on `base` are stripped and the filesystem-root `/` is
/// special-cased, so no join ever produces a `//`. Keeps every derived plan path
/// canonical however `root` was spelled.
fn join_path(base : String, child : String) -> String {
  let mut b = base
  while b.length() > 1 && b.has_suffix("/") {
    b = b[:b.length() - 1].to_owned()
  }
  if b == "/" {
    "/\{child}"
  } else {
    "\{b}/\{child}"
  }
}

///|
/// Build the exact argv for one deck-generation run: `codex exec` under bypass
/// (the container is externally sandboxed, so approvals and sandboxing are
/// waived), its git-repo check skipped, and its working root set to `cwd` (the
/// repo parent, which is also the provenance `src_base`). The whole invocation
/// is wrapped in `timeout --kill-after` — SIGTERM at the ceiling, then SIGKILL a
/// short grace later — so even a run that ignores SIGTERM is force-killed rather
/// than hanging the caller forever (callers pass a positive `timeout_secs`;
/// `timeout 0` would disable the kill). The prompt is delivered on stdin, not in
/// argv, so it never appears here. `cwd` is a resolved repo-parent path and the
/// vector is exec'd directly (no shell), so the argv itself needs no quoting.
pub fn build_codex_argv(
  cwd : String,
  timeout_secs? : Int = default_timeout_secs,
) -> Array[String] {
  [
    "timeout",
    "--kill-after=30",
    timeout_secs.to_string(),
    "codex",
    "exec",
    "--dangerously-bypass-approvals-and-sandbox",
    "--skip-git-repo-check",
    "-C",
    cwd,
  ]
}

///|
/// First-draft deck-authoring prompt delivered to codex on stdin; the refined,
/// version-controlled contract lands in M2.4. It tells codex to document
/// `plan.source_dir` as a slide-deck bundle written into `plan.stage_dir`,
/// styled after the shipped template, with per-claim provenance whose citations
/// are parent-relative (resolved against `plan.cwd`) and an honest gaps list.
fn build_prompt(plan : GenPlan) -> String {
  (
    $|Generate a Japanese slide deck documenting the '\{plan.project}' project at \{plan.source_dir}.
    $|
    $|Write a deck bundle into \{plan.stage_dir}/ (create it):
    $|  - deck.html: match the structure and CSS of \{plan.template} exactly — a
    $|    Japanese three-tier layout (.jp original / .jpf furigana / .en gloss per
    $|    .entry), one <section class="slide"> per slide, each with an .eyebrow, a
    $|    .pageno, and its .entry blocks. Tag every data-bearing claim with
    $|    data-claim="<id>".
    $|  - provenance.json: a JSON array of rows {id, slide, claim, status, src,
    $|    quote}. status is verified | inferred | gap. For a non-gap row, src is
    $|    "<path>:<startLine>-<endLine>" with <path> relative to \{plan.cwd} (never
    $|    absolute) and quote copied verbatim from that exact line range. Cite only
    $|    real source files you read, never a file you write into the bundle. Every
    $|    deck data-claim id must match a row id.
    $|  - gaps.md: a Markdown bullet list of whatever you could not verify from the
    $|    sources, or the single line "no gaps". Route uncertain furigana readings
    $|    here rather than guessing.
    $|  - figures.py + assets/*.png: author figures only from committed, cited
    $|    numbers and run them; cite each PNG with a provenance row.
    $|
    $|Read only real files under \{plan.cwd}; never invent quotes, line numbers, or
    $|readings. Keep secrets and personal or health data out of every committed
    $|file. Reply with a manifest listing the files you wrote.
  )
}

///|
/// Join an argv vector into one shell-runnable line for the dry-run display,
/// POSIX-quoting any element that is empty or carries a shell-significant
/// character so a `cwd` with a space still copy-pastes as a single argument. The
/// live run execs the vector directly (no shell), so this quoting is display-only.
fn join_argv(argv : Array[String]) -> String {
  let sb = StringBuilder::new()
  for i, arg in argv {
    if i > 0 {
      sb.write_string(" ")
    }
    sb.write_string(shell_quote(arg))
  }
  sb.to_string()
}

///|
/// Single-quote `s` for shell display when it is empty or holds any character
/// outside a conservative unquoted-safe set (letters, digits, and the path/flag
/// punctuation the argv actually uses); otherwise return it unchanged. An
/// embedded single quote becomes the standard `'\''` break-out. Resolved repo
/// paths and the fixed flags stay unquoted, so only an exotic `cwd` gains quotes.
fn shell_quote(s : String) -> String {
  let chars = s.to_array()
  let mut safe = chars.length() > 0
  for c in chars {
    let code = c.to_int()
    let ok = (code >= 0x41 && code <= 0x5a) ||
      (code >= 0x61 && code <= 0x7a) ||
      (code >= 0x30 && code <= 0x39) ||
      c == '/' ||
      c == '.' ||
      c == '_' ||
      c == '-' ||
      c == '=' ||
      c == ':' ||
      c == '+' ||
      c == '@' ||
      c == ','
    if !ok {
      safe = false
      break
    }
  }
  if safe {
    return s
  }
  let sb = StringBuilder::new()
  sb.write_string("'")
  for c in chars {
    if c == '\'' {
      sb.write_string("'\\''")
    } else {
      sb.write_string("\{c}")
    }
  }
  sb.write_string("'")
  sb.to_string()
}

///|
/// Render what `generate <project> --dry-run` prints: the resolved plan paths,
/// the exact `codex exec` argv, and the prompt delivered on stdin — the full
/// invocation with zero codex spend. Pure (no filesystem access), so it is
/// golden-tested directly.
pub fn render_dry_run(
  root : String,
  project : String,
  timeout_secs? : Int = default_timeout_secs,
) -> String {
  let plan = plan_generate(root, project)
  let argv = build_codex_argv(plan.cwd, timeout_secs~)
  let sb = StringBuilder::new()
  sb.write_string("generate (dry run) — no codex spend\n\n")
  sb.write_string("project:   \{plan.project}\n")
  sb.write_string("source:    \{plan.source_dir}\n")
  sb.write_string("template:  \{plan.template}\n")
  sb.write_string("stage:     \{plan.stage_dir}\n")
  sb.write_string("deck:      \{plan.deck_dir}\n")
  sb.write_string("cwd:       \{plan.cwd}\n")
  sb.write_string("argv:      \{join_argv(argv)}\n\n")
  sb.write_string("--- prompt (stdin) ---\n")
  sb.write_string(build_prompt(plan))
  sb.write_string("\n")
  sb.to_string()
}
