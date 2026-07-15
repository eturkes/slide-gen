// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Unwrap a valid render plan in compact test fixtures.
fn test_render_plan(root : String, project : String) -> RenderPlan {
  match plan_render(root, project) {
    Some(plan) => plan
    None => abort("expected valid render plan")
  }
}

///|
/// Validator-clean static deck fixture with an arbitrary positive slide count.
/// It uses no assets, claims, or kanji so render tests stay focused on the
/// browser boundary.
fn render_test_deck(project : String, page_count : Int) -> String {
  let out = StringBuilder::new()
  out.write_string(
    "<!doctype html>\n<html lang=\"ja\">\n<head><meta charset=\"utf-8\"><style>body{}</style></head>\n<body>\n",
  )
  for page in 1..<=page_count {
    out.write_string(
      "<section class=\"slide\"><div class=\"eyebrow\"><span class=\"n\">\{two_digit(page)}</span><span>label</span></div><div class=\"entry\"><div class=\"jp\">a</div><div class=\"jpf\">a</div><div class=\"en\">a</div></div><div class=\"pageno\">\{project} \u{b7} \{page} / \{page_count}</div></section>\n",
    )
  }
  out.write_string("</body>\n</html>\n")
  out.to_string()
}

///|
/// Small browser-DOM fixture whose only real slides are the requested balanced
/// section.slide elements.
fn render_test_dom(page_count : Int) -> String {
  let out = StringBuilder::new()
  out.write_string("<html><head></head><body>")
  for _ in 0..<page_count {
    out.write_string("<section class=\"slide\"></section>")
  }
  out.write_string("</body></html>")
  out.to_string()
}

///|
/// Seed one real no-follow bundle directory and deck.html.
async fn write_render_test_deck(plan : RenderPlan, html : String) -> Unit {
  if !is_real_directory_no_follow(plan.bundle_dir) {
    @fs.mkdir(plan.bundle_dir, recursive=true)
  }
  @fs.write_file(plan.deck_path, html, create_mode=CreateOrTruncate)
}

///|
/// Compact injected command result fixture.
fn render_command_result(
  code : Int,
  stdout? : String = "",
  stderr? : String = "",
) -> RenderCommandResult {
  RenderCommandResult::{ code, stdout, stderr }
}

///|
/// Feed preflight a finite response queue while recording every exact argv. An
/// unexpected extra process aborts immediately; an early filesystem/validator
/// failure consumes an intentionally empty queue.
async fn queued_render_preflight(
  plan : RenderPlan,
  responses : Array[RenderCommandResult],
  calls : Array[Array[String]],
  timeout_secs? : Int = 5,
) -> RenderPreflightOutcome {
  let mut next = 0
  async fn run(argv : Array[String]) -> RenderCommandResult {
    ignore(@fs.exists(plan.bundle_dir))
    calls.push(argv)
    guard next < responses.length() else {
      abort("render preflight issued an unexpected process")
    }
    let response = responses[next]
    next = next + 1
    response
  }

  let outcome = preflight_render_with(plan, run~, timeout_secs~)
  assert_eq(next, responses.length())
  outcome
}

///|
/// Unwrap the expected controlled-failure branch.
fn render_preflight_failure(outcome : RenderPreflightOutcome) -> RenderFailure {
  match outcome {
    PreflightFailed(failure) => failure
    PreflightReady(_) => abort("expected render preflight failure")
  }
}

///|
/// Establish the exact fresh-stage contract normally produced by preflight,
/// without spawning its browser/font/DOM commands.
async fn fresh_render_context(
  plan : RenderPlan,
  page_count : Int,
) -> RenderContext {
  recreate_stage(plan.publication())
  @fs.mkdir(plan.input_dir)
  @fs.write_file(
    plan.input_deck_path,
    render_test_deck(plan.project, page_count),
    create_mode=CreateOrTruncate,
  )
  @fs.mkdir(plan.profile_dir)
  RenderContext::{ plan, browser: "/stub/chrome", page_count }
}

///|
/// Unwrap the expected controlled raster-failure branch.
fn render_raster_failure(outcome : RenderRasterOutcome) -> RenderFailure {
  match outcome {
    RasterFailed(failure) => failure
    RasterReady(_) => abort("expected render raster failure")
  }
}

///|
/// Unwrap the expected controlled final-render failure branch.
fn final_render_failure(outcome : RenderOutcome) -> RenderFailure {
  match outcome {
    RenderFailed(failure) => failure
    RenderPublished(_) => abort("expected final render failure")
  }
}

///|
/// The shared advisory lease rejects a second owner for the same project,
/// permits an independent project, and becomes available again on release.
async test "project operation locks serialize one key without blocking others" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-project-operation-lock")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let raced_dir = "\{root}/first-use"
    let first_create = group.spawn(() => ensure_real_dir(raced_dir))
    let second_create = group.spawn(() => ensure_real_dir(raced_dir))
    first_create.wait()
    second_create.wait()
    assert_true(is_real_directory_no_follow(raced_dir))
    async fn hold_and_contend() -> Unit {
      let first = match acquire_project_operation_lock(root, "project") {
        ProjectOperationLocked(file) => file
        ProjectOperationBusy =>
          abort("first project lock was unexpectedly busy")
        ProjectOperationLockFailed(error) =>
          abort("first project lock failed: \{error}")
      }
      defer first.close()
      defer first.unlock()
      assert_true(
        acquire_project_operation_lock(root, "project") is ProjectOperationBusy,
      )
      let other = match acquire_project_operation_lock(root, "other") {
        ProjectOperationLocked(file) => file
        ProjectOperationBusy => abort("independent project lock was busy")
        ProjectOperationLockFailed(error) =>
          abort("independent project lock failed: \{error}")
      }
      defer other.close()
      defer other.unlock()
    }

    hold_and_contend()
    let reacquired = match acquire_project_operation_lock(root, "project") {
      ProjectOperationLocked(file) => file
      ProjectOperationBusy => abort("released project lock stayed busy")
      ProjectOperationLockFailed(error) =>
        abort("released project lock failed: \{error}")
    }
    defer reacquired.close()
    defer reacquired.unlock()
    let outside = "\{root}/outside-lock-target"
    @fs.write_file(outside, "untouched", create_mode=CreateOrTruncate)
    @fs.symlink("\{root}/renders/.locks/forged.lock", target=outside)
    guard acquire_project_operation_lock(root, "forged")
      is ProjectOperationLockFailed(error) else {
      abort("forged lock leaf was accepted")
    }
    assert_true(error.contains("not a regular file"))
    assert_eq(@fs.read_file(outside).text(), "untouched")
  }
}

///|
/// Seed the browser-clean page-only stage handed from rasterization to M3.3.
async fn ready_render_pages(plan : RenderPlan, page_count : Int) -> RenderPages {
  recreate_stage(plan.publication())
  let paths : Array[String] = []
  for page in 1..<=page_count {
    guard render_page_path(plan, page) is Some(path) else {
      abort("missing ready page path")
    }
    @fs.write_file(path, valid_png_header(), create_mode=CreateOrTruncate)
    paths.push(path)
  }
  RenderPages::{ plan, paths }
}

///|
/// Seed the prior published render that every failing completion path must keep.
async fn seed_old_render(plan : RenderPlan) -> String {
  @fs.mkdir(plan.live_dir, recursive=true)
  let sentinel = "\{plan.live_dir}/sentinel"
  @fs.write_file(sentinel, "old", create_mode=CreateOrTruncate)
  sentinel
}

