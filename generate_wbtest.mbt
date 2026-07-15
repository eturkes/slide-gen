// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Pin `shell_quote`'s branches directly — it is package-private, so the dry-run
/// render goldens reach only the spaced-path case. It returns an unquoted-safe
/// element untouched and single-quotes everything else: the empty string (else
/// it vanishes from a reconstructed argv), an embedded single quote (the POSIX
/// `'\''` break-out), and any shell metacharacter. The quoting is display-only —
/// the live harness (M2.3b) execs the argv vector directly, so this string never
/// reaches a shell.
test "shell_quote leaves safe elements bare and single-quotes the rest" {
  // All-safe (letters/digits + the path/flag punctuation the argv carries): bare.
  inspect(
    shell_quote("/w/Projects/slide-gen"),
    content=(
      #|/w/Projects/slide-gen
    ),
  )
  inspect(
    shell_quote("--kill-after=30"),
    content=(
      #|--kill-after=30
    ),
  )
  inspect(
    shell_quote("a.b_c-d:e+f@g,h"),
    content=(
      #|a.b_c-d:e+f@g,h
    ),
  )
  // Empty -> '' so it survives as one (empty) argument.
  inspect(
    shell_quote(""),
    content=(
      #|''
    ),
  )
  // A space -> quoted, so the element stays a single argument.
  inspect(
    shell_quote("/w/My Projects"),
    content=(
      #|'/w/My Projects'
    ),
  )
  // An embedded single quote -> the standard '\'' break-out.
  inspect(
    shell_quote("a'b"),
    content=(
      #|'a'\''b'
    ),
  )
  // Shell metacharacters -> quoted (parameter expansion, command separator).
  inspect(
    shell_quote("a$b"),
    content=(
      #|'a$b'
    ),
  )
  inspect(
    shell_quote("a;b"),
    content=(
      #|'a;b'
    ),
  )
}

///|
/// Smallest honest bundle accepted by the deterministic validators: one complete
/// slide, no claims or figures, an empty provenance array, and the no-gaps
/// sentinel. Keeping this fixture local avoids coupling white-box harness tests
/// to the black-box validator test module.
fn gen_stub_deck(project : String, entry? : String = "a") -> String {
  "<!doctype html>\n<html lang=\"ja\">\n<head>\n<meta charset=\"utf-8\">\n<style>body{}</style>\n</head>\n<body>\n<section class=\"slide\"><div class=\"eyebrow\"><span class=\"n\">01</span><span>l</span></div><div class=\"entry\"><div class=\"jp\">\{entry}</div><div class=\"jpf\">\{entry}</div><div class=\"en\">\{entry}</div></div><div class=\"pageno\">\{project} \u{b7} 1 / 1</div></section>\n</body>\n</html>\n"
}

///|
/// A generation plan rooted wholly inside one test tmpdir.
fn gen_stub_plan(root : String, project? : String = "project") -> GenPlan {
  GenPlan::{
    project,
    cwd: root,
    source_dir: "\{root}/\{project}",
    template: "\{root}/template.html",
    stage_dir: "\{root}/decks/.partial/\{project}",
    deck_dir: "\{root}/decks/\{project}",
  }
}

///|
/// Fill an already-created stage with the canonical passing stub bundle.
async fn write_gen_stub(plan : GenPlan, entry? : String = "a") -> Unit {
  @fs.write_file(
    "\{plan.stage_dir}/deck.html",
    gen_stub_deck(plan.project, entry~),
    create_mode=CreateOrTruncate,
  )
  @fs.write_file(
    "\{plan.stage_dir}/provenance.json",
    "[]\n",
    create_mode=CreateOrTruncate,
  )
  @fs.write_file(
    "\{plan.stage_dir}/gaps.md",
    "no gaps\n",
    create_mode=CreateOrTruncate,
  )
}

///|
/// Test confinement seam that observes the stage asynchronously and accepts it.
async fn allow_gen_stage(plan : GenPlan) -> String? {
  ignore(@fs.exists(plan.stage_dir))
  None
}

///|
/// A passing bundle promotes over an existing published deck. A symlink planted
/// at the stage root is unlinked rather than recursively traversed, preserving
/// its target before the clean stage is rebuilt.
async test "stage_validate_promote safely rebuilds and promotes a passing bundle" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-stage-good")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let plan = gen_stub_plan(root)
    let outside = "\{root}/outside"
    @fs.mkdir(outside)
    @fs.write_file("\{outside}/sentinel", "keep", create_mode=CreateOrTruncate)
    @fs.mkdir(split_path(plan.stage_dir).0, recursive=true)
    @fs.symlink(plan.stage_dir, target=outside)
    @fs.mkdir(plan.deck_dir)
    @fs.write_file(
      "\{plan.deck_dir}/stale",
      "old",
      create_mode=CreateOrTruncate,
    )
    async fn produce(p : GenPlan) -> (Int, String, String) {
      write_gen_stub(p)
      (0, "manifest", "")
    }

    let outcome = stage_validate_promote(
      plan,
      produce~,
      confine=allow_gen_stage,
    )
    guard outcome is Promoted(report) else {
      abort("passing stub was not promoted")
    }
    assert_true(report.ok())
    assert_true(@fs.exists("\{plan.deck_dir}/deck.html"))
    assert_false(@fs.exists("\{plan.deck_dir}/stale"))
    assert_false(@fs.exists(plan.stage_dir))
    assert_true(@fs.exists("\{outside}/sentinel"))
  }
}

