// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// One three-tier `.entry` (JA / furigana / EN). Structurally complete for the
/// slide-count checks; its text content is exercised by later M2.1 slices.
fn entry() -> String {
  "<div class=\"entry\"><div class=\"jp\">a</div><div class=\"jpf\">a</div><div class=\"en\">A</div></div>"
}

///|
/// One `.eyebrow` with its `.n` section number.
fn eyebrow(n : String) -> String {
  "<div class=\"eyebrow\"><span class=\"n\">\{n}</span><span>l</span></div>"
}

///|
/// One `.pageno` footer carrying `text`.
fn pageno(text : String) -> String {
  "<div class=\"pageno\">\{text}</div>"
}

///|
/// A `<section class="slide">` from an eyebrow, an entries fragment, and a
/// pageno — the smallest deck slide that passes the M2.1b structure checks.
fn slide_of(e : String, es : String, p : String) -> String {
  "<section class=\"slide\">\{e}\{es}\{p}</section>"
}

///|
/// Assemble a deck's HTML from envelope parts. Every part defaults to a valid
/// value, so overriding one seeds a single defect in isolation. The default
/// section is a structurally complete one-slide deck (eyebrow + entry + pageno),
/// so envelope/image tests do not trip the M2.1b slide-structure checks.
fn envelope(
  doctype? : String = "<!doctype html>",
  html_open? : String = "<html lang=\"ja\">",
  charset? : String = "<meta charset=\"utf-8\">",
  style? : String = "<style>body{}</style>",
  body_open? : String = "<body>",
  sections? : String = slide_of(
    eyebrow("01"),
    entry(),
    pageno("project \u{b7} 1 / 1"),
  ),
  body_close? : String = "</body>",
  html_close? : String = "</html>",
) -> String {
  "\{doctype}\n\{html_open}\n<head>\n\{charset}\n\{style}\n</head>\n\{body_open}\n\{sections}\n\{body_close}\n\{html_close}\n"
}

///|
/// The empty asset set.
fn no_assets() -> @set.Set[String] {
  let empty : Array[String] = []
  @set.Set(empty[:])
}

///|
/// A well-formed envelope with one complete slide passes clean; a decoy
/// `<section class="slide">` and `<img>` living inside an HTML comment are
/// stripped up front and ignored.
test "good envelope passes; commented decoys ignored" {
  json_inspect(validate_deck(envelope(), "project", no_assets()).codes(), content=[])
  let with_decoy = envelope(
    sections="<!-- <section class=\"slide\"></section> <img src=\"assets/z.png\"> -->\{slide_of(eyebrow("01"), entry(), pageno("project \u{b7} 1 / 1"))}",
  )
  json_inspect(validate_deck(with_decoy, "project", no_assets()).codes(), content=[])
  // An <img> written inside a CSS comment in <style> is raw text, not markup.
  let css_img = envelope(
    style="<style>/* swap for <img src=…> */ .col-fig img{width:100%}</style>",
  )
  json_inspect(validate_deck(css_img, "project", no_assets()).codes(), content=[])
}

///|
/// The public `Report` surface: a clean deck is `ok` and renders `ok`; a
/// defective deck is not `ok` and renders a severity-labeled line.
test "report ok and render" {
  let clean = validate_deck(envelope(), "project", no_assets())
  assert_true(clean.ok())
  inspect(clean.render(), content="ok")
  let bad = validate_deck(envelope(doctype=""), "project", no_assets())
  assert_false(bad.ok())
  inspect(bad.render(), content="[MUST] frame.doctype: missing <!doctype html>")
}