///|
/// Split one Poppler output line without depending on its aligned spacing.
fn whitespace_fields(line : String) -> Array[String] {
  let fields : Array[String] = []
  for field in line.split(" ") {
    if !field.is_empty() {
      fields.push(field.to_owned())
    }
  }
  fields
}

///|
/// Parse Poppler's whitespace table into only numbered image rows. Header and
/// separator lines remain ignored without pinning column spacing.
fn poppler_image_rows(output : String) -> Array[Array[String]] {
  let rows : Array[Array[String]] = []
  for line in output.split("\n") {
    let fields = whitespace_fields(line.to_owned())
    if fields.length() >= 14 && parse_int(fields[0]) is Some(_) {
      rows.push(fields)
    }
  }
  rows
}

///|
/// Parse every per-page MediaBox row from `pdfinfo -box` output.
fn poppler_media_boxes(output : String) -> Array[Array[String]] {
  let rows : Array[Array[String]] = []
  for line in output.split("\n") {
    let fields = whitespace_fields(line.to_owned())
    if fields.length() >= 7 && fields[0] == "Page" && fields[2] == "MediaBox:" {
      rows.push(fields)
    }
  }
  rows
}

///|
/// The direct-child policy rejects traversal/reserved dot names and the shared
/// unrepresentable classes while retaining ordinary internal punctuation,
/// spaces, quotes, and non-ASCII.
test "render project names stay direct and outside reserved dot roots" {
  assert_true(valid_render_project("simple"))
  assert_true(valid_render_project("a.b quote's 道"))
  assert_false(valid_render_project(""))
  assert_false(valid_render_project("."))
  assert_false(valid_render_project(".."))
  assert_false(valid_render_project(".partial"))
  assert_false(valid_render_project(".previous"))
  assert_false(valid_render_project(".hidden/project"))
  assert_false(valid_render_project("-option"))
  assert_false(valid_render_project(" trailing "))
  assert_false(plan_render("relative/root", "project") is Some(_))
}

///|
/// Plan arithmetic is canonical at filesystem root and after trailing slashes;
/// all browser-only paths stay under the reserved render stage.
test "render plan paths cover filesystem root and exotic direct children" {
  let root = test_render_plan("/", "quo'te 道")
  assert_eq(root.root, "/")
  assert_eq(root.bundle_dir, "/decks/quo'te 道")
  assert_eq(root.deck_path, "/decks/quo'te 道/deck.html")
  assert_eq(root.stage_dir, "/renders/.partial/quo'te 道")
  assert_eq(root.backup_dir, "/renders/.previous/quo'te 道")
  assert_eq(root.live_dir, "/renders/quo'te 道")
  assert_eq(root.input_dir, "/renders/.partial/quo'te 道/.render-input")
  assert_eq(
    root.input_deck_path,
    "/renders/.partial/quo'te 道/.render-input/deck.html",
  )
  assert_eq(
    root.input_assets_dir,
    "/renders/.partial/quo'te 道/.render-input/assets",
  )
  assert_eq(root.profile_dir, "/renders/.partial/quo'te 道/.chromium-profile")
  assert_eq(root.wrapper_path, "/renders/.partial/quo'te 道/.page.html")
  assert_eq(root.pdf_path, "/renders/.partial/quo'te 道/deck.pdf")
  let trailing = test_render_plan("/w/slide-gen///", "a.b")
  assert_eq(trailing.root, "/w/slide-gen")
  assert_eq(trailing.deck_path, "/w/slide-gen/decks/a.b/deck.html")
  assert_eq(trailing.live_dir, "/w/slide-gen/renders/a.b")
}

///|
/// File URLs encode UTF-8 bytes and every URI delimiter while preserving path
/// separators; attribute escaping independently covers all HTML delimiters.
test "file URL and HTML attribute escaping are byte exact" {
  inspect(file_url("/").unwrap_or("<invalid>"), content="file:///")
  inspect(
    file_url("/w/My \"quote's\" 道/%#?&.html").unwrap_or("<invalid>"),
    content="file:///w/My%20%22quote%27s%22%20%E9%81%93/%25%23%3F%26.html",
  )
  assert_true(file_url("relative") is None)
  inspect(
    escape_html_attr("a&<b>\"c'd 道"),
    content="a&amp;&lt;b&gt;&quot;c&#39;d 道",
  )
}

///|
/// Wrapper geometry selects one page from an exact-height iframe, and its URL
/// remains inert with spaces, quotes, and non-ASCII path bytes.
test "fixed page wrapper has exact geometry and escaped file URL" {
  let plan = test_render_plan("/w/My Root", "quo\"te 道")
  inspect(
    render_page_wrapper(plan, 2, 12).unwrap_or("<invalid>"),
    content=(
      #|<!doctype html>
      #|<html lang="en">
      #|<head>
      #|<meta charset="utf-8">
      #|<style>
      #|*{box-sizing:border-box}
      #|html,body{margin:0;width:2560px;height:1440px;overflow:hidden;background:#fff}
      #|iframe{position:absolute;left:0;top:-1440px;width:2560px;height:17280px;border:0}
      #|</style>
      #|</head>
      #|<body><iframe title="slide page 2" src="file:///w/My%20Root/renders/.partial/quo%22te%20%E9%81%93/.render-input/deck.html" scrolling="no"></iframe></body>
      #|</html>
      #|
    ),
  )
  assert_true(render_page_wrapper(plan, 1, 1) is Some(_))
  assert_true(render_page_wrapper(plan, 0, 1) is None)
  assert_true(render_page_wrapper(plan, 2, 1) is None)
  assert_true(render_page_wrapper(plan, 1, 0) is None)
  assert_true(render_page_wrapper(plan, 1, 100) is None)
}

///|
/// Two-digit page names are total only across the bounded render range.
test "page artifact names cover 01 through 99" {
  inspect(render_page_name(1).unwrap_or("<invalid>"), content="page_01.png")
  inspect(render_page_name(9).unwrap_or("<invalid>"), content="page_09.png")
  inspect(render_page_name(10).unwrap_or("<invalid>"), content="page_10.png")
  inspect(render_page_name(99).unwrap_or("<invalid>"), content="page_99.png")
  assert_true(render_page_name(0) is None)
  assert_true(render_page_name(100) is None)
}

///|
/// Browser argv pins viewport/DSF, an isolated profile, and the dead-network
/// route; per-action suffixes preserve exotic paths as single argv elements.
test "Chromium DOM and screenshot argv are exact and bounded" {
  let plan = test_render_plan("/w/My Root", "rehab's 道")
  json_inspect(
    build_dump_dom_argv(plan, "/opt/Chromium Fish/chrome", timeout_secs=45).unwrap_or([],
    ),
    content=[
      "timeout", "--kill-after=30", "45", "/opt/Chromium Fish/chrome", "--headless=new",
      "--disable-field-trial-config", "--disable-breakpad", "--no-sandbox", "--disable-gpu",
      "--force-device-scale-factor=1", "--window-size=2560,1440", "--hide-scrollbars",
      "--user-data-dir=/w/My Root/renders/.partial/rehab's 道/.chromium-profile",
      "--proxy-server=http://127.0.0.1:9", "--proxy-bypass-list=<-loopback>", "--host-resolver-rules=MAP * ~NOTFOUND",
      "--disable-background-networking", "--disable-component-update", "--disable-default-apps",
      "--disable-sync", "--metrics-recording-only", "--no-first-run", "--dump-dom",
      "file:///w/My%20Root/renders/.partial/rehab%27s%20%E9%81%93/.render-input/deck.html",
    ],
  )
  let screenshot = build_screenshot_argv(
    plan,
    "/opt/chrome",
    10,
    timeout_secs=0,
  ).unwrap_or([])
  assert_eq(screenshot[2], default_render_timeout_secs.to_string())
  assert_eq(
    screenshot[screenshot.length() - 2],
    "--screenshot=/w/My Root/renders/.partial/rehab's 道/page_10.png",
  )
  assert_eq(
    screenshot[screenshot.length() - 1],
    "file:///w/My%20Root/renders/.partial/rehab%27s%20%E9%81%93/.page.html",
  )
  assert_true(build_screenshot_argv(plan, "/opt/chrome", 0) is None)
}

