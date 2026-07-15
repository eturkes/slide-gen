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
/// Prompt composition appends authoritative runtime values and embeds the whole
/// style contract after the tracked static policy. This small synthetic input
/// keeps the boundary exact without snapshotting the shipped multi-kilobyte
/// prompt/template pair.
test "build_prompt composes contract runtime inputs and embedded style" {
  let plan = plan_generate("/w/Projects/slide-gen", "projA")
  let out = build_prompt(
    plan, "CONTRACT MARKER\n", "<html>STYLE MARKER</html>\n",
  )
  assert_true(out.has_prefix("CONTRACT MARKER\n\n## Runtime inputs\n"))
  assert_true(out.contains("- Project slug: `projA`\n"))
  assert_true(out.contains("- Source project: `/w/Projects/projA`\n"))
  assert_true(
    out.contains(
      "- Stage directory (the only durable write root): `/w/Projects/slide-gen/decks/.partial/projA`\n",
    ),
  )
  assert_true(
    out.has_suffix(
      "<deck-style-contract>\n<html>STYLE MARKER</html>\n</deck-style-contract>\n",
    ),
  )
}

///|
/// Plan joins stay canonical at the filesystem root and past trailing slashes,
/// and the pure dry-run renderer shell-quotes only the spaced cwd argv element.
test "generation plan and dry-run paths stay canonical" {
  let at_root = plan_generate("/slide-gen", "projA")
  assert_eq(at_root.root, "/slide-gen")
  assert_eq(at_root.cwd, "/")
  assert_eq(at_root.source_dir, "/projA")
  assert_eq(at_root.template, "/slide-gen/templates/deck.html")
  assert_eq(at_root.prompt_contract, "/slide-gen/templates/deck-prompt.md")
  assert_eq(at_root.furigana_tool, "/slide-gen/tools/furigana_check.py")
  assert_eq(at_root.stage_dir, "/slide-gen/decks/.partial/projA")
  let trailing = plan_generate("/w/Projects/slide-gen/", "projA")
  assert_eq(trailing.template, "/w/Projects/slide-gen/templates/deck.html")
  assert_eq(
    trailing.prompt_contract,
    "/w/Projects/slide-gen/templates/deck-prompt.md",
  )
  assert_eq(trailing.stage_dir, "/w/Projects/slide-gen/decks/.partial/projA")
  let spaced = plan_generate("/w/My Projects/slide-gen", "projA")
  let shown = render_dry_run_text(spaced, "prompt\n", 900)
  assert_true(shown.contains("-C '/w/My Projects'\n"))
  assert_true(
    shown.contains(
      "post:      uv run --locked --no-dev python '/w/My Projects/slide-gen/tools/furigana_check.py' '/w/My Projects/slide-gen/decks/.partial/projA'\n",
    ),
  )
  assert_true(shown.contains("cwd:       /w/My Projects\n"))
  assert_false(shown.has_suffix("\n\n"))
}

///|
/// The analyzer command is uv-locked, excludes development-only Ruff, and
/// receives the helper and stage as direct argv elements (never shell text).
test "build_furigana_argv pins the authoring sidecar boundary" {
  let plan = plan_generate("/w/Projects/slide-gen", "projA")
  json_inspect(build_furigana_argv(plan), content=[
    "uv", "run", "--locked", "--no-dev", "python", "/w/Projects/slide-gen/tools/furigana_check.py",
    "/w/Projects/slide-gen/decks/.partial/projA",
  ])
}

///|
/// A missing tracked prompt/template fails before a Codex process can start and
/// returns the producer diagnostic shape consumed by the retry orchestrator.
async test "run_codex reports prompt load failure before execution" {
  let plan = plan_generate("/definitely/missing/slide-gen", "projA")
  let (code, stdout, stderr) = run_codex(plan)
  assert_eq(code, 1)
  assert_eq(stdout, "")
  assert_true(stderr.has_prefix("prompt load failed:"))
}

