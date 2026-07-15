// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Fixed raster contract inherited from the shipped deck template. Chromium
/// captures at device-scale-factor 1; img2pdf maps every pixel to one 72-dpi
/// PDF point without recompression.
pub let render_width_px : Int = 2560

///|
/// Fixed page height in CSS pixels, raster pixels, and final PDF points.
pub let render_height_px : Int = 1440

///|
/// DOM/source page counts are bounded to two-digit artifact names.
pub let max_render_pages : Int = 99

///|
/// Wall-clock ceiling for each Chromium or img2pdf process. GNU timeout treats
/// zero as disabled, so non-positive overrides fall back to this value.
pub let default_render_timeout_secs : Int = 120

///|
/// Pure path plan for one named render. `bundle_dir` is committed input;
/// everything else is derived, ignored output. Browser-only scratch lives
/// inside the reserved stage and is removed before the closed layout publishes.
/// The opaque public type is the temporary warning-free seam for M3.2b/M3.2c;
/// it can become package-private once the production orchestrator consumes it.
pub struct RenderPlan {
  project : String
  root : String
  bundle_dir : String
  deck_path : String
  stage_dir : String
  backup_dir : String
  live_dir : String
  profile_dir : String
  wrapper_path : String
  pdf_path : String
}

///|
/// One no-follow stage entry projected onto the pure layout checker. `regular`
/// is true only for a real regular file; directories, symlinks, and special
/// entries are false.
pub(all) struct RenderEntry {
  name : String
  regular : Bool
}

///|
/// Stable preflight failure surfaced before rasterization. `code` is the
/// machine-readable contract asserted by controlled tests; `detail` retains the
/// validator or process diagnostic for the eventual CLI.
pub(all) struct RenderFailure {
  code : String
  detail : String
}

///|
/// Browser-resolved, validator-clean input handed to M3.2c. The stage and its
/// real isolated profile already exist; `page_count` is the matching source and
/// browser-DOM slide count in the bounded render range.
pub(all) struct RenderContext {
  plan : RenderPlan
  browser : String
  page_count : Int
}

///|
/// M3.2b outcome: either a context safe to begin fixed-page capture or one
/// deterministic failure. Raster/PDF/publication outcomes land in later units.
pub(all) enum RenderPreflightOutcome {
  PreflightReady(RenderContext)
  PreflightFailed(RenderFailure)
}

///|
/// Browser-clean staged rasters handed to M3.3. Paths are one per page in
/// numeric order; the stage contains exactly those real validated PNG files
/// when this value is constructed.
pub(all) struct RenderPages {
  plan : RenderPlan
  paths : Array[String]
}

///|
/// M3.2c outcome: either every fixed page was captured and browser-only scratch
/// was removed, or rasterization stopped at one stable failure. This raster
/// layer itself performs no PDF or publication action.
pub(all) enum RenderRasterOutcome {
  RasterReady(RenderPages)
  RasterFailed(RenderFailure)
}

///|
/// Injectable process result. Production fills it through collect_output;
/// white-box tests return controlled tool/font/Chromium outcomes without
/// spawning processes.
priv struct RenderCommandResult {
  code : Int
  stdout : String
  stderr : String
}

///|
/// A render target is one representable direct child that cannot overlap the
/// reserved `.partial`/`.previous` roots: the shared CLI name policy plus no
/// leading dot. Internal dots, spaces, quotes, and non-ASCII remain valid.
pub fn valid_render_project(name : String) -> Bool {
  representable(name) && !name.has_prefix(".")
}

///|
/// Strip redundant trailing separators while preserving filesystem root.
fn canonical_render_root(root : String) -> String {
  let mut out = root
  while out.length() > 1 && out.has_suffix("/") {
    out = out[:out.length() - 1].to_owned()
  }
  out
}