///|
/// Each seeded envelope defect surfaces exactly its code and nothing else.
test "envelope defects each map to their code" {
  json_inspect(
    validate_deck(envelope(doctype=""), "project", no_assets()).codes(),
    content=["frame.doctype"],
  )
  json_inspect(
    validate_deck(
      envelope(html_open="<html lang=\"en\">"),
      "project",
      no_assets(),
    ).codes(),
    content=["frame.html_lang"],
  )
  json_inspect(
    validate_deck(envelope(charset=""), "project", no_assets()).codes(),
    content=["frame.charset"],
  )
  // An unclosed <style> is raw text to end of document (browser RAWTEXT-to-EOF),
  // so the body it swallows is gone: frame.style plus frame.body/no_slides.
  json_inspect(
    validate_deck(envelope(style="<style>body{}"), "project", no_assets()).codes(),
    content=["frame.style", "frame.body", "frame.no_slides"],
  )
  json_inspect(
    validate_deck(envelope(html_close=""), "project", no_assets()).codes(),
    content=["frame.body"],
  )
  json_inspect(
    validate_deck(envelope(sections=""), "project", no_assets()).codes(),
    content=["frame.no_slides"],
  )
}

///|
/// Attributed `<style>`/`<body>` (a `media`/`class` attribute) still satisfy the
/// frame checks — discovery is tag- and attribute-aware, not exact-literal.
test "attributed <style> and <body> pass the frame checks" {
  let attributed = envelope(
    style="<style media=\"screen\">body{}</style>",
    body_open="<body class=\"deck\">",
  )
  json_inspect(validate_deck(attributed, "project", no_assets()).codes(), content=[])
}

///|
/// A decoy `<img>` inside an unclosed `<style>` is swallowed with the rest of the
/// document (RAWTEXT-to-EOF), so it never surfaces as `img.not_asset`; only the
/// structural frame findings remain.
test "unclosed <style> swallows a decoy <img> rather than leaking img.not_asset" {
  let leaky = envelope(style="<style>/* <img src=\"foo.png\"> */")
  json_inspect(validate_deck(leaky, "project", no_assets()).codes(), content=[
    "frame.style", "frame.body", "frame.no_slides",
  ])
}

///|
/// A stray `</style>` before `<body>` must not satisfy `frame.style` for a real
/// `<style>` opened (and left unclosed) after `<body>`: the close must follow the
/// open it closes, else an unclosed style would validate clean.
test "frame.style requires the close to follow its own open" {
  let slide = slide_of(eyebrow("01"), entry(), pageno("project \u{b7} 1 / 1"))
  let deck = "<!doctype html>\n<html lang=\"ja\">\n<head>\n<meta charset=\"utf-8\">\n</style>\n</head>\n<body>\n\{slide}\n<style>body{}</body>\n</html>\n"
  json_inspect(validate_deck(deck, "project", no_assets()).codes(), content=[
    "frame.style", "frame.body",
  ])
}

///|
/// Image checks: a src outside `assets/` flags `img.not_asset`; a src under
/// `assets/` with no matching file flags `img.missing`; the same src with its
/// asset present passes clean.
test "image checks map to their codes" {
  let not_asset = envelope(
    sections=slide_of(
      eyebrow("01"),
      entry() + "<img src=\"foo.png\">",
      pageno("project \u{b7} 1 / 1"),
    ),
  )
  json_inspect(validate_deck(not_asset, "project", no_assets()).codes(), content=[
    "img.not_asset",
  ])
  let missing = envelope(
    sections=slide_of(
      eyebrow("01"),
      entry() + "<img src=\"assets/x.png\">",
      pageno("project \u{b7} 1 / 1"),
    ),
  )
  json_inspect(validate_deck(missing, "project", no_assets()).codes(), content=[
    "img.missing",
  ])
  let present : @set.Set[String] = @set.Set(["assets/x.png"][:])
  json_inspect(validate_deck(missing, "project", present).codes(), content=[])
}