///|
/// The real uv sidecar runs against a staged controlled deck and converts a
/// wrong common-word reading into a non-blocking structured gaps.md entry.
async test "run_furigana executes the locked analyzer against the stage" {
  guard find_repo_root() is Some(source_root) else { return }
  @async.with_task_group() <| group => {
    let tmp = @fs.tmpdir(prefix="slide-gen-furigana")
    group.add_defer(() => @fs.rmdir(tmp, recursive=true))
    let plan = GenPlan::{
      ..gen_stub_plan(tmp),
      root: source_root,
      furigana_tool: "\{source_root}/tools/furigana_check.py",
    }
    @fs.mkdir(plan.stage_dir, recursive=true)
    @fs.write_file(
      "\{plan.stage_dir}/deck.html",
      "<!doctype html><html lang=\"ja\"><body><div class=\"jp\">学校です。</div><div class=\"jpf\"><ruby>学校<rt>がくこう</rt></ruby>です。</div></body></html>\n",
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{plan.stage_dir}/gaps.md",
      "no gaps\n",
      create_mode=CreateOrTruncate,
    )
    let (code, error) = run_furigana(plan)
    assert_eq(code, 0, msg=error)
    assert_eq(error, "")
    let gaps = @fs.read_file("\{plan.stage_dir}/gaps.md").text()
    assert_true(gaps.contains("furigana-check:start"))
    assert_true(gaps.contains("codex-reading: \"がくこう\""))
    assert_true(gaps.contains("analyzer-reading: \"がっこう\""))
  }
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
    root,
    cwd: root,
    source_dir: "\{root}/\{project}",
    template: "\{root}/template.html",
    prompt_contract: "\{root}/deck-prompt.md",
    furigana_tool: "\{root}/tools/furigana_check.py",
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
/// Passing postprocessor seam for orchestration tests that do not exercise uv.
async fn pass_gen_postprocess(plan : GenPlan) -> (Int, String) {
  ignore(@fs.exists(plan.stage_dir))
  (0, "")
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
      postprocess=pass_gen_postprocess,
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
    let mut post_calls = 0
    async fn produce(p : GenPlan) -> (Int, String, String) {
      calls = calls + 1
      ignore(@fs.exists(p.stage_dir))
      (0, "", "")
    }

    async fn postprocess(p : GenPlan) -> (Int, String) {
      post_calls = post_calls + 1
      ignore(@fs.exists(p.stage_dir))
      (0, "")
    }

    let outcome = stage_validate_promote(
      plan,
      produce~,
      postprocess~,
      confine=allow_gen_stage,
    )
    guard outcome is Retained(report) else {
      abort("invalid stub was not retained")
    }
    json_inspect(report.codes(), content=["deck.missing"])
    assert_eq(calls, 2)
    assert_eq(post_calls, 0)
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
      postprocess=pass_gen_postprocess,
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
/// A broken postprocessor consumes the retry budget and blocks validation and
/// publication even when Codex produced a validator-clean bundle.
async test "stage_validate_promote reports postprocessor failure" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-stage-post")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let plan = gen_stub_plan(root)
    let mut calls = 0
    async fn produce(p : GenPlan) -> (Int, String, String) {
      write_gen_stub(p)
      (0, "", "")
    }

    async fn postprocess(p : GenPlan) -> (Int, String) {
      calls = calls + 1
      ignore(@fs.exists(p.stage_dir))
      (8, "furigana check failed")
    }

    let outcome = stage_validate_promote(
      plan,
      produce~,
      postprocess~,
      confine=allow_gen_stage,
    )
    guard outcome is ExecFailed(message) else {
      abort("postprocessor failure was not reported")
    }
    assert_eq(message, "furigana check failed")
    assert_eq(calls, 2)
    assert_true(@fs.exists("\{plan.stage_dir}/deck.html"))
    assert_false(@fs.exists(plan.deck_dir))
  }
}

///|
/// A zero-exit postprocessor still cannot bypass the deterministic bundle gate:
/// its malformed gaps rewrite is caught by the final validation pass and retained.
async test "stage_validate_promote revalidates postprocessor writes" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-stage-post-invalid")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let plan = gen_stub_plan(root)
    async fn produce(p : GenPlan) -> (Int, String, String) {
      write_gen_stub(p)
      (0, "", "")
    }

    async fn postprocess(p : GenPlan) -> (Int, String) {
      @fs.write_file(
        "\{p.stage_dir}/gaps.md",
        "opaque prose\n",
        create_mode=CreateOrTruncate,
      )
      (0, "")
    }

    let outcome = stage_validate_promote(
      plan,
      produce~,
      postprocess~,
      confine=allow_gen_stage,
      retries=0,
    )
    guard outcome is Retained(report) else {
      abort("invalid postprocessor rewrite was not retained")
    }
    json_inspect(report.codes(), content=["gaps.empty"])
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

    let outcome = stage_validate_promote(
      plan,
      produce~,
      postprocess=pass_gen_postprocess,
      confine~,
    )
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
      postprocess=pass_gen_postprocess,
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
      postprocess=pass_gen_postprocess,
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
      postprocess=pass_gen_postprocess,
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