///|
/// Resolve committed input and reserved render output paths without touching
/// the filesystem. A canonical repo root is absolute in production; rejecting
/// relative roots keeps later file URLs unambiguous. Joins preserve `/` exactly
/// and never introduce `//` path components.
pub fn plan_render(root : String, project : String) -> RenderPlan? {
  guard root.has_prefix("/") && valid_render_project(project) else {
    return None
  }
  let root = canonical_render_root(root)
  let bundle_dir = join_path(root, "decks/\{project}")
  let stage_dir = join_path(root, "renders/.partial/\{project}")
  Some(RenderPlan::{
    project,
    root,
    bundle_dir,
    deck_path: join_path(bundle_dir, "deck.html"),
    stage_dir,
    backup_dir: join_path(root, "renders/.previous/\{project}"),
    live_dir: join_path(root, "renders/\{project}"),
    profile_dir: join_path(stage_dir, ".chromium-profile"),
    wrapper_path: join_path(stage_dir, ".page.html"),
    pdf_path: join_path(stage_dir, "deck.pdf"),
  })
}

///|
/// Adapt render paths to the shared rollback-safe directory-publication seam.
/// M3.2b uses only stage recreation; M3.3 will recover/promote these same paths.
fn RenderPlan::publication(self : RenderPlan) -> PublicationPaths {
  PublicationPaths::{
    stage: self.stage_dir,
    backup: self.backup_dir,
    live: self.live_dir,
  }
}

///|
/// Whether one UTF-8 byte may remain literal in a file-URL path. RFC 3986
/// unreserved bytes plus `/` are stable across URI and filesystem parsing;
/// every other byte is percent-encoded.
fn file_url_byte_safe(byte : Byte) -> Bool {
  let n = byte.to_int()
  (n >= 0x41 && n <= 0x5a) ||
  (n >= 0x61 && n <= 0x7a) ||
  (n >= 0x30 && n <= 0x39) ||
  byte == b'-' ||
  byte == b'.' ||
  byte == b'_' ||
  byte == b'~' ||
  byte == b'/'
}

///|
/// Convert an absolute POSIX path to a UTF-8, uppercase-percent-encoded file
/// URL. Quotes, spaces, URL delimiters, and non-ASCII bytes therefore cannot
/// alter the browser's path parse. `/` becomes `file:///`.
pub fn file_url(path : String) -> String? {
  guard path.has_prefix("/") else { return None }
  let hex = "0123456789ABCDEF".to_array()
  let out = StringBuilder::new()
  out.write_string("file://")
  for byte in @utf8.encode(path).iter() {
    if file_url_byte_safe(byte) {
      out.write_char(byte.to_char())
    } else {
      let n = byte.to_int()
      out.write_char('%')
      out.write_char(hex[n / 16])
      out.write_char(hex[n % 16])
    }
  }
  Some(out.to_string())
}