///|
/// A producer that exits successfully without writing deck.html is validated as
/// a retained `deck.missing` failure, retried once, and left staged for inspection.
async test "stage_validate_promote retains an invalid bundle after one retry" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-stage-bad")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let plan = gen_stub_plan(root)
    let mut calls = 0
    async fn produce(p : GenPlan) -> (Int, String, String) {
      calls = calls + 1
      ignore(@fs.exists(p.stage_dir))
      (0, "", "")
    }

    let outcome = stage_validate_promote(
      plan,
      produce~,
      confine=allow_gen_stage,
    )
    guard outcome is Retained(report) else {
      abort("invalid stub was not retained")
    }
    json_inspect(report.codes(), content=["deck.missing"])
    assert_eq(calls, 2)
    assert_true(@fs.exists(plan.stage_dir))
    assert_false(@fs.exists(plan.deck_dir))
  }
}

///|
/// A nonzero producer exit returns its stderr after the requested attempt count
/// without validating or publishing the empty stage.
async test "stage_validate_promote reports producer failure" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-stage-exec")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let plan = gen_stub_plan(root)
    async fn produce(p : GenPlan) -> (Int, String, String) {
      ignore(@fs.exists(p.stage_dir))
      (7, "", "codex failed")
    }

    let outcome = stage_validate_promote(
      plan,
      produce~,
      confine=allow_gen_stage,
      retries=0,
    )
    guard outcome is ExecFailed(message) else {
      abort("nonzero producer was not reported")
    }
    assert_eq(message, "codex failed")
    assert_true(@fs.exists(plan.stage_dir))
    assert_false(@fs.exists(plan.deck_dir))
  }
}

///|
/// A confinement finding is non-retryable: it blocks promotion immediately even
/// when the staged bundle itself passes validation.
async test "stage_validate_promote blocks escaped writes without retry" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-stage-confine")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let plan = gen_stub_plan(root)
    let mut calls = 0
    async fn produce(p : GenPlan) -> (Int, String, String) {
      calls = calls + 1
      write_gen_stub(p)
      (0, "", "")
    }

    async fn confine(p : GenPlan) -> String? {
      ignore(@fs.exists(p.stage_dir))
      Some("tracked.txt")
    }

    let outcome = stage_validate_promote(plan, produce~, confine~)
    guard outcome is ExecFailed(message) else {
      abort("escaped write was not blocked")
    }
    assert_eq(message, "write escaped bundle: tracked.txt")
    assert_eq(calls, 1)
    assert_true(@fs.exists("\{plan.stage_dir}/deck.html"))
    assert_false(@fs.exists(plan.deck_dir))
  }
}

///|
/// The default retry budget recovers from one nonzero producer exit, recreates
/// the stage, and promotes the second attempt's valid bundle.
async test "stage_validate_promote retries once then promotes" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-stage-retry")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let plan = gen_stub_plan(root)
    let mut calls = 0
    async fn produce(p : GenPlan) -> (Int, String, String) {
      calls = calls + 1
      if calls == 1 {
        ignore(@fs.exists(p.stage_dir))
        (9, "", "first failed")
      } else {
        write_gen_stub(p)
        (0, "", "")
      }
    }

    let outcome = stage_validate_promote(
      plan,
      produce~,
      confine=allow_gen_stage,
    )
    guard outcome is Promoted(report) else {
      abort("second attempt was not promoted")
    }
    assert_true(report.ok())
    assert_eq(calls, 2)
    assert_true(@fs.exists("\{plan.deck_dir}/deck.html"))
  }
}

///|
/// Advisory-only validation findings still promote and remain attached to the
/// outcome for the CLI to render later.
async test "stage_validate_promote preserves warnings on promotion" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-stage-warning")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let plan = gen_stub_plan(root)
    async fn produce(p : GenPlan) -> (Int, String, String) {
      write_gen_stub(p, entry="1")
      (0, "", "")
    }

    let outcome = stage_validate_promote(
      plan,
      produce~,
      confine=allow_gen_stage,
    )
    guard outcome is Promoted(report) else {
      abort("warning-only bundle was not promoted")
    }
    assert_true(report.ok())
    json_inspect(report.codes(), content=["prov.untagged_number"])
  }
}