///|
/// Bundle and deck entries must be real no-follow filesystem objects, and both
/// unsafe markup and ordinary structural defects stop before tool resolution.
async test "render preflight rejects unsafe input before every process" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-render-input")
    group.add_defer(() => @fs.rmdir(root, recursive=true))

    let missing = test_render_plan(root, "missing")
    let calls : Array[Array[String]] = []
    let failure = render_preflight_failure(
      queued_render_preflight(missing, [], calls),
    )
    assert_eq(failure.code, "render.deck.directory")
    assert_eq(calls.length(), 0)

    let linked = test_render_plan(root, "linked")
    let outside = "\{root}/outside"
    @fs.mkdir(outside)
    @fs.mkdir(split_path(linked.bundle_dir).0, recursive=true)
    @fs.symlink(linked.bundle_dir, target=outside)
    let linked_calls : Array[Array[String]] = []
    let linked_failure = render_preflight_failure(
      queued_render_preflight(linked, [], linked_calls),
    )
    assert_eq(linked_failure.code, "render.deck.directory")
    assert_eq(linked_calls.length(), 0)

    let linked_file = test_render_plan(root, "linked-file")
    @fs.mkdir(linked_file.bundle_dir)
    let outside_deck = "\{root}/outside-deck.html"
    @fs.write_file(
      outside_deck,
      render_test_deck(linked_file.project, 1),
      create_mode=CreateOrTruncate,
    )
    @fs.symlink(linked_file.deck_path, target=outside_deck)
    let file_calls : Array[Array[String]] = []
    let file_failure = render_preflight_failure(
      queued_render_preflight(linked_file, [], file_calls),
    )
    assert_eq(file_failure.code, "render.deck.file")
    assert_eq(file_calls.length(), 0)

    let unsafe_plan = test_render_plan(root, "unsafe")
    let unsafe_html = render_test_deck(unsafe_plan.project, 1).replace(
      old="<body>",
      new="<body><script>location='https://example.invalid'</script>",
    )
    write_render_test_deck(unsafe_plan, unsafe_html)
    let unsafe_calls : Array[Array[String]] = []
    let unsafe_failure = render_preflight_failure(
      queued_render_preflight(unsafe_plan, [], unsafe_calls),
    )
    assert_eq(unsafe_failure.code, "render.deck.invalid")
    assert_true(unsafe_failure.detail.contains("static.active_markup"))
    assert_eq(unsafe_calls.length(), 0)

    let invalid = test_render_plan(root, "invalid")
    let invalid_html = render_test_deck(invalid.project, 1).replace(
      old="class=\"entry\"",
      new="class=\"not-entry\"",
    )
    write_render_test_deck(invalid, invalid_html)
    let invalid_calls : Array[Array[String]] = []
    let invalid_failure = render_preflight_failure(
      queued_render_preflight(invalid, [], invalid_calls),
    )
    assert_eq(invalid_failure.code, "render.deck.invalid")
    assert_true(invalid_failure.detail.contains("slide.no_entry"))
    assert_eq(invalid_calls.length(), 0)
  }
}

///|
/// Tool resolution is ordered after deterministic deck validation. Bounded
/// timeout/hard-kill, a missing shim, an unusable path, a missing fontconfig
/// tool, and a fallback font each receive one stable failure class.
async test "render preflight classifies missing browser and font surfaces" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-render-tools")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let plan = test_render_plan(root, "project")
    write_render_test_deck(plan, render_test_deck(plan.project, 1))
    let browser = "\{root}/chrome"
    @fs.write_file(browser, "stub", create_mode=CreateOrTruncate)

    let missing_calls : Array[Array[String]] = []
    let missing = render_preflight_failure(
      queued_render_preflight(
        plan,
        [render_command_result(127, stderr="chromiumfish: not found")],
        missing_calls,
      ),
    )
    assert_eq(missing.code, "render.browser.resolve")
    assert_eq(missing_calls.length(), 1)

    let browser_timeout = render_preflight_failure(
      queued_render_preflight(plan, [render_command_result(137)], []),
    )
    assert_eq(browser_timeout.code, "render.browser.timeout")

    let bad_path_calls : Array[Array[String]] = []
    let bad_path = render_preflight_failure(
      queued_render_preflight(
        plan,
        [render_command_result(0, stdout="\{root}/missing-browser\n")],
        bad_path_calls,
      ),
    )
    assert_eq(bad_path.code, "render.browser.path")
    assert_eq(bad_path_calls.length(), 1)

    let font_tool_calls : Array[Array[String]] = []
    let font_tool = render_preflight_failure(
      queued_render_preflight(
        plan,
        [
          render_command_result(0, stdout="\{browser}\n"),
          render_command_result(127, stderr="fc-match: not found"),
        ],
        font_tool_calls,
      ),
    )
    assert_eq(font_tool.code, "render.font.resolve")
    assert_eq(font_tool_calls.length(), 2)

    let font_timeout = render_preflight_failure(
      queued_render_preflight(
        plan,
        [
          render_command_result(0, stdout="\{browser}\n"),
          render_command_result(124),
        ],
        [],
      ),
    )
    assert_eq(font_timeout.code, "render.font.timeout")

    let fallback_calls : Array[Array[String]] = []
    let fallback = render_preflight_failure(
      queued_render_preflight(
        plan,
        [
          render_command_result(0, stdout="\{browser}\n"),
          render_command_result(0, stdout="DejaVu Sans\n"),
        ],
        fallback_calls,
      ),
    )
    assert_eq(fallback.code, "render.font.missing")
    assert_eq(fallback_calls.length(), 2)
  }
}

///|
/// Passing preflight preserves exact tool/DOM argv, creates a real isolated
/// profile, and counts only genuine section.slide nodes: comment, attribute,
/// and wrong-tag class decoys remain inert.
async test "render preflight resolves a decoy-safe matching browser DOM" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-render-ready")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let plan = test_render_plan(root, "project")
    write_render_test_deck(plan, render_test_deck(plan.project, 1))
    let browser = "\{root}/chrome with space"
    @fs.write_file(browser, "stub", create_mode=CreateOrTruncate)
    let dom = "<!-- <section class=\"slide\"></section> --><div class=\"slide\"></div><p data-decoy=\"<section class='slide'>\"></p>" +
      render_test_dom(1)
    let calls : Array[Array[String]] = []
    let outcome = queued_render_preflight(
      plan,
      [
        render_command_result(0, stdout="\{browser}\n"),
        render_command_result(0, stdout="Noto Sans CJK JP\n"),
        render_command_result(0, stdout=dom),
      ],
      calls,
      timeout_secs=17,
    )
    guard outcome is PreflightReady(context) else {
      abort("matching DOM did not pass render preflight")
    }
    assert_eq(context.page_count, 1)
    assert_eq(context.browser, browser)
    assert_true(is_real_directory_no_follow(plan.profile_dir))
    json_inspect(calls[0], content=[
      "timeout", "--kill-after=30", "17", "chromiumfish", "path",
    ])
    json_inspect(calls[1], content=[
      "timeout", "--kill-after=30", "17", "fc-match", "--format=%{family}\\n", "Noto Sans CJK JP",
    ])
    assert_eq(calls[2][0], "timeout")
    assert_eq(calls[2][2], "17")
    assert_eq(calls[2][3], browser)
    assert_eq(calls[2][calls[2].length() - 2], "--dump-dom")
    assert_eq(calls[2][calls[2].length() - 1], "file://\{plan.input_deck_path}")
  }
}

