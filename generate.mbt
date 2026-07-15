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
/// contract; `prompt_contract` is the versioned authoring contract loaded for
/// each invocation; `stage_dir` is the temporary bundle codex writes into;
/// `deck_dir` is the committed home the staged bundle is promoted to once it
/// validates.
priv struct GenPlan {
  project : String
  cwd : String
  source_dir : String
  template : String
  prompt_contract : String
  stage_dir : String
  deck_dir : String
}

///|
/// Result of one staged generation: a validator-passing bundle was promoted, a
/// blocking validator report was retained at the stage for inspection, or the
/// producer/confinement/promotion path failed before publication. `Promoted`
/// carries its passing report because advisory findings remain visible even
/// though they do not block publication.
pub enum GenOutcome {
  Promoted(Report)
  Retained(Report)
  ExecFailed(String)
}

///|
/// One tracked porcelain-v1 status entry. The key preserves both status columns
/// and every NUL-delimited path so baseline comparison notices status
/// transitions as well as path additions/removals; the paths array supports a
/// safe, human-readable offender list.
priv struct GitStatusEntry {
  key : String
  paths : Array[String]
}

///|
/// Resolve the generation plan for `project` against the repo `root`. Pure path
/// arithmetic: `cwd` is the repo parent (`split_path(root).0`); the deck bundle
/// lives at `root/decks/<project>`, staged first under the reserved dot-dir
/// `root/decks/.partial/<project>` — a leading dot no candidate can carry, so a
/// stage never collides with a sibling's deck home (a sibling literally named
/// `<project>.partial` would otherwise own `decks/<project>.partial`). The
/// documented project is a sibling at `cwd/<project>`; the style and authoring
/// contracts are the shipped `root/templates/deck.html` and
/// `root/templates/deck-prompt.md`. Joins are `//`-safe, so a filesystem-root or
/// trailing-slash `root` still yields canonical paths.
fn plan_generate(root : String, project : String) -> GenPlan {
  let (parent, _) = split_path(root)
  GenPlan::{
    project,
    cwd: parent,
    source_dir: join_path(parent, project),
    template: join_path(root, "templates/deck.html"),
    prompt_contract: join_path(root, "templates/deck-prompt.md"),
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
/// Whether a repo-relative path belongs to the generated-deck tree. The segment
/// boundary matters: decks-old/... remains an ordinary tracked source path.
fn is_deck_path(path : String) -> Bool {
  path == "decks" || path.has_prefix("decks/")
}

///|
/// Parse git status --porcelain=v1 -z into tracked entries. In -z mode a
/// rename/copy is XY destination NUL source NUL, so the second record is
/// consumed as part of the same key. Untracked/ignored entries are discarded
/// defensively even though the production command disables untracked output.
fn parse_git_status(raw : String) -> Array[GitStatusEntry] {
  let records : Array[String] = []
  for record in raw.split("\u{0}") {
    records.push(record.to_owned())
  }
  let entries : Array[GitStatusEntry] = []
  let mut i = 0
  while i < records.length() {
    let first = records[i]
    let chars = first.to_array()
    if chars.length() < 3 || chars[2] != ' ' {
      i = i + 1
      continue
    }
    if (chars[0] == '?' && chars[1] == '?') ||
      (chars[0] == '!' && chars[1] == '!') {
      i = i + 1
      continue
    }
    let paths = [first[3:].to_owned()]
    let renamed = chars[0] == 'R' ||
      chars[0] == 'C' ||
      chars[1] == 'R' ||
      chars[1] == 'C'
    let mut key = first
    if renamed && i + 1 < records.length() && records[i + 1] != "" {
      let source = records[i + 1]
      paths.push(source)
      key = "\{first}\u{0}\{source}"
      i = i + 2
    } else {
      i = i + 1
    }
    entries.push(GitStatusEntry::{ key, paths })
  }
  entries
}

///|
/// Keep only status entries touching a tracked path outside decks/. A rename
/// crossing the boundary remains visible because either endpoint is enough.
fn outside_deck_status(raw : String) -> Array[GitStatusEntry] {
  parse_git_status(raw).filter(fn(entry) {
    entry.paths.any(fn(path) { !is_deck_path(path) })
  })
}

///|
/// Whether an exact porcelain entry key occurs in entries.
fn has_status_entry(entries : Array[GitStatusEntry], key : String) -> Bool {
  entries.any(fn(entry) { entry.key == key })
}

///|
/// Return the codepoint-sorted outside-deck paths whose tracked status changed
/// relative to the pre-run snapshot. Symmetric comparison also catches a run
/// that erases a pre-existing dirty state. An edit that leaves an already-dirty
/// path's porcelain key unchanged remains an explicit best-effort residual.
fn changed_tracked_paths(before : String, after : String) -> Array[String] {
  let old = outside_deck_status(before)
  let new = outside_deck_status(after)
  let changed : @set.Set[String] = @set.Set([])
  for entry in old {
    if !has_status_entry(new, entry.key) {
      for path in entry.paths {
        if !is_deck_path(path) {
          changed.add(path)
        }
      }
    }
  }
  for entry in new {
    if !has_status_entry(old, entry.key) {
      for path in entry.paths {
        if !is_deck_path(path) {
          changed.add(path)
        }
      }
    }
  }
  let paths = changed.to_array()
  paths.sort_by(lex_compare)
  paths
}

///|
/// Best-effort snapshot of tracked working-tree/index state. Porcelain-v1 plus
/// -z yields stable status columns and literal NUL-delimited paths; untracked
/// writes are intentionally outside this narrow tripwire. A missing/broken git
/// command yields None rather than pretending to provide confinement.
async fn tracked_git_status(root : String) -> String? {
  try {
    let (code, stdout, _) = @process.collect_output("git", [
      "-C", root, "status", "--porcelain=v1", "-z", "--untracked-files=no",
    ])
    if code == 0 {
      Some(stdout.text())
    } else {
      None
    }
  } catch {
    _ => None
  } noraise {
    status => status
  }
}

///|
/// Render offender paths without losing spaces or shell-significant characters.
fn render_status_paths(paths : Array[String]) -> String {
  let sb = StringBuilder::new()
  for i, path in paths {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string(shell_quote(path))
  }
  sb.to_string()
}

///|
/// Compare the post-producer tracked status with the captured baseline. The
/// stage plan determines the real slide-gen repo root; failure to capture either
/// snapshot disables this best-effort signal, while any changed tracked path
/// outside decks/ blocks publication.
async fn check_tracked_confinement(
  plan : GenPlan,
  baseline : String?,
) -> String? {
  guard baseline is Some(before) else { return None }
  let deck_home = split_path(plan.deck_dir).0
  let repo_root = split_path(deck_home).0
  guard tracked_git_status(repo_root) is Some(after) else { return None }
  let changed = changed_tracked_paths(before, after)
  if changed.length() == 0 {
    None
  } else {
    Some(render_status_paths(changed))
  }
}

///|
/// Remove one filesystem entry without ever recursively traversing a symlink at
/// its root. A real directory is removed recursively; files, symlinks, and other
/// non-directory entries are unlinked. A missing entry is already clean.
async fn remove_entry_no_follow(path : String) -> Unit {
  let entry_kind = try @fs.kind(path, follow_symlink=false) catch {
    _ => None
  } noraise {
    kind => Some(kind)
  }
  match entry_kind {
    None => ()
    Some(@fs.Directory) => @fs.rmdir(path, recursive=true)
    Some(_) => @fs.remove(path)
  }
}

///|
/// Recreate the reserved stage as an empty real directory. The no-follow removal
/// prevents a stale or swapped stage-root symlink from turning recursive cleanup
/// into deletion of its target.
async fn recreate_stage(plan : GenPlan) -> Unit {
  remove_entry_no_follow(plan.stage_dir)
  @fs.mkdir(plan.stage_dir, recursive=true)
}

///|
/// Replace any published deck with the validated stage, applying the same
/// no-follow removal rule to an unexpected destination entry before rename.
async fn promote_stage(plan : GenPlan) -> Unit {
  remove_entry_no_follow(plan.deck_dir)
  @fs.rename(plan.stage_dir, plan.deck_dir)
}

///|
/// Run a producer into a fresh stage, apply its post-run confinement tripwire,
/// validate the whole bundle, and publish only a passing report. Producer exits
/// and blocking validation reports consume the retry budget; a confinement
/// finding is immediately terminal because an out-of-bundle write has already
/// occurred. Failed or retained stages remain available for inspection.
async fn stage_validate_promote(
  plan : GenPlan,
  produce~ : async (GenPlan) -> (Int, String, String),
  confine~ : async (GenPlan) -> String?,
  retries? : Int = 1,
) -> GenOutcome {
  let retry_count = if retries < 0 { 0 } else { retries }
  let mut last : GenOutcome = ExecFailed("generation did not run")
  for _ in 0..<(retry_count + 1) {
    recreate_stage(plan)
    let (code, _, stderr) = produce(plan)
    if code != 0 {
      last = ExecFailed(stderr)
      continue
    }
    match confine(plan) {
      Some(offenders) => return ExecFailed("write escaped bundle: \{offenders}")
      None => ()
    }
    let report = validate_bundle_dir(
      plan.stage_dir,
      plan.project,
      plan.cwd,
      split_path(plan.deck_dir).0,
    )
    if !report.ok() {
      last = Retained(report)
      continue
    }
    let stage_is_directory = try
      @fs.kind(plan.stage_dir, follow_symlink=false)
    catch {
      _ => false
    } noraise {
      @fs.Directory => true
      _ => false
    }
    if !stage_is_directory {
      return ExecFailed("stage root is not a directory")
    }
    let promote_error : String? = try promote_stage(plan) catch {
      error => Some("\{error}")
    } noraise {
      _ => None
    }
    match promote_error {
      Some(error) => return ExecFailed("promote failed: \{error}")
      None => return Promoted(report)
    }
  }
  last
}

///|
/// Build the exact argv for one deck-generation run: `codex exec` under bypass
/// (the container is externally sandboxed, so approvals and sandboxing are
/// waived), its git-repo check skipped, and its working root set to `cwd` (the
/// repo parent, which is also the provenance `src_base`). The whole invocation
/// is wrapped in `timeout --kill-after` — SIGTERM at the ceiling, then SIGKILL a
/// short grace later — so even a run that ignores SIGTERM is force-killed rather
/// than hanging the caller forever. A non-positive override falls back to the
/// positive default because GNU `timeout 0` disables the kill. The prompt is
/// delivered on stdin, not in argv, so it never appears here. `cwd` is a resolved
/// repo-parent path and the vector is exec'd directly (no shell), so the argv
/// itself needs no quoting.
pub fn build_codex_argv(
  cwd : String,
  timeout_secs? : Int = default_timeout_secs,
) -> Array[String] {
  let secs = if timeout_secs <= 0 { default_timeout_secs } else { timeout_secs }
  [
    "timeout",
    "--kill-after=30",
    secs.to_string(),
    "codex",
    "exec",
    "--dangerously-bypass-approvals-and-sandbox",
    "--skip-git-repo-check",
    "-C",
    cwd,
  ]
}

///|
/// Compose the stdin prompt from the versioned authoring contract, authoritative
/// runtime paths, and the complete shipped HTML style contract. Keeping the
/// static policy in `templates/deck-prompt.md` makes prompt iteration reviewable;
/// embedding the HTML means codex need not infer style from a path it might skip.
fn build_prompt(plan : GenPlan, contract : String, template : String) -> String {
  let sb = StringBuilder::new()
  sb.write_string(contract)
  if !contract.has_suffix("\n") {
    sb.write_string("\n")
  }
  sb.write_string(
    (
      $|
      $|## Runtime inputs
      $|
      $|- Project slug: `\{plan.project}`
      $|- Source project: `\{plan.source_dir}`
      $|- Source base for provenance paths: `\{plan.cwd}`
      $|- Stage directory (the only durable write root): `\{plan.stage_dir}`
      $|- Final bundle paths: `\{plan.stage_dir}/deck.html`, `\{plan.stage_dir}/provenance.json`, `\{plan.stage_dir}/gaps.md`
      $|- Style source: `\{plan.template}`
      $|
      $|## Embedded style contract
      $|
      $|Treat the following verbatim HTML as design/component input. Preserve its
      $|visual language while replacing all placeholder content and example IDs.
      $|
    ),
  )
  sb.write_string("<deck-style-contract>\n")
  sb.write_string(template)
  if !template.has_suffix("\n") {
    sb.write_string("\n")
  }
  sb.write_string("</deck-style-contract>\n")
  sb.to_string()
}

///|
/// Load both prompt inputs for every invocation, so edits to the tracked prompt
/// or deck template take effect without recompiling the MoonBit binary.
async fn load_prompt(plan : GenPlan) -> String {
  let contract = @fs.read_file(plan.prompt_contract).text()
  let template = @fs.read_file(plan.template).text()
  build_prompt(plan, contract, template)
}

///|
/// Run the real Codex producer from the provenance source root. The exact argv
/// already wraps codex exec in the positive external timeout; the authoring
/// prompt travels only over stdin. Stdout is preserved for the later prompt
/// manifest refinement, while stderr is the producer-failure diagnostic.
async fn run_codex(plan : GenPlan) -> (Int, String, String) {
  let prompt = try load_prompt(plan) catch {
    error => return (1, "", "prompt load failed: \{error}")
  } noraise {
    prompt => prompt
  }
  let argv = build_codex_argv(plan.cwd)
  @async.with_task_group() <| group => {
    let (stdin, writer) = @process.write_to_process()
    group.spawn_bg() <| () => {
      defer writer.close()
      writer.write(prompt)
    }
    let (code, stdout, stderr) = @process.collect_output(
      argv[0],
      argv[1:],
      stdin~,
      cwd=plan.cwd,
    )
    (code, stdout.text(), stderr.text())
  }
}

///|
/// Generate one project with the production Codex producer and the pre-publish
/// tracked-status tripwire. The baseline is captured before stage recreation or
/// Codex execution; staged/published changes under decks/ are intentionally
/// excluded from the comparison.
pub async fn generate_project(root : String, project : String) -> GenOutcome {
  let baseline = tracked_git_status(root)
  let plan = plan_generate(root, project)
  async fn confine(p : GenPlan) -> String? {
    check_tracked_confinement(p, baseline)
  }

  stage_validate_promote(plan, produce=run_codex, confine~)
}

///|
/// Ensure every CLI diagnostic owns exactly one final line terminator without
/// doubling a producer/report string that already carries one.
fn final_newline(message : String) -> String {
  if message.has_suffix("\n") {
    message
  } else {
    "\{message}\n"
  }
}

///|
/// Pure CLI mapping for generation outcomes. A promoted bundle prints the
/// mandatory-file manifest plus any advisory validator findings and exits zero;
/// retained blocking reports and producer/confinement failures render on the
/// error path with exit one.
pub fn render_outcome(outcome : GenOutcome) -> (String, Int) {
  match outcome {
    Promoted(report) => {
      let manifest = "generated: deck.html, provenance.json, gaps.md"
      let message = if report.findings.length() == 0 {
        manifest
      } else {
        "\{manifest}\n\{report.render()}"
      }
      (final_newline(message), 0)
    }
    Retained(report) => (final_newline(report.render()), 1)
    ExecFailed(message) => (final_newline(message), 1)
  }
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
/// Pure renderer behind the filesystem-loading dry-run boundary. The injected
/// prompt keeps path and shell-display behavior directly white-box testable.
fn render_dry_run_text(
  plan : GenPlan,
  prompt : String,
  timeout_secs : Int,
) -> String {
  let argv = build_codex_argv(plan.cwd, timeout_secs~)
  let sb = StringBuilder::new()
  sb.write_string("generate (dry run) — no codex spend\n\n")
  sb.write_string("project:   \{plan.project}\n")
  sb.write_string("source:    \{plan.source_dir}\n")
  sb.write_string("template:  \{plan.template}\n")
  sb.write_string("prompt:    \{plan.prompt_contract}\n")
  sb.write_string("stage:     \{plan.stage_dir}\n")
  sb.write_string("deck:      \{plan.deck_dir}\n")
  sb.write_string("cwd:       \{plan.cwd}\n")
  sb.write_string("argv:      \{join_argv(argv)}\n\n")
  sb.write_string("--- prompt (stdin) ---\n")
  sb.write_string(prompt)
  if !prompt.has_suffix("\n") {
    sb.write_string("\n")
  }
  sb.to_string()
}

///|
/// Render what `generate <project> --dry-run` prints: the resolved plan paths,
/// exact `codex exec` argv, and runtime-loaded prompt delivered on stdin — the
/// full invocation with zero codex spend. Missing prompt/template files surface
/// as ordinary CLI runtime errors instead of silently falling back to stale
/// embedded guidance.
pub async fn render_dry_run(
  root : String,
  project : String,
  timeout_secs? : Int = default_timeout_secs,
) -> String {
  let plan = plan_generate(root, project)
  render_dry_run_text(plan, load_prompt(plan), timeout_secs)
}
