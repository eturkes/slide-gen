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
      #|<body><iframe title="slide page 2" src="file:///w/My%20Root/decks/quo%22te%20%E9%81%93/deck.html" scrolling="no"></iframe></body>
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
      "--no-sandbox", "--disable-gpu", "--force-device-scale-factor=1", "--window-size=2560,1440",
      "--hide-scrollbars", "--user-data-dir=/w/My Root/renders/.partial/rehab's 道/.chromium-profile",
      "--proxy-server=http://127.0.0.1:9", "--proxy-bypass-list=<-loopback>", "--host-resolver-rules=MAP * ~NOTFOUND",
      "--disable-background-networking", "--disable-component-update", "--disable-default-apps",
      "--disable-sync", "--metrics-recording-only", "--no-first-run", "--dump-dom",
      "file:///w/My%20Root/decks/rehab%27s%20%E9%81%93/deck.html",
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
/// img2pdf receives the lossless deterministic options before numerically
/// ordered page paths and writes only the stage PDF.
test "img2pdf argv preserves page order and 72-dpi lossless options" {
  let plan = test_render_plan("/", "project")
  json_inspect(build_img2pdf_argv(plan, 3, timeout_secs=90).unwrap_or([]), content=[
    "timeout", "--kill-after=30", "90", "uv", "run", "--locked", "--no-dev", "img2pdf",
    "--nodate", "--engine=internal", "--imgsize=72dpi", "--rotation=none", "--output",
    "/renders/.partial/project/deck.pdf", "/renders/.partial/project/page_01.png",
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
