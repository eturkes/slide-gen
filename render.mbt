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
/// background services are suppressed. The validated deck itself is static;
/// these flags are defense-in-depth, not a browser sandbox claim.
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
  guard page_count >= 1 && page_count <= max_render_pages else { return None }
  let names : Array[String] = []
  for page in 1..<=page_count {
    guard render_page_name(page) is Some(name) else { return None }
    names.push(name)
  }
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