///|
/// A producer cannot swap the stage root for a symlink and publish its target:
/// validation may read the target under the current residual policy, but the
/// pre-promotion no-follow kind assertion blocks the rename.
async test "stage_validate_promote rejects a swapped stage-root symlink" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-stage-swap")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let plan = gen_stub_plan(root)
    let target_plan = GenPlan::{ ..plan, stage_dir: "\{root}/outside" }
    @fs.mkdir(target_plan.stage_dir)
    write_gen_stub(target_plan)
    async fn produce(p : GenPlan) -> (Int, String, String) {
      @fs.rmdir(p.stage_dir, recursive=true)
      @fs.symlink(p.stage_dir, target=target_plan.stage_dir)
      (0, "", "")
    }

    let outcome = stage_validate_promote(
      plan,
      produce~,
      confine=allow_gen_stage,
    )
    guard outcome is ExecFailed(message) else {
      abort("swapped stage symlink was not blocked")
    }
    assert_eq(message, "stage root is not a directory")
    assert_false(@fs.exists(plan.deck_dir))
    assert_true(@fs.exists("\{target_plan.stage_dir}/deck.html"))
  }
}

///|
/// The confinement tripwire compares tracked-status entries outside `decks/`
/// against its pre-run baseline. An unchanged dirty file is tolerated, while a
/// new change, a disappeared baseline change, or a status transition is named;
/// generated-deck changes and untracked records are outside this best-effort
/// signal.
test "changed_tracked_paths diffs outside-deck status against baseline" {
  let before = " M unchanged.txt\u{0} M removed.txt\u{0} M transition.txt\u{0} M decks/proj/deck.html\u{0}"
  let after = " M unchanged.txt\u{0} M added name.txt\u{0}M  transition.txt\u{0} D decks/proj/deck.html\u{0}?? untracked.txt\u{0}"
  json_inspect(changed_tracked_paths(before, after), content=[
    "added name.txt", "removed.txt", "transition.txt",
  ])
}

///|
/// Porcelain-v1 `-z` emits a rename/copy's destination and source as adjacent
/// NUL records. Both paths belong to one status entry: an all-decks rename is
/// allowed, while a rename crossing the boundary reports only its outside path.
test "changed_tracked_paths parses nul rename records without path quoting" {
  let after = "R  decks/proj/new.html\u{0}source old.html\u{0}R  decks/proj/newer.html\u{0}decks/proj/older.html\u{0}"
  json_inspect(changed_tracked_paths("", after), content=["source old.html"])
}

///|
/// Exercise the real porcelain command over a temporary Git repo: the clean
/// baseline is empty, a tracked source edit appears, a tracked deck edit is
/// filtered by the boundary rule, and an untracked write is omitted at capture.
async test "tracked_git_status captures only relevant tracked changes" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-git-status")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    @fs.mkdir("\{root}/decks/proj", recursive=true)
    @fs.write_file(
      "\{root}/source.txt",
      "before\n",
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{root}/decks/proj/deck.html",
      "before\n",
      create_mode=CreateOrTruncate,
    )
    let (init_code, _, _) = @process.collect_output(
      "git",
      ["init", "-q"],
      cwd=root,
    )
    assert_eq(init_code, 0)
    let (add_code, _, _) = @process.collect_output(
      "git",
      ["add", "source.txt", "decks/proj/deck.html"],
      cwd=root,
    )
    assert_eq(add_code, 0)
    let (commit_code, _, _) = @process.collect_output(
      "git",
      [
        "-c", "user.name=slide-gen test", "-c", "user.email=slide-gen@example.invalid",
        "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit",
        "-qm", "fixture",
      ],
      cwd=root,
    )
    assert_eq(commit_code, 0)
    guard tracked_git_status(root) is Some(before) else {
      abort("clean git baseline capture failed")
    }
    assert_eq(before, "")
    @fs.write_file(
      "\{root}/source.txt",
      "after\n",
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{root}/decks/proj/deck.html",
      "after\n",
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{root}/untracked.txt",
      "ignored\n",
      create_mode=CreateOrTruncate,
    )
    guard tracked_git_status(root) is Some(after) else {
      abort("dirty git status capture failed")
    }
    json_inspect(changed_tracked_paths(before, after), content=["source.txt"])
  }
}

///|
/// CLI outcome rendering is a pure, stable boundary: promotion prints the
/// mandatory-file manifest plus advisory findings and exits zero; retained
/// blocking reports and producer failures preserve their diagnostics and exit
/// one, with exactly one final newline.
test "render_outcome maps promote retain and exec failure" {
  let (promoted_message, promoted_code) = render_outcome(
    Promoted(Report::{
      findings: [should("prov.untagged_number", "number needs a citation")],
    }),
  )
  inspect(
    "\{promoted_code}|\{promoted_message}",
    content=(
      #|0|generated: deck.html, provenance.json, gaps.md
      #|[SHOULD] prov.untagged_number: number needs a citation
      #|
    ),
  )
  let (retained_message, retained_code) = render_outcome(
    Retained(Report::{ findings: [must("deck.missing", "deck absent")] }),
  )
  inspect(
    "\{retained_code}|\{retained_message}",
    content=(
      #|1|[MUST] deck.missing: deck absent
      #|
    ),
  )
  let (failed_message, failed_code) = render_outcome(
    ExecFailed("codex failed\n"),
  )
  inspect(
    "\{failed_code}|\{failed_message}",
    content=(
      #|1|codex failed
      #|
    ),
  )
}