///|
/// Source mutation after validation cannot substitute Chromium input: preflight
/// copies the deck and direct assets before resolving tools, validates that
/// snapshot, and points the DOM command only at the staged copy.
async test "render preflight snapshots browser input before external tools" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-render-snapshot")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let plan = test_render_plan(root, "project")
    let original = render_test_deck(plan.project, 1).replace(
      old="<div class=\"pageno\">",
      new="<img src=\"assets/chart.png\"><div class=\"pageno\">",
    )
    write_render_test_deck(plan, original)
    let source_assets = "\{plan.bundle_dir}/assets"
    @fs.mkdir(source_assets)
    let original_png = valid_png_header()
    @fs.write_file(
      "\{source_assets}/chart.png",
      original_png,
      create_mode=CreateOrTruncate,
    )
    let browser = "\{root}/chrome"
    @fs.write_file(browser, "stub", create_mode=CreateOrTruncate)
    let calls : Array[Array[String]] = []
    let mut next = 0
    async fn run(argv : Array[String]) -> RenderCommandResult {
      calls.push(argv)
      next = next + 1
      match next {
        1 => {
          @fs.write_file(
            plan.deck_path,
            render_test_deck(plan.project, 1).replace(
              old="<body>",
              new="<body><script>location='https://example.invalid'</script>",
            ),
            create_mode=CreateOrTruncate,
          )
          @fs.write_file(
            "\{source_assets}/chart.png",
            "changed",
            create_mode=CreateOrTruncate,
          )
          render_command_result(0, stdout="\{browser}\n")
        }
        2 => render_command_result(0, stdout="Noto Sans CJK JP\n")
        3 => render_command_result(0, stdout=render_test_dom(1))
        _ => abort("snapshot preflight issued an unexpected process")
      }
    }

    let outcome = preflight_render_with(plan, run~, timeout_secs=11)
    guard outcome is PreflightReady(context) else {
      abort("snapshotted preflight did not pass")
    }
    assert_eq(context.page_count, 1)
    assert_eq(next, 3)
    assert_eq(read_regular_text(plan.input_deck_path), Some(original))
    guard read_real_binary_no_follow("\{plan.input_assets_dir}/chart.png")
      is Some(snapshot_png) else {
      abort("snapshotted asset disappeared")
    }
    assert_true(snapshot_png == original_png)
    assert_true(@fs.read_file(plan.deck_path).text().contains("<script>"))
    assert_eq(@fs.read_file("\{source_assets}/chart.png").text(), "changed")
    assert_eq(
      calls[2][calls[2].length() - 1],
      file_url(plan.input_deck_path).unwrap_or("<invalid>"),
    )
  }
}

///|
/// Chromium nonzero/timeout/empty output, in-range parity drift, and an
/// over-limit DOM are distinct. A validator-clean 100-page source is rejected
/// before tools, proving both sides of the 1..=99 bound.
async test "render preflight classifies every DOM page-count failure" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-render-dom")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let plan = test_render_plan(root, "project")
    write_render_test_deck(plan, render_test_deck(plan.project, 1))
    let browser = "\{root}/chrome"
    @fs.write_file(browser, "stub", create_mode=CreateOrTruncate)

    let nonzero = render_preflight_failure(
      queued_render_preflight(
        plan,
        [
          render_command_result(0, stdout="\{browser}"),
          render_command_result(0, stdout="Noto Sans CJK JP"),
          render_command_result(7, stderr="browser failed"),
        ],
        [],
      ),
    )
    assert_eq(nonzero.code, "render.dom.exec")
    assert_eq(nonzero.detail, "browser failed")

    let timeout = render_preflight_failure(
      queued_render_preflight(
        plan,
        [
          render_command_result(0, stdout="\{browser}"),
          render_command_result(0, stdout="Noto Sans CJK JP"),
          render_command_result(124),
        ],
        [],
      ),
    )
    assert_eq(timeout.code, "render.dom.timeout")

    let empty = render_preflight_failure(
      queued_render_preflight(
        plan,
        [
          render_command_result(0, stdout="\{browser}"),
          render_command_result(0, stdout="Noto Sans CJK JP"),
          render_command_result(0, stdout=" \n\t"),
        ],
        [],
      ),
    )
    assert_eq(empty.code, "render.dom.empty")

    let mismatch = render_preflight_failure(
      queued_render_preflight(
        plan,
        [
          render_command_result(0, stdout="\{browser}"),
          render_command_result(0, stdout="Noto Sans CJK JP"),
          render_command_result(0, stdout=render_test_dom(2)),
        ],
        [],
      ),
    )
    assert_eq(mismatch.code, "render.dom.mismatch")
    assert_eq(mismatch.detail, "source deck has 1 pages but browser DOM has 2")

    let dom_over = render_preflight_failure(
      queued_render_preflight(
        plan,
        [
          render_command_result(0, stdout="\{browser}"),
          render_command_result(0, stdout="Noto Sans CJK JP"),
          render_command_result(0, stdout=render_test_dom(100)),
        ],
        [],
      ),
    )
    assert_eq(dom_over.code, "render.dom.page_count")

    write_render_test_deck(plan, render_test_deck(plan.project, 100))
    let source_calls : Array[Array[String]] = []
    let source_over = render_preflight_failure(
      queued_render_preflight(plan, [], source_calls),
    )
    assert_eq(source_over.code, "render.pages.source")
    assert_eq(source_calls.length(), 0)
  }
}

///|
/// A pre-existing raster makes the supposedly fresh stage unusable. Once
/// fresh, a page-two process failure stops the sequence immediately and cannot
/// touch the later PDF/publication surfaces.
async test "raster capture rejects stale output and stops on mid-page failure" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-render-raster-stop")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let plan = test_render_plan(root, "project")
    let stale_context = fresh_render_context(plan, 3)
    guard render_page_path(plan, 1) is Some(stale) else {
      abort("missing stale page path")
    }
    @fs.write_file(stale, valid_png_header(), create_mode=CreateOrTruncate)
    let mut stale_calls = 0
    async fn stale_run(_ : Array[String]) -> RenderCommandResult {
      ignore(@fs.exists(plan.stage_dir))
      stale_calls = stale_calls + 1
      render_command_result(0)
    }

    let stale_failure = render_raster_failure(
      capture_render_pages_with(stale_context, run=stale_run),
    )
    assert_eq(stale_failure.code, "render.raster.stage_dirty")
    assert_eq(stale_calls, 0)

    let context = fresh_render_context(plan, 3)
    @fs.mkdir(plan.live_dir, recursive=true)
    let sentinel = "\{plan.live_dir}/sentinel"
    @fs.write_file(sentinel, "old", create_mode=CreateOrTruncate)
    let calls : Array[Array[String]] = []
    let mut page = 0
    async fn run(argv : Array[String]) -> RenderCommandResult {
      calls.push(argv)
      page = page + 1
      if page == 1 {
        guard render_page_path(plan, page) is Some(output) else {
          abort("missing stub page path")
        }
        @fs.write_file(output, valid_png_header(), create_mode=CreateOrTruncate)
        render_command_result(0)
      } else {
        render_command_result(9, stderr="controlled page failure")
      }
    }

    let failure = render_raster_failure(
      capture_render_pages_with(context, run~, timeout_secs=7),
    )
    assert_eq(failure.code, "render.raster.exec")
    assert_true(failure.detail.contains("page 2"))
    assert_eq(calls.length(), 2)
    assert_eq(calls[0][2], "7")
    guard render_page_path(plan, 3) is Some(page_three) else {
      abort("missing page-three path")
    }
    assert_false(@fs.exists(page_three))
    assert_false(@fs.exists(plan.pdf_path))
    assert_eq(@fs.read_file(sentinel).text(), "old")

    let timeout_context = fresh_render_context(plan, 1)
    async fn hard_timeout(argv : Array[String]) -> RenderCommandResult {
      ignore(@fs.exists(argv[0]))
      render_command_result(137)
    }

    let timeout_failure = render_raster_failure(
      capture_render_pages_with(timeout_context, run=hard_timeout),
    )
    assert_eq(timeout_failure.code, "render.raster.timeout")
  }
}