///|
/// Each seeded slide-structure defect surfaces exactly its code. Every valid
/// member carries correct text — the first `.eyebrow`/`.pageno` is well-formed —
/// so only the structural defect surfaces, never a spurious text finding: a
/// duplicate `.eyebrow`/`.pageno` breaks the "exactly one" count, and a slide
/// with no `.entry` flags `slide.no_entry`.
test "slide structure defects each map to their code" {
  let dup_eyebrow = envelope(
    sections=slide_of(
      eyebrow("01") + eyebrow("02"),
      entry(),
      pageno("project \u{b7} 1 / 1"),
    ),
  )
  json_inspect(validate_deck(dup_eyebrow, "project", no_assets()).codes(), content=[
    "slide.eyebrow_count",
  ])
  let dup_pageno = envelope(
    sections=slide_of(
      eyebrow("01"),
      entry(),
      pageno("project \u{b7} 1 / 1") + pageno("b"),
    ),
  )
  json_inspect(validate_deck(dup_pageno, "project", no_assets()).codes(), content=[
    "slide.pageno_count",
  ])
  let no_entry = envelope(
    sections=slide_of(eyebrow("01"), "", pageno("project \u{b7} 1 / 1")),
  )
  json_inspect(validate_deck(no_entry, "project", no_assets()).codes(), content=[
    "slide.no_entry",
  ])
}

///|
/// A two-slide deck with correct section numbers and page-number footers passes
/// clean: each slide's `.eyebrow .n` is its two-digit 1-based index and its
/// `.pageno` reads `"<slug> · <n> / <total>"`.
test "well-formed multi-slide deck passes the text checks" {
  let s1 = slide_of(eyebrow("01"), entry(), pageno("proj \u{b7} 1 / 2"))
  let s2 = slide_of(eyebrow("02"), entry(), pageno("proj \u{b7} 2 / 2"))
  json_inspect(
    validate_deck(envelope(sections=s1 + s2), "proj", no_assets()).codes(),
    content=[],
  )
}

///|
/// The `.pageno` text is compared after entity decoding, so a slug carrying a
/// character escaped in the deck (`A&amp;B`) matches the raw slug `A&B`.
test "pageno format compares decoded text" {
  let deck = envelope(
    sections=slide_of(eyebrow("01"), entry(), pageno("A&amp;B \u{b7} 1 / 1")),
  )
  json_inspect(validate_deck(deck, "A&B", no_assets()).codes(), content=[])
}

///|
/// Each seeded slide-text defect surfaces exactly its code: a wrong `.eyebrow .n`
/// flags `slide.eyebrow_n`, and a wrong `.pageno` flags `slide.pageno_format`.
test "slide text defects each map to their code" {
  let wrong_n = envelope(
    sections=slide_of(eyebrow("99"), entry(), pageno("project \u{b7} 1 / 1")),
  )
  json_inspect(validate_deck(wrong_n, "project", no_assets()).codes(), content=[
    "slide.eyebrow_n",
  ])
  let bad_pageno = envelope(
    sections=slide_of(eyebrow("01"), entry(), pageno("wrong")),
  )
  json_inspect(validate_deck(bad_pageno, "project", no_assets()).codes(), content=[
    "slide.pageno_format",
  ])
}

///|
/// A single `.eyebrow` holding two `.n` spans is a defect even when the first
/// reads the right number: `scan_deck` captures the `.n` only when it is unique,
/// so `slide.eyebrow_n` fires. Closes the first-only false negative where a
/// stray second `.n` (here `99`) rode along unchecked.
test "duplicate .n inside one eyebrow flags slide.eyebrow_n" {
  let two_n = "<div class=\"eyebrow\"><span class=\"n\">01</span><span class=\"n\">99</span></div>"
  let deck = envelope(
    sections=slide_of(two_n, entry(), pageno("project \u{b7} 1 / 1")),
  )
  json_inspect(validate_deck(deck, "project", no_assets()).codes(), content=[
    "slide.eyebrow_n",
  ])
}

