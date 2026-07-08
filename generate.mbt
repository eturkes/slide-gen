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
/// lives at `root/decks/<project>`, staged first at
/// `root/decks/<project>.partial`; the documented project is a sibling at
/// `cwd/<project>`; the style contract is the shipped `root/templates/deck.html`.
fn plan_generate(root : String, project : String) -> GenPlan {
  let (parent, _) = split_path(root)
  GenPlan::{
    project,
    cwd: parent,
    source_dir: "\{parent}/\{project}",
    template: "\{root}/templates/deck.html",
    stage_dir: "\{root}/decks/\{project}.partial",
    deck_dir: "\{root}/decks/\{project}",
  }
}

///|
/// Build the exact argv for one deck-generation run: `codex exec` under bypass
/// (the container is externally sandboxed, so approvals and sandboxing are
/// waived), its git-repo check skipped, and its working root set to `cwd` (the
/// repo parent, which is also the provenance `src_base`). The whole invocation
/// is wrapped in `timeout` so a hung run is killed. The prompt is delivered on
/// stdin, not in argv, so it never appears here. `cwd` is a resolved repo-parent
/// path and the vector is exec'd directly (no shell), so no quoting is involved.
pub fn build_codex_argv(
  cwd : String,
  timeout_secs? : Int = default_timeout_secs,
) -> Array[String] {
  [
    "timeout",
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
    $|    "<path>:<startLine>-<endLine>" (path relative to \{plan.cwd}, or absolute)
    $|    and quote is text copied verbatim from that exact line range. Every deck
    $|    data-claim id must match a row id.
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
/// Space-join an argv vector into a single readable line for the dry-run display.
/// The elements here are fixed flags plus a resolved `cwd` path with no embedded
/// spaces, so a plain join is unambiguous.
fn join_argv(argv : Array[String]) -> String {
  let sb = StringBuilder::new()
  for i, arg in argv {
    if i > 0 {
      sb.write_string(" ")
    }
    sb.write_string(arg)
  }
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