///|
/// Direct-output and wrapper symlinks are rejected after a nominally successful
/// producer. The wrapper case proves stage-local markup cannot be redirected to
/// an outside file between materialization and browser completion.
async test "raster capture rejects symlink page and wrapper forgery" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-render-raster-forge")
    group.add_defer(() => @fs.rmdir(root, recursive=true))

    let page_plan = test_render_plan(root, "page-link")
    let page_context = fresh_render_context(page_plan, 1)
    let outside_png = "\{root}/outside.png"
    @fs.write_file(
      outside_png,
      valid_png_header(),
      create_mode=CreateOrTruncate,
    )
    async fn link_page(_ : Array[String]) -> RenderCommandResult {
      guard render_page_path(page_plan, 1) is Some(output) else {
        abort("missing linked page path")
      }
      @fs.symlink(output, target=outside_png)
      render_command_result(0)
    }

    let page_failure = render_raster_failure(
      capture_render_pages_with(page_context, run=link_page),
    )
    assert_eq(page_failure.code, "render.raster.output")

    let wrapper_plan = test_render_plan(root, "wrapper-link")
    let wrapper_context = fresh_render_context(wrapper_plan, 1)
    let outside_wrapper = "\{root}/outside.html"
    @fs.write_file(
      outside_wrapper,
      render_page_wrapper(wrapper_plan, 1, 1).unwrap_or(""),
      create_mode=CreateOrTruncate,
    )
    async fn link_wrapper(_ : Array[String]) -> RenderCommandResult {
      remove_entry_no_follow(wrapper_plan.wrapper_path)
      @fs.symlink(wrapper_plan.wrapper_path, target=outside_wrapper)
      render_command_result(0)
    }

    let wrapper_failure = render_raster_failure(
      capture_render_pages_with(wrapper_context, run=link_wrapper),
    )
    assert_eq(wrapper_failure.code, "render.wrapper.forged")
  }
}

///|
/// A 12-page injected producer observes the exact escaped wrapper on every
/// call. Ready paths remain numeric across the 09/10 boundary and successful
/// cleanup leaves only the validated PNG set.
async test "raster capture materializes escaped wrappers and orders page ten" {
  @async.with_task_group() <| group => {
    let tmp = @fs.tmpdir(prefix="slide-gen-render-raster-order")
    group.add_defer(() => @fs.rmdir(tmp, recursive=true))
    let root = "\{tmp}/My Root"
    @fs.mkdir(root)
    let plan = test_render_plan(root, "quo\"te 道")
    let context = fresh_render_context(plan, 12)
    let calls : Array[Array[String]] = []
    let mut page = 0
    async fn run(argv : Array[String]) -> RenderCommandResult {
      calls.push(argv)
      page = page + 1
      guard read_regular_text(plan.wrapper_path) is Some(actual) else {
        abort("stub could not read page wrapper")
      }
      assert_eq(
        actual,
        render_page_wrapper(plan, page, 12).unwrap_or("<invalid>"),
      )
      guard render_page_path(plan, page) is Some(output) else {
        abort("missing ordered stub page path")
      }
      assert_eq(argv[argv.length() - 2], "--screenshot=\{output}")
      @fs.write_file(output, valid_png_header(), create_mode=CreateOrTruncate)
      render_command_result(0)
    }

    let outcome = capture_render_pages_with(context, run~)
    guard outcome is RasterReady(pages) else {
      abort("12-page injected raster did not pass")
    }
    assert_eq(calls.length(), 12)
    assert_eq(pages.paths.length(), 12)
    assert_true(pages.paths[8].has_suffix("/page_09.png"))
    assert_true(pages.paths[9].has_suffix("/page_10.png"))
    assert_true(pages.paths[11].has_suffix("/page_12.png"))
    assert_true(
      calls[0][calls[0].length() - 1].contains(
        "quo%22te%20%E9%81%93/.page.html",
      ),
    )
    assert_false(@fs.exists(plan.wrapper_path))
    assert_false(@fs.exists(plan.profile_dir))
    assert_false(@fs.exists(plan.input_dir))
    assert_false(@fs.exists(plan.pdf_path))
    assert_eq(@fs.readdir(plan.stage_dir, include_hidden=true).length(), 12)
  }
}

///|
/// A producer-created stale extra page survives neither cleanup nor the exact
/// page-only final enumeration.
async test "raster capture rejects unexpected final page" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-render-raster-layout")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let plan = test_render_plan(root, "project")
    let context = fresh_render_context(plan, 1)
    async fn run(_ : Array[String]) -> RenderCommandResult {
      guard render_page_path(plan, 1) is Some(output) &&
        render_page_path(plan, 99) is Some(stale) else {
        abort("missing raster layout paths")
      }
      @fs.write_file(output, valid_png_header(), create_mode=CreateOrTruncate)
      @fs.write_file(stale, valid_png_header(), create_mode=CreateOrTruncate)
      render_command_result(0)
    }

    let failure = render_raster_failure(
      capture_render_pages_with(context, run~),
    )
    assert_eq(failure.code, "render.raster.layout")
    assert_true(failure.detail.contains("page_99.png"))
  }
}

///|
/// Explicit environment gate for the installed ChromiumFish/font surface. Both
/// committed decks must pass the deterministic validator and browser parity
/// probe at six pages; only their private ignored stages are cleaned afterward.
async test "live Chromium DOM probe counts both committed six-page decks" {
  guard @env.get_env_var("SLIDE_GEN_RENDER_DOM_LIVE") is Some(_) else { return }
  guard find_repo_root() is Some(root) else {
    abort("live render probe could not find the slide-gen root")
  }
  @async.with_task_group() <| group => {
    for project in ["rehab", "spine-segmentation"] {
      let plan = test_render_plan(root, project)
      group.add_defer(() => remove_entry_no_follow(plan.stage_dir))
      let outcome = preflight_render(root, project)
      match outcome {
        PreflightReady(context) => assert_eq(context.page_count, 6)
        PreflightFailed(failure) =>
          abort(
            "\{project} render preflight failed: \{failure.code}: \{failure.detail}",
          )
      }
    }
  }
}