///|
/// The text checks are gated on their owning count being 1, so one absent slot
/// yields one finding, not two: a slide missing its `.eyebrow` reports only
/// `slide.eyebrow_count` (never also `slide.eyebrow_n`), and a slide missing its
/// `.pageno` reports only `slide.pageno_count` (never also `slide.pageno_format`).
test "a missing slot reports only its count, not the text code" {
  let no_eyebrow = envelope(
    sections=slide_of("", entry(), pageno("project \u{b7} 1 / 1")),
  )
  json_inspect(validate_deck(no_eyebrow, "project", no_assets()).codes(), content=[
    "slide.eyebrow_count",
  ])
  let no_pageno = envelope(sections=slide_of(eyebrow("01"), entry(), ""))
  json_inspect(validate_deck(no_pageno, "project", no_assets()).codes(), content=[
    "slide.pageno_count",
  ])
}

///|
/// Frame checks are fail-closed against attribute-embedded tag literals: a
/// `<style></style>` sitting inside a quoted attribute value, with no real
/// `<style>` element, must NOT satisfy `frame.style`. The quote-aware
/// `find_all_open_tags` steps over the attribute as part of its host tag, so the
/// decoy is invisible and `frame.style` fires.
test "attr-embedded <style> literal does not satisfy frame.style" {
  let decoy = envelope(style="<div data-x=\"<style></style>\"></div>")
  json_inspect(validate_deck(decoy, "project", no_assets()).codes(), content=[
    "frame.style",
  ])
}

///|
/// A `<div class="slide">` wrapper does not hide a real `<section class="slide">`
/// nested inside it: `scan_deck` descends through the non-section wrapper and
/// checks the inner slide, so a malformed nested slide (here missing its
/// `.entry`) still flags rather than escaping validation.
test "section.slide nested under a div.slide wrapper is still checked" {
  let wrapped = envelope(
    sections="<div class=\"slide\">" +
      slide_of(eyebrow("01"), "", pageno("project \u{b7} 1 / 1")) +
      "</div>",
  )
  json_inspect(validate_deck(wrapped, "project", no_assets()).codes(), content=[
    "slide.no_entry",
  ])
}

///|
/// `validate_deck_dir` reads a bundle from disk: a deck referencing an asset that
/// exists passes; a bundle with no `assets/` directory and no images also passes,
/// proving a missing assets dir is not an error.
async test "validate_deck_dir over a disk bundle" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="slide-gen-validate")
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    @fs.mkdir("\{dir}/assets")
    @fs.write_file("\{dir}/assets/x.png", "", create_mode=CreateOrTruncate)
    let deck = envelope(
      sections=slide_of(
        eyebrow("01"),
        entry() + "<img src=\"assets/x.png\">",
        pageno("project \u{b7} 1 / 1"),
      ),
    )
    @fs.write_file("\{dir}/deck.html", deck, create_mode=CreateOrTruncate)
    json_inspect(validate_deck_dir(dir, "project").codes(), content=[])
    let bare = @fs.tmpdir(prefix="slide-gen-validate-bare")
    group.add_defer(() => @fs.rmdir(bare, recursive=true))
    @fs.write_file(
      "\{bare}/deck.html",
      envelope(),
      create_mode=CreateOrTruncate,
    )
    json_inspect(validate_deck_dir(bare, "project").codes(), content=[])
  }
}

///|
/// The shipped `templates/deck.html` passes the full envelope, slide-structure,
/// slide-text, and image checks with slug `project`: the hand-authored template
/// (two slides, section numbers `01`/`02`, page footers `project · n / 2`) is the
/// positive contract. Located via the repo root so it runs under `moon test`
/// regardless of cwd; skipped only if the root cannot be found.
async test "shipped template frame and slides are clean" {
  guard find_repo_root() is Some(root) else { return }
  let html = @fs.read_file("\{root}/templates/deck.html").text()
  let assets = list_assets("\{root}/templates")
  json_inspect(validate_deck(html, "project", assets).codes(), content=[])
}