///|
/// Escape one HTML double-quoted attribute value. This remains a separate
/// defense from URI encoding so wrapper composition stays safe if its URL
/// surface later changes.
pub fn escape_html_attr(value : String) -> String {
  let out = StringBuilder::new()
  for c in value.to_array() {
    match c {
      '&' => out.write_string("&amp;")
      '<' => out.write_string("&lt;")
      '>' => out.write_string("&gt;")
      '"' => out.write_string("&quot;")
      '\'' => out.write_string("&#39;")
      _ => out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// Stable two-digit artifact basename for a one-based page number.
pub fn render_page_name(page : Int) -> String? {
  guard page >= 1 && page <= max_render_pages else { return None }
  if page < 10 {
    Some("page_0\{page}.png")
  } else {
    Some("page_\{page}.png")
  }
}

///|
/// Stage-local path for one page raster.
pub fn render_page_path(plan : RenderPlan, page : Int) -> String? {
  guard render_page_name(page) is Some(name) else { return None }
  Some(join_path(plan.stage_dir, name))
}

///|
/// Ordered page basenames for one bounded render, without the later PDF.
fn expected_page_names(page_count : Int) -> Array[String]? {
  guard page_count >= 1 && page_count <= max_render_pages else { return None }
  let names : Array[String] = []
  for page in 1..<=page_count {
    guard render_page_name(page) is Some(name) else { return None }
    names.push(name)
  }
  Some(names)
}

///|
/// Render the tiny stage-local page wrapper. Its viewport clips one tall iframe
/// whose height is exactly the deck height; shifting the iframe by one fixed
/// page per capture avoids fragments, unbounded screenshots, and crop tools.
/// Pages are one-based; invalid page/count pairs fail before browser input is
/// materialized.
pub fn render_page_wrapper(
  plan : RenderPlan,
  page : Int,
  page_count : Int,
) -> String? {
  guard page_count >= 1 &&
    page_count <= max_render_pages &&
    page >= 1 &&
    page <= page_count else {
    return None
  }
  guard file_url(plan.deck_path) is Some(deck_url) else { return None }
  let frame_height = page_count * render_height_px
  let offset = (page - 1) * render_height_px
  let top = if offset == 0 { "0" } else { "-\{offset}" }
  Some(
    (
      $|<!doctype html>
      $|<html lang="en">
      $|<head>
      $|<meta charset="utf-8">
      $|<style>
      $|*{box-sizing:border-box}
      $|html,body{margin:0;width:\{render_width_px}px;height:\{render_height_px}px;overflow:hidden;background:#fff}
      $|iframe{position:absolute;left:0;top:\{top}px;width:\{render_width_px}px;height:\{frame_height}px;border:0}
      $|</style>
      $|</head>
      $|<body><iframe title="slide page \{page}" src="\{escape_html_attr(deck_url)}" scrolling="no"></iframe></body>
      $|</html>
      $|
    ),
  )
}

///|
/// Normalize a caller override without allowing GNU timeout's disabling zero.
fn bounded_render_timeout(timeout_secs : Int) -> Int {
  if timeout_secs <= 0 {
    default_render_timeout_secs
  } else {
    timeout_secs
  }
}

///|
/// Shared bounded/offline Chromium prefix. The dead proxy plus loopback-bypass
/// subtraction catches literal-IP traffic, the resolver rule fails DNS, and
/// background services/crash reporting are suppressed. Disabling mutable field-
/// trial startup config also keeps ChromiumFish's CLI capture path terminating
/// deterministically. The validated deck itself is static; these flags are
/// defense-in-depth, not a browser sandbox claim.
fn chromium_argv(
  browser : String,
  profile_dir : String,
  timeout_secs : Int,
) -> Array[String] {
  [
    "timeout",
    "--kill-after=30",
    bounded_render_timeout(timeout_secs).to_string(),
    browser,
    "--headless=new",
    "--disable-field-trial-config",
    "--disable-breakpad",
    "--no-sandbox",
    "--disable-gpu",
    "--force-device-scale-factor=1",
    "--window-size=\{render_width_px},\{render_height_px}",
    "--hide-scrollbars",
    "--user-data-dir=\{profile_dir}",
    "--proxy-server=http://127.0.0.1:9",
    "--proxy-bypass-list=<-loopback>",
    "--host-resolver-rules=MAP * ~NOTFOUND",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-default-apps",
    "--disable-sync",
    "--metrics-recording-only",
    "--no-first-run",
  ]
}

///|
/// Exact bounded Chromium argv for the browser-parsed DOM preflight. The deck
/// URL is the final positional argument and stdout carries `--dump-dom` output.
pub fn build_dump_dom_argv(
  plan : RenderPlan,
  browser : String,
  timeout_secs? : Int = default_render_timeout_secs,
) -> Array[String]? {
  guard file_url(plan.deck_path) is Some(deck_url) else { return None }
  let argv = chromium_argv(browser, plan.profile_dir, timeout_secs)
  argv.push("--dump-dom")
  argv.push(deck_url)
  Some(argv)
}

///|
/// Construct one stable preflight failure.
fn render_preflight_failed(
  code : String,
  detail : String,
) -> RenderPreflightOutcome {
  PreflightFailed(RenderFailure::{ code, detail })
}

///|
/// Prefer stderr, then stdout, then the numeric exit when describing a failed
/// external command. Edge whitespace is presentation noise and is removed.
fn render_command_detail(result : RenderCommandResult) -> String {
  let stderr = result.stderr.trim().to_owned()
  if !stderr.is_empty() {
    return stderr
  }
  let stdout = result.stdout.trim().to_owned()
  if !stdout.is_empty() {
    return stdout
  }
  "exit code \{result.code}"
}

///|
/// GNU timeout returns 124 after a terminating deadline and 137 when its
/// kill-after escalation had to SIGKILL a command that ignored termination.
fn render_command_timed_out(code : Int) -> Bool {
  code == 124 || code == 137
}

///|
/// Whether one path's final component is a real regular file. Bundle input and
/// the resolved browser binary both fail closed on missing/symlink/special
/// entries.
async fn is_real_regular_no_follow(path : String) -> Bool {
  try @fs.kind(path, follow_symlink=false) catch {
    _ => false
  } noraise {
    @fs.Regular => true
    _ => false
  }
}

///|
/// Execute one argv vector without a shell. Start/decoding failures become a
/// synthetic nonzero result so every production failure follows the same
/// deterministic stage-specific classification as injected failures.
async fn run_render_command(argv : Array[String]) -> RenderCommandResult {
  guard argv.length() > 0 else {
    return RenderCommandResult::{
      code: -1,
      stdout: "",
      stderr: "empty command",
    }
  }
  try {
    let (code, stdout, stderr) = @process.collect_output(argv[0], argv[1:])
    RenderCommandResult::{ code, stdout: stdout.text(), stderr: stderr.text() }
  } catch {
    error => RenderCommandResult::{ code: -1, stdout: "", stderr: "\{error}" }
  } noraise {
    result => result
  }
}

///|
/// Filesystem/validator/tool/DOM preflight with an injected argv runner. Deck
/// directory and deck.html are lstat-checked and the complete structural/static
/// validator runs before the first external process. The same cleaned scanner
/// that drives validation counts source and dumped-DOM section.slide elements.
async fn preflight_render_with(
  plan : RenderPlan,
  run~ : async (Array[String]) -> RenderCommandResult,
  timeout_secs? : Int = default_render_timeout_secs,
) -> RenderPreflightOutcome {
  if !is_real_directory_no_follow(plan.bundle_dir) {
    return render_preflight_failed(
      "render.deck.directory",
      "deck bundle is missing, non-directory, or a symlink: \{plan.bundle_dir}",
    )
  }
  if !is_real_regular_no_follow(plan.deck_path) {
    return render_preflight_failed(
      "render.deck.file",
      "deck.html is missing, non-regular, or a symlink: \{plan.deck_path}",
    )
  }
  guard read_regular_text(plan.deck_path) is Some(html) && !html.is_empty() else {
    return render_preflight_failed(
      "render.deck.file",
      "deck.html is empty or unreadable: \{plan.deck_path}",
    )
  }
  let assets = list_assets(plan.bundle_dir)
  let report = validate_deck(html, plan.project, assets)
  if !report.ok() {
    return render_preflight_failed("render.deck.invalid", report.render())
  }
  let source_pages = scan_deck(clean_doc(html.to_array())).length()
  if source_pages < 1 || source_pages > max_render_pages {
    return render_preflight_failed(
      "render.pages.source",
      "source deck page count must be in 1..=\{max_render_pages}; got \{source_pages}",
    )
  }

  let browser_result = run(["chromiumfish", "path"])
  if browser_result.code != 0 {
    return render_preflight_failed(
      "render.browser.resolve",
      render_command_detail(browser_result),
    )
  }
  let browser = browser_result.stdout.trim().to_owned()
  if !browser.has_prefix("/") || !is_real_regular_no_follow(browser) {
    return render_preflight_failed(
      "render.browser.path", "chromiumfish path did not resolve to an absolute real regular file",
    )
  }

  let font_result = run([
    "fc-match", "--format=%{family}\\n", "Noto Sans CJK JP",
  ])
  if font_result.code != 0 {
    return render_preflight_failed(
      "render.font.resolve",
      render_command_detail(font_result),
    )
  }
  if font_result.stdout.trim().to_owned() != "Noto Sans CJK JP" {
    return render_preflight_failed(
      "render.font.missing", "fc-match did not resolve Noto Sans CJK JP",
    )
  }

  let profile_error : String? = try {
    recreate_stage(plan.publication())
    @fs.mkdir(plan.profile_dir)
    None
  } catch {
    error => Some("\{error}")
  } noraise {
    result => result
  }
  match profile_error {
    Some(error) =>
      return render_preflight_failed(
        "render.profile.create",
        "could not create isolated Chromium profile: \{error}",
      )
    None => ()
  }
  if !is_real_directory_no_follow(plan.profile_dir) {
    return render_preflight_failed(
      "render.profile.create", "isolated Chromium profile is not a real directory",
    )
  }

  guard build_dump_dom_argv(plan, browser, timeout_secs~) is Some(argv) else {
    return render_preflight_failed(
      "render.dom.argv", "could not construct Chromium DOM command",
    )
  }
  let dom_result = run(argv)
  if render_command_timed_out(dom_result.code) {
    return render_preflight_failed(
      "render.dom.timeout", "Chromium DOM probe exceeded its bounded runtime",
    )
  }
  if dom_result.code != 0 {
    return render_preflight_failed(
      "render.dom.exec",
      render_command_detail(dom_result),
    )
  }
  if !is_real_directory_no_follow(plan.profile_dir) {
    return render_preflight_failed(
      "render.profile.swapped", "isolated Chromium profile ceased to be a real directory",
    )
  }
  let dom = dom_result.stdout
  if dom.trim().is_empty() {
    return render_preflight_failed(
      "render.dom.empty", "Chromium returned an empty DOM",
    )
  }
  let dom_pages = scan_deck(clean_doc(dom.to_array())).length()
  if dom_pages < 1 || dom_pages > max_render_pages {
    return render_preflight_failed(
      "render.dom.page_count",
      "browser DOM page count must be in 1..=\{max_render_pages}; got \{dom_pages}",
    )
  }
  if dom_pages != source_pages {
    return render_preflight_failed(
      "render.dom.mismatch",
      "source deck has \{source_pages} pages but browser DOM has \{dom_pages}",
    )
  }
  PreflightReady(RenderContext::{ plan, browser, page_count: dom_pages })
}

///|
/// Production Chromium preflight for one named committed deck. Name/root
/// rejection is deterministic and happens before filesystem or process access;
/// M3.2c consumes the ready context for sequential fixed-page capture.
pub async fn preflight_render(
  root : String,
  project : String,
  timeout_secs? : Int = default_render_timeout_secs,
) -> RenderPreflightOutcome {
  guard plan_render(root, project) is Some(plan) else {
    return render_preflight_failed(
      "render.project", "render project must be a non-dot representable direct-child name under an absolute root",
    )
  }
  preflight_render_with(plan, run=run_render_command, timeout_secs~)
}

///|
/// Exact bounded Chromium argv for one fixed-viewport wrapper capture. The
/// output path is passed as an argv value, never shell-parsed.
pub fn build_screenshot_argv(
  plan : RenderPlan,
  browser : String,
  page : Int,
  timeout_secs? : Int = default_render_timeout_secs,
) -> Array[String]? {
  guard render_page_path(plan, page) is Some(output) else { return None }
  guard file_url(plan.wrapper_path) is Some(wrapper_url) else { return None }
  let argv = chromium_argv(browser, plan.profile_dir, timeout_secs)
  argv.push("--screenshot=\{output}")
  argv.push(wrapper_url)
  Some(argv)
}

///|
/// Ordered expected root basenames for a complete staged render: every page in
/// numeric order, then the PDF. Invalid counts have no valid layout.
pub fn expected_render_names(page_count : Int) -> Array[String]? {
  guard expected_page_names(page_count) is Some(names) else { return None }
  names.push("deck.pdf")
  Some(names)
}

///|
/// Exact uv-locked, bounded img2pdf argv. Ordered stage page paths follow the
/// fixed lossless 72-dpi options; `deck.pdf` is written into the same stage.
/// M3.3 adds the pinned runtime dependency before this command is executed.
pub fn build_img2pdf_argv(
  plan : RenderPlan,
  page_count : Int,
  timeout_secs? : Int = default_render_timeout_secs,
) -> Array[String]? {
  guard expected_render_names(page_count) is Some(_) else { return None }
  let argv = [
    "timeout",
    "--kill-after=30",
    bounded_render_timeout(timeout_secs).to_string(),
    "uv",
    "run",
    "--locked",
    "--no-dev",
    "img2pdf",
    "--nodate",
    "--engine=internal",
    "--imgsize=72dpi",
    "--rotation=none",
    "--output",
    plan.pdf_path,
  ]
  for page in 1..<=page_count {
    guard render_page_path(plan, page) is Some(path) else { return None }
    argv.push(path)
  }
  Some(argv)
}

///|
/// Compare a byte range against one short literal.
fn png_bytes_equal(data : Bytes, offset : Int, expected : Array[Byte]) -> Bool {
  guard offset >= 0 && offset + expected.length() <= data.length() else {
    return false
  }
  for i, byte in expected {
    if data[offset + i] != byte {
      return false
    }
  }
  true
}

///|
/// Read one network-order UInt32 after the caller has established bounds.
fn png_u32(data : Bytes, offset : Int) -> UInt {
  (data[offset].to_uint() << 24) |
  (data[offset + 1].to_uint() << 16) |
  (data[offset + 2].to_uint() << 8) |
  data[offset + 3].to_uint()
}

///|
/// Validate the deterministic browser raster header. The first returned code
/// isolates one contract class: complete PNG signature/IHDR shape, exact
/// 2560x1440 size, 8-bit truecolor RGB, standard compression/filter methods,
/// and no interlace. Full pixel/chunk decoding remains img2pdf's job.
pub fn validate_page_png(data : Bytes) -> String? {
  if data.length() < 33 {
    return Some("render.png.truncated")
  }
  if !png_bytes_equal(data, 0, [0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]) {
    return Some("render.png.signature")
  }
  if png_u32(data, 8) != 13U ||
    !png_bytes_equal(data, 12, [b'I', b'H', b'D', b'R']) {
    return Some("render.png.ihdr")
  }
  if png_u32(data, 16) != render_width_px.reinterpret_as_uint() ||
    png_u32(data, 20) != render_height_px.reinterpret_as_uint() {
    return Some("render.png.size")
  }
  if data[24] != 8 {
    return Some("render.png.depth")
  }
  if data[25] != 2 {
    return Some("render.png.color")
  }
  if data[26] != 0 || data[27] != 0 {
    return Some("render.png.method")
  }
  if data[28] != 0 {
    return Some("render.png.interlace")
  }
  None
}

///|
/// Construct one stable raster failure while retaining the shared diagnostic
/// shape used by preflight and the eventual CLI.
fn render_raster_failed(code : String, detail : String) -> RenderRasterOutcome {
  RasterFailed(RenderFailure::{ code, detail })
}

///|
/// Read one direct real regular file as bytes. The no-follow classification is
/// repeated immediately before the read; publication-level hostile-race
/// resistance remains outside this portable path-based boundary.
async fn read_real_binary_no_follow(path : String) -> Bytes? {
  if !is_real_regular_no_follow(path) {
    return None
  }
  try @fs.read_file(path).binary() catch {
    _ => None
  } noraise {
    data => Some(data)
  }
}

///|
/// Preflight must hand rasterization a fresh stage containing only its isolated
/// real Chromium profile. This makes a stale screenshot unusable even when a
/// later browser command exits successfully without writing output.
async fn raster_stage_is_fresh(context : RenderContext) -> Bool {
  if !is_real_directory_no_follow(context.plan.stage_dir) ||
    !is_real_directory_no_follow(context.plan.profile_dir) {
    return false
  }
  try
    @fs.readdir(
      context.plan.stage_dir,
      include_hidden=true,
      include_special=false,
    )
  catch {
    _ => false
  } noraise {
    entries => entries.length() == 1 && entries[0] == ".chromium-profile"
  }
}

///|
/// Remove wrapper/profile scratch, then re-enumerate and revalidate the exact
/// page-only stage. Numeric construction, rather than directory order, defines
/// the returned path order (including page 10+).
async fn finish_raster_stage(context : RenderContext) -> RenderRasterOutcome {
  let plan = context.plan
  if !is_real_directory_no_follow(plan.stage_dir) {
    return render_raster_failed(
      "render.raster.stage", "render stage ceased to be a real directory",
    )
  }
  let cleanup_error : String? = try {
    remove_entry_no_follow(plan.wrapper_path)
    remove_entry_no_follow(plan.profile_dir)
    None
  } catch {
    error => Some("\{error}")
  } noraise {
    result => result
  }
  match cleanup_error {
    Some(error) =>
      return render_raster_failed(
        "render.raster.cleanup",
        "could not remove browser scratch: \{error}",
      )
    None => ()
  }
  if !is_real_directory_no_follow(plan.stage_dir) {
    return render_raster_failed(
      "render.raster.stage", "render stage ceased to be a real directory",
    )
  }
  guard expected_page_names(context.page_count) is Some(expected) else {
    return render_raster_failed(
      "render.raster.context", "raster page count is outside the bounded range",
    )
  }
  let entries : Array[String] = try
    @fs.readdir(plan.stage_dir, include_hidden=true, include_special=false)
  catch {
    error =>
      return render_raster_failed(
        "render.raster.layout",
        "could not enumerate raster stage: \{error}",
      )
  } noraise {
    names => names
  }
  let expected_set = @set.Set(expected[:])
  let unexpected : Array[String] = []
  for name in entries {
    if !expected_set.contains(name) {
      unexpected.push(name)
    }
  }
  unexpected.sort_by(lex_compare)
  if unexpected.length() > 0 {
    return render_raster_failed(
      "render.raster.layout",
      "unexpected staged raster entry: \{unexpected[0]}",
    )
  }
  if entries.length() != expected.length() {
    return render_raster_failed(
      "render.raster.layout", "staged raster set is incomplete",
    )
  }
  let paths : Array[String] = []
  for page in 1..<=context.page_count {
    guard render_page_path(plan, page) is Some(path) else {
      return render_raster_failed(
        "render.raster.context", "could not construct ordered page path",
      )
    }
    guard read_real_binary_no_follow(path) is Some(data) else {
      return render_raster_failed(
        "render.raster.output",
        "page \{page} is missing, unreadable, non-regular, or a symlink",
      )
    }
    match validate_page_png(data) {
      Some(code) =>
        return render_raster_failed(
          code,
          "page \{page} failed the PNG contract during final validation",
        )
      None => ()
    }
    paths.push(path)
  }
  RasterReady(RenderPages::{ plan, paths })
}

///|
/// Sequential fixed-page capture over a validator/browser-ready context. Every
/// wrapper is written as a direct real file, every prior output path is removed
/// before its producer runs, and stage/profile/wrapper/output identities are
/// checked after each process. A failed page returns immediately.
async fn capture_render_pages_with(
  context : RenderContext,
  run~ : async (Array[String]) -> RenderCommandResult,
  timeout_secs? : Int = default_render_timeout_secs,
) -> RenderRasterOutcome {
  if context.page_count < 1 || context.page_count > max_render_pages {
    return render_raster_failed(
      "render.raster.context", "raster page count is outside the bounded range",
    )
  }
  if !raster_stage_is_fresh(context) {
    return render_raster_failed(
      "render.raster.stage_dirty", "render stage must contain only a real isolated Chromium profile",
    )
  }
  for page in 1..<=context.page_count {
    if !is_real_directory_no_follow(context.plan.stage_dir) ||
      !is_real_directory_no_follow(context.plan.profile_dir) {
      return render_raster_failed(
        "render.raster.stage", "render stage or Chromium profile was swapped",
      )
    }
    guard render_page_wrapper(context.plan, page, context.page_count)
      is Some(wrapper) else {
      return render_raster_failed(
        "render.wrapper.compose",
        "could not compose page \{page} wrapper",
      )
    }
    guard render_page_path(context.plan, page) is Some(output) else {
      return render_raster_failed(
        "render.raster.context",
        "could not construct page \{page} output path",
      )
    }
    let write_error : String? = try {
      remove_entry_no_follow(context.plan.wrapper_path)
      remove_entry_no_follow(output)
      @fs.write_file(
        context.plan.wrapper_path,
        wrapper,
        create_mode=CreateOrTruncate,
      )
      None
    } catch {
      error => Some("\{error}")
    } noraise {
      result => result
    }
    match write_error {
      Some(error) =>
        return render_raster_failed(
          "render.wrapper.write",
          "could not materialize page \{page} wrapper: \{error}",
        )
      None => ()
    }
    if !is_real_regular_no_follow(context.plan.wrapper_path) ||
      read_regular_text(context.plan.wrapper_path) != Some(wrapper) {
      return render_raster_failed(
        "render.wrapper.forged",
        "page \{page} wrapper is not the direct regular file that was written",
      )
    }
    guard build_screenshot_argv(
        context.plan,
        context.browser,
        page,
        timeout_secs~,
      )
      is Some(argv) else {
      return render_raster_failed(
        "render.raster.argv",
        "could not construct page \{page} Chromium command",
      )
    }
    let result = run(argv)
    if render_command_timed_out(result.code) {
      return render_raster_failed(
        "render.raster.timeout",
        "Chromium page \{page} capture exceeded its bounded runtime",
      )
    }
    if result.code != 0 {
      return render_raster_failed(
        "render.raster.exec",
        "Chromium page \{page} capture failed: \{render_command_detail(result)}",
      )
    }
    if !is_real_directory_no_follow(context.plan.stage_dir) ||
      !is_real_directory_no_follow(context.plan.profile_dir) {
      return render_raster_failed(
        "render.raster.stage", "render stage or Chromium profile was swapped",
      )
    }
    if !is_real_regular_no_follow(context.plan.wrapper_path) ||
      read_regular_text(context.plan.wrapper_path) != Some(wrapper) {
      return render_raster_failed(
        "render.wrapper.forged",
        "page \{page} wrapper was replaced during capture",
      )
    }
    guard read_real_binary_no_follow(output) is Some(data) else {
      return render_raster_failed(
        "render.raster.output",
        "page \{page} output is missing, unreadable, non-regular, or a symlink",
      )
    }
    match validate_page_png(data) {
      Some(code) =>
        return render_raster_failed(
          code,
          "page \{page} output failed the PNG contract",
        )
      None => ()
    }
  }
  finish_raster_stage(context)
}

///|
/// Production M3.2c entry: deterministic deck/tool/DOM preflight followed by
/// sequential fixed-page Chromium capture. Later units consume only the ready
/// page set; failure performs no PDF or publication work.
pub async fn raster_render(
  root : String,
  project : String,
  timeout_secs? : Int = default_render_timeout_secs,
) -> RenderRasterOutcome {
  match preflight_render(root, project, timeout_secs~) {
    PreflightFailed(failure) => RasterFailed(failure)
    PreflightReady(context) =>
      capture_render_pages_with(context, run=run_render_command, timeout_secs~)
  }
}

///|
/// Validate the exact no-follow stage-root layout around already-validated
/// page/PDF contents. Expected names are checked in page order; unexpected
/// names are codepoint-sorted so filesystem enumeration cannot perturb output.
pub fn validate_render_layout(
  entries : Array[RenderEntry],
  page_count : Int,
) -> Report {
  let out = Report::{ findings: [] }
  guard expected_render_names(page_count) is Some(expected) else {
    out.findings.push(
      must(
        "render.layout.page_count",
        "render page count must be in 1..=\{max_render_pages}",
      ),
    )
    return out
  }
  let expected_set = @set.Set(expected[:])
  for name in expected {
    let mut matches = 0
    let mut regular = false
    for entry in entries {
      if entry.name == name {
        matches = matches + 1
        regular = entry.regular
      }
    }
    if matches == 0 {
      out.findings.push(
        must("render.layout.missing", "missing staged artifact: \{name}"),
      )
    } else if matches > 1 {
      out.findings.push(
        must("render.layout.duplicate", "duplicate staged artifact: \{name}"),
      )
    } else if !regular {
      out.findings.push(
        must(
          "render.layout.not_regular",
          "staged artifact is not a real regular file: \{name}",
        ),
      )
    }
  }
  let unexpected : Array[String] = []
  for entry in entries {
    if !expected_set.contains(entry.name) {
      unexpected.push(entry.name)
    }
  }
  unexpected.sort_by(lex_compare)
  for name in unexpected {
    out.findings.push(
      must("render.layout.unexpected", "unexpected staged entry: \{name}"),
    )
  }
  out
}