///|
/// Explicit live raster gate: capture all six rehab pages twice on the current
/// Chromium/font surface and require byte-identical outputs. Each ready stage
/// must already be stripped of wrapper/profile scratch.
async test "live Chromium raster repeats rehab byte identically" {
  guard @env.get_env_var("SLIDE_GEN_RENDER_RASTER_LIVE") is Some(_) else {
    return
  }
  guard find_repo_root() is Some(root) else {
    abort("live raster probe could not find the slide-gen root")
  }
  let plan = test_render_plan(root, "rehab")
  @async.with_task_group() <| group => {
    group.add_defer(() => remove_entry_no_follow(plan.stage_dir))
    let first_outcome = raster_render(root, "rehab")
    guard first_outcome is RasterReady(first) else {
      guard first_outcome is RasterFailed(failure) else {
        abort("unreachable raster outcome")
      }
      abort("first live raster failed: \{failure.code}: \{failure.detail}")
    }
    assert_eq(first.paths.length(), 6)
    let first_bytes : Array[Bytes] = []
    for path in first.paths {
      guard read_real_binary_no_follow(path) is Some(data) else {
        abort("first live raster disappeared")
      }
      first_bytes.push(data)
    }
    assert_true(first_bytes[0] != first_bytes[5])

    let second_outcome = raster_render(root, "rehab")
    guard second_outcome is RasterReady(second) else {
      guard second_outcome is RasterFailed(failure) else {
        abort("unreachable raster outcome")
      }
      abort("second live raster failed: \{failure.code}: \{failure.detail}")
    }
    assert_eq(second.paths.length(), 6)
    for index, path in second.paths {
      guard read_real_binary_no_follow(path) is Some(data) else {
        abort("second live raster disappeared")
      }
      assert_true(data == first_bytes[index])
    }
    assert_false(@fs.exists(plan.wrapper_path))
    assert_false(@fs.exists(plan.profile_dir))
    assert_false(@fs.exists(plan.input_dir))
    assert_eq(@fs.readdir(plan.stage_dir, include_hidden=true).length(), 6)
  }
}

///|
/// Explicit live PDF gate over a disposable two-page bundle under the real repo
/// root, so uv resolves the exact tracked project/lock used by production.
async test "live rendered PDF preserves pages and lossless image streams" {
  guard @env.get_env_var("SLIDE_GEN_RENDER_PDF_LIVE") is Some(_) else { return }
  guard find_repo_root() is Some(root) else {
    abort("live PDF probe could not find the slide-gen root")
  }
  let project = "m3-pdf-live-probe"
  let plan = test_render_plan(root, project)
  for path in [plan.bundle_dir, plan.stage_dir, plan.backup_dir, plan.live_dir] {
    if @fs.exists(path) {
      abort("live PDF probe refuses to replace existing path: \{path}")
    }
  }
  @async.with_task_group() <| group => {
    group.add_defer(() => remove_entry_no_follow(plan.bundle_dir))
    group.add_defer(() => remove_entry_no_follow(plan.stage_dir))
    group.add_defer(() => remove_entry_no_follow(plan.backup_dir))
    group.add_defer(() => remove_entry_no_follow(plan.live_dir))
    write_render_test_deck(plan, render_test_deck(project, 2))
    let first = render_project(root, project)
    guard first is RenderPublished(result) else {
      guard first is RenderFailed(failure) else {
        abort("unreachable live PDF outcome")
      }
      abort("live PDF render failed: \{failure.code}: \{failure.detail}")
    }
    let first_pdf = @fs.read_file(result.pdf_path).binary()
    let first_pages : Array[Bytes] = []
    for page in 1..<=result.page_count {
      guard render_page_name(page) is Some(name) else {
        abort("live PDF probe could not construct a page name")
      }
      first_pages.push(@fs.read_file("\{result.render_dir}/\{name}").binary())
    }
    assert_true(first_pages[0] != first_pages[1])
    let info = run_render_command([
      "timeout",
      "--kill-after=5",
      "30",
      "env",
      "LC_ALL=C",
      "pdfinfo",
      "-f",
      "1",
      "-l",
      "2",
      "-box",
      result.pdf_path,
    ])
    let images = run_render_command([
      "timeout",
      "--kill-after=5",
      "30",
      "env",
      "LC_ALL=C",
      "pdfimages",
      "-list",
      result.pdf_path,
    ])
    assert_eq(info.code, 0)
    assert_true(info.stdout.contains("Producer:        img2pdf 0.6.3\n"))
    assert_true(info.stdout.contains("Pages:           2\n"))
    assert_false(info.stdout.contains("CreationDate:"))
    assert_false(info.stdout.contains("ModDate:"))
    let media_boxes = poppler_media_boxes(info.stdout)
    assert_eq(media_boxes.length(), 2)
    for index, box in media_boxes {
      assert_eq(box[1], (index + 1).to_string())
      assert_eq(box[3], "0.00")
      assert_eq(box[4], "0.00")
      assert_eq(box[5], "2560.00")
      assert_eq(box[6], "1440.00")
    }
    assert_eq(images.code, 0)
    let rows = poppler_image_rows(images.stdout)
    assert_eq(rows.length(), 2)
    for index, row in rows {
      assert_eq(row[0], (index + 1).to_string())
      assert_eq(row[1], index.to_string())
      assert_eq(row[2], "image")
      assert_eq(row[3], "2560")
      assert_eq(row[4], "1440")
      assert_eq(row[5], "rgb")
      assert_eq(row[6], "3")
      assert_eq(row[7], "8")
      assert_eq(row[8], "image")
      assert_eq(row[9], "no")
      assert_eq(row[12], "72")
      assert_eq(row[13], "72")
    }

    let second = render_project(root, project)
    guard second is RenderPublished(repeated) else {
      guard second is RenderFailed(failure) else {
        abort("unreachable repeated live PDF outcome")
      }
      abort(
        "repeated live PDF render failed: \{failure.code}: \{failure.detail}",
      )
    }
    assert_eq(repeated.page_count, 2)
    assert_true(@fs.read_file(repeated.pdf_path).binary() == first_pdf)
    for page in 1..<=repeated.page_count {
      guard render_page_name(page) is Some(name) else {
        abort("repeated live PDF probe could not construct a page name")
      }
      assert_true(
        @fs.read_file("\{repeated.render_dir}/\{name}").binary() ==
        first_pages[page - 1],
      )
    }
  }
}

///|
/// img2pdf receives the lossless deterministic options before numerically
/// ordered page paths and writes only the stage PDF.
test "img2pdf argv preserves page order and 72-dpi lossless options" {
  let plan = test_render_plan("/", "project")
  json_inspect(build_img2pdf_argv(plan, 3, timeout_secs=90).unwrap_or([]), content=[
    "timeout", "--kill-after=30", "90", "uv", "run", "--project", "/", "--locked",
    "--no-dev", "img2pdf", "--nodate", "--engine=internal", "--imgsize=72dpi", "--rotation=none",
    "--output", "/renders/.partial/project/deck.pdf", "/renders/.partial/project/page_01.png",
    "/renders/.partial/project/page_02.png", "/renders/.partial/project/page_03.png",
  ])
  assert_true(build_img2pdf_argv(plan, 0) is None)
  assert_true(build_img2pdf_argv(plan, 100) is None)
}

///|
/// Minimal signature+IHDR fixture for the pure header validator. CRC bytes are
/// present but deliberately inert: full chunk decoding belongs to img2pdf.
fn valid_png_header() -> Bytes {
  Bytes::from_array([
    0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, b'I',
    b'H', b'D', b'R', 0x00, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x05, 0xa0, 0x08, 0x02,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ])
}

///|
/// Clone the header and replace one byte to seed exactly one defect.
fn png_with_byte(index : Int, value : Byte) -> Bytes {
  let bytes = valid_png_header().to_array()
  bytes[index] = value
  Bytes::from_array(bytes)
}

///|
/// Header failures are classified one at a time: truncation, signature/IHDR,
/// dimensions, bit depth, non-RGB color, methods, and interlace.
test "PNG signature and IHDR contract isolates malformed raster classes" {
  inspect(validate_page_png(valid_png_header()).unwrap_or("ok"), content="ok")
  inspect(
    validate_page_png(Bytes::make(12, 0)).unwrap_or("ok"),
    content="render.png.truncated",
  )
  inspect(
    validate_page_png(png_with_byte(0, 0)).unwrap_or("ok"),
    content="render.png.signature",
  )
  inspect(
    validate_page_png(png_with_byte(15, b'X')).unwrap_or("ok"),
    content="render.png.ihdr",
  )
  inspect(
    validate_page_png(png_with_byte(19, 0x01)).unwrap_or("ok"),
    content="render.png.size",
  )
  inspect(
    validate_page_png(png_with_byte(24, 0x10)).unwrap_or("ok"),
    content="render.png.depth",
  )
  inspect(
    validate_page_png(png_with_byte(25, 0x06)).unwrap_or("ok"),
    content="render.png.color",
  )
  inspect(
    validate_page_png(png_with_byte(26, 0x01)).unwrap_or("ok"),
    content="render.png.method",
  )
  inspect(
    validate_page_png(png_with_byte(28, 0x01)).unwrap_or("ok"),
    content="render.png.interlace",
  )
}

///|
/// Closed layout accepts only ordered page names plus deck.pdf as real files;
/// missing, forged, duplicate, stale, and browser-scratch entries isolate their
/// respective stable codes.
test "closed staged render layout rejects every non-artifact entry class" {
  let clean = [
    RenderEntry::{ name: "page_01.png", regular: true },
    RenderEntry::{ name: "page_02.png", regular: true },
    RenderEntry::{ name: "deck.pdf", regular: true },
  ]
  json_inspect(validate_render_layout(clean, 2).codes(), content=[])
  json_inspect(validate_render_layout([clean[1], clean[2]], 2).codes(), content=[
    "render.layout.missing",
  ])
  let forged = clean.copy()
  forged[1] = RenderEntry::{ name: "page_02.png", regular: false }
  json_inspect(validate_render_layout(forged, 2).codes(), content=[
    "render.layout.not_regular",
  ])
  let duplicate = clean.copy()
  duplicate.push(RenderEntry::{ name: "deck.pdf", regular: true })
  json_inspect(validate_render_layout(duplicate, 2).codes(), content=[
    "render.layout.duplicate",
  ])
  let stale = clean.copy()
  stale.push(RenderEntry::{ name: "page_03.png", regular: true })
  json_inspect(validate_render_layout(stale, 2).codes(), content=[
    "render.layout.unexpected",
  ])
  let scratch = clean.copy()
  scratch.push(RenderEntry::{ name: ".page.html", regular: true })
  scratch.push(RenderEntry::{ name: ".chromium-profile", regular: false })
  json_inspect(validate_render_layout(scratch, 2).codes(), content=[
    "render.layout.unexpected", "render.layout.unexpected",
  ])
  json_inspect(validate_render_layout([], 0).codes(), content=[
    "render.layout.page_count",
  ])
}

///|
/// The final artifact gate requires a nonempty direct file beginning exactly
/// with the PDF header marker; container parsing remains pdfinfo's live job.
test "PDF artifact prefix rejects truncation and false signatures" {
  inspect(
    validate_pdf_artifact(Bytes::from_array([])).unwrap_or("ok"),
    content="render.pdf.truncated",
  )
  inspect(
    validate_pdf_artifact(Bytes::from_array([b'%', b'P', b'D', b'F'])).unwrap_or(
      "ok",
    ),
    content="render.pdf.truncated",
  )
  inspect(
    validate_pdf_artifact(Bytes::from_array([b'P', b'D', b'F', b'-', b'!'])).unwrap_or(
      "ok",
    ),
    content="render.pdf.signature",
  )
  assert_true(
    validate_pdf_artifact(
      Bytes::from_array([b'%', b'P', b'D', b'F', b'-', b'1', b'.', b'7']),
    )
    is None,
  )
}

///|
/// A fake zero-exit converter receives the exact locked argv, then the complete
/// closed stage atomically replaces an old live render through the shared seam.
async test "PDF completion publishes an exact render atomically" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-render-publish-good")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let plan = test_render_plan(root, "project")
    let pages = ready_render_pages(plan, 2)
    let sentinel = seed_old_render(plan)
    let calls : Array[Array[String]] = []
    async fn convert(argv : Array[String]) -> RenderCommandResult {
      calls.push(argv)
      @fs.write_file(plan.pdf_path, "%PDF-1.7\n", create_mode=CreateOrTruncate)
      render_command_result(0)
    }

    let outcome = complete_render_with(
      RasterReady(pages),
      run=convert,
      publish=promote_stage,
      timeout_secs=17,
    )
    guard outcome is RenderPublished(result) else {
      abort("passing fake PDF did not publish")
    }
    assert_eq(result.project, "project")
    assert_eq(result.page_count, 2)
    assert_eq(result.render_dir, plan.live_dir)
    assert_eq(result.pdf_path, "\{plan.live_dir}/deck.pdf")
    assert_eq(calls.length(), 1)
    assert_eq(calls[0][2], "17")
    assert_eq(calls[0][6], root)
    assert_false(@fs.exists(sentinel))
    assert_false(@fs.exists(plan.stage_dir))
    assert_false(@fs.exists(plan.backup_dir))
    assert_true(@fs.exists("\{plan.live_dir}/page_01.png"))
    assert_true(@fs.exists("\{plan.live_dir}/page_02.png"))
    assert_eq(@fs.read_file(result.pdf_path).text(), "%PDF-1.7\n")
  }
}

///|
/// The production entry restores an interrupted old-render backup before even
/// checking deck input. A deterministic missing-deck failure therefore cannot
/// strand the previously complete render in the reserved backup slot.
async test "render project recovers interrupted publication before preflight" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-render-recover-entry")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let plan = test_render_plan(root, "project")
    @fs.mkdir(plan.backup_dir, recursive=true)
    @fs.write_file(
      "\{plan.backup_dir}/sentinel",
      "old",
      create_mode=CreateOrTruncate,
    )
    let failure = final_render_failure(render_project(root, "project"))
    assert_eq(failure.code, "render.deck.directory")
    assert_eq(@fs.read_file("\{plan.live_dir}/sentinel").text(), "old")
    assert_false(@fs.exists(plan.backup_dir))
  }
}

///|
/// Every public render entry fails before touching the stage when generation or
/// a peer render already owns the project operation lease.
async test "render entries report a concurrent project operation" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-render-entry-lock")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let lock_file = match acquire_project_operation_lock(root, "project") {
      ProjectOperationLocked(file) => file
      ProjectOperationBusy => abort("setup project lock was busy")
      ProjectOperationLockFailed(error) =>
        abort("setup project lock failed: \{error}")
    }
    defer lock_file.close()
    defer lock_file.unlock()
    let preflight = render_preflight_failure(preflight_render(root, "project"))
    assert_eq(preflight.code, "render.project.busy")
    let raster = render_raster_failure(raster_render(root, "project"))
    assert_eq(raster.code, "render.project.busy")
    let failure = final_render_failure(render_project(root, "project"))
    assert_eq(failure.code, "render.project.busy")
    assert_true(failure.detail.contains("project project"))
  }
}

///|
/// Capture, timeout, nonzero converter, missing output, and forged-output
/// failures all stop before publication and retain the previous live render.
async test "render completion preserves old live across capture and PDF failures" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-render-publish-pdf-fail")
    group.add_defer(() => @fs.rmdir(root, recursive=true))

    let capture_plan = test_render_plan(root, "capture")
    let capture_sentinel = seed_old_render(capture_plan)
    let mut capture_calls = 0
    async fn should_not_convert(_ : Array[String]) -> RenderCommandResult {
      ignore(@fs.exists(capture_plan.live_dir))
      capture_calls = capture_calls + 1
      render_command_result(0)
    }

    let capture_failure = final_render_failure(
      complete_render_with(
        RasterFailed(RenderFailure::{
          code: "render.raster.exec",
          detail: "controlled",
        }),
        run=should_not_convert,
        publish=promote_stage,
      ),
    )
    assert_eq(capture_failure.code, "render.raster.exec")
    assert_eq(capture_calls, 0)
    assert_eq(@fs.read_file(capture_sentinel).text(), "old")

    let timeout_plan = test_render_plan(root, "timeout")
    let timeout_pages = ready_render_pages(timeout_plan, 1)
    let timeout_sentinel = seed_old_render(timeout_plan)
    async fn timeout_convert(argv : Array[String]) -> RenderCommandResult {
      ignore(@fs.exists(argv[0]))
      render_command_result(137)
    }

    let timeout_failure = final_render_failure(
      complete_render_with(
        RasterReady(timeout_pages),
        run=timeout_convert,
        publish=promote_stage,
      ),
    )
    assert_eq(timeout_failure.code, "render.pdf.timeout")
    assert_eq(@fs.read_file(timeout_sentinel).text(), "old")

    let exec_plan = test_render_plan(root, "exec")
    let exec_pages = ready_render_pages(exec_plan, 1)
    let exec_sentinel = seed_old_render(exec_plan)
    async fn failed_convert(argv : Array[String]) -> RenderCommandResult {
      ignore(@fs.exists(argv[0]))
      render_command_result(8, stderr="controlled converter failure")
    }

    let exec_failure = final_render_failure(
      complete_render_with(
        RasterReady(exec_pages),
        run=failed_convert,
        publish=promote_stage,
      ),
    )
    assert_eq(exec_failure.code, "render.pdf.exec")
    assert_true(exec_failure.detail.contains("controlled converter failure"))
    assert_eq(@fs.read_file(exec_sentinel).text(), "old")

    let missing_plan = test_render_plan(root, "missing")
    let missing_pages = ready_render_pages(missing_plan, 1)
    let missing_sentinel = seed_old_render(missing_plan)
    async fn missing_convert(argv : Array[String]) -> RenderCommandResult {
      ignore(@fs.exists(argv[0]))
      render_command_result(0)
    }

    let missing_failure = final_render_failure(
      complete_render_with(
        RasterReady(missing_pages),
        run=missing_convert,
        publish=promote_stage,
      ),
    )
    assert_eq(missing_failure.code, "render.pdf.output")
    assert_eq(@fs.read_file(missing_sentinel).text(), "old")

    let malformed_plan = test_render_plan(root, "malformed")
    let malformed_pages = ready_render_pages(malformed_plan, 1)
    let malformed_sentinel = seed_old_render(malformed_plan)
    async fn malformed_convert(_ : Array[String]) -> RenderCommandResult {
      @fs.write_file(
        malformed_plan.pdf_path,
        "not a PDF",
        create_mode=CreateOrTruncate,
      )
      render_command_result(0)
    }

    let malformed_failure = final_render_failure(
      complete_render_with(
        RasterReady(malformed_pages),
        run=malformed_convert,
        publish=promote_stage,
      ),
    )
    assert_eq(malformed_failure.code, "render.pdf.signature")
    assert_eq(@fs.read_file(malformed_sentinel).text(), "old")

    let linked_plan = test_render_plan(root, "linked")
    let linked_pages = ready_render_pages(linked_plan, 1)
    let linked_sentinel = seed_old_render(linked_plan)
    let outside = "\{root}/outside.pdf"
    @fs.write_file(outside, "%PDF-1.7\n", create_mode=CreateOrTruncate)
    async fn linked_convert(_ : Array[String]) -> RenderCommandResult {
      @fs.symlink(linked_plan.pdf_path, target=outside)
      render_command_result(0)
    }

    let linked_failure = final_render_failure(
      complete_render_with(
        RasterReady(linked_pages),
        run=linked_convert,
        publish=promote_stage,
      ),
    )
    assert_eq(linked_failure.code, "render.pdf.output")
    assert_eq(@fs.read_file(linked_sentinel).text(), "old")
    assert_eq(@fs.read_file(outside).text(), "%PDF-1.7\n")
  }
}

///|
/// Converter-created junk and a failed stage rename are both non-publication
/// outcomes. The shared promotion seam restores the old render after moving it
/// aside, while the failed candidate stays absent from live.
async test "render completion preserves old live on layout and promote failure" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-render-publish-final-fail")
    group.add_defer(() => @fs.rmdir(root, recursive=true))

    let layout_plan = test_render_plan(root, "layout")
    let layout_pages = ready_render_pages(layout_plan, 1)
    let layout_sentinel = seed_old_render(layout_plan)
    async fn dirty_convert(_ : Array[String]) -> RenderCommandResult {
      @fs.write_file(
        layout_plan.pdf_path,
        "%PDF-1.7\n",
        create_mode=CreateOrTruncate,
      )
      @fs.write_file(
        "\{layout_plan.stage_dir}/junk",
        "junk",
        create_mode=CreateOrTruncate,
      )
      render_command_result(0)
    }

    let layout_failure = final_render_failure(
      complete_render_with(
        RasterReady(layout_pages),
        run=dirty_convert,
        publish=promote_stage,
      ),
    )
    assert_eq(layout_failure.code, "render.layout.unexpected")
    assert_eq(@fs.read_file(layout_sentinel).text(), "old")

    let mutated_plan = test_render_plan(root, "mutated")
    let mutated_pages = ready_render_pages(mutated_plan, 1)
    let mutated_sentinel = seed_old_render(mutated_plan)
    async fn mutating_convert(_ : Array[String]) -> RenderCommandResult {
      @fs.write_file(
        mutated_plan.pdf_path,
        "%PDF-1.7\n",
        create_mode=CreateOrTruncate,
      )
      @fs.write_file(
        mutated_pages.paths[0],
        "not a PNG",
        create_mode=CreateOrTruncate,
      )
      render_command_result(0)
    }

    let mutated_failure = final_render_failure(
      complete_render_with(
        RasterReady(mutated_pages),
        run=mutating_convert,
        publish=promote_stage,
      ),
    )
    assert_eq(mutated_failure.code, "render.png.truncated")
    assert_eq(@fs.read_file(mutated_sentinel).text(), "old")

    let promote_plan = test_render_plan(root, "promote")
    let promote_pages = ready_render_pages(promote_plan, 1)
    let promote_sentinel = seed_old_render(promote_plan)
    async fn good_convert(_ : Array[String]) -> RenderCommandResult {
      @fs.write_file(
        promote_plan.pdf_path,
        "%PDF-1.7\n",
        create_mode=CreateOrTruncate,
      )
      render_command_result(0)
    }

    async fn break_publish(paths : PublicationPaths) -> Unit {
      remove_entry_no_follow(paths.stage)
      promote_stage(paths)
    }

    let promote_failure = final_render_failure(
      complete_render_with(
        RasterReady(promote_pages),
        run=good_convert,
        publish=break_publish,
      ),
    )
    assert_eq(promote_failure.code, "render.publication.promote")
    assert_eq(@fs.read_file(promote_sentinel).text(), "old")
    assert_false(@fs.exists(promote_plan.backup_dir))
  }
}
