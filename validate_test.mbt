// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// One three-tier `.entry` (JA / furigana / EN). Structurally complete; its `.jp`
/// and `.jpf` match and it carries no kanji, so it passes the M2.1c entry checks.
fn entry() -> String {
  "<div class=\"entry\"><div class=\"jp\">a</div><div class=\"jpf\">a</div><div class=\"en\">A</div></div>"
}

///|
/// A three-tier `.entry` from explicit `.jp`, `.jpf`, and `.en` inner HTML, for
/// exercising the M2.1c entry and furigana checks.
fn entry_of(jp : String, jpf : String, en : String) -> String {
  "<div class=\"entry\"><div class=\"jp\">\{jp}</div><div class=\"jpf\">\{jpf}</div><div class=\"en\">\{en}</div></div>"
}

///|
/// A one-slide deck whose single `.entry` is `e`, for exercising entry checks in
/// isolation (slug `project`, section `01`, footer `project · 1 / 1`).
fn deck_with_entry(e : String) -> String {
  envelope(sections=slide_of(eyebrow("01"), e, pageno("project \u{b7} 1 / 1")))
}

///|
/// A valid one-slide deck with the fragment after its required entry. Security
/// tests use this to seed markup without perturbing the slide/tier contract.
fn deck_with_fragment(fragment : String) -> String {
  envelope(
    sections=slide_of(
      eyebrow("01"),
      entry() + fragment,
      pageno("project \u{b7} 1 / 1"),
    ),
  )
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
/// Cleaning and tag discovery remain fail-closed around authored decoys: comment
/// and raw-text openers inside quoted attributes cannot blank a later invalid
/// image, and a stray text `<` cannot swallow that image's real opening tag.
test "quoted cleaner decoys and stray text less-than cannot hide markup" {
  let comment_decoy = envelope(
    sections=slide_of(
      eyebrow("01"),
      entry() +
      "<span title=\"<!--\">x</span><img src=\"bad.png\"><span title=\"-->\">y</span>",
      pageno("project \u{b7} 1 / 1"),
    ),
  )
  json_inspect(validate_deck(comment_decoy, "project", no_assets()).codes(), content=[
    "img.not_asset",
  ])
  let raw_decoy = envelope(
    sections=slide_of(
      eyebrow("01"),
      entry() +
      "<span title=\"<style>\">x</span><img src=\"bad.png\"><span title=\"</style>\">y</span>",
      pageno("project \u{b7} 1 / 1"),
    ),
  )
  json_inspect(validate_deck(raw_decoy, "project", no_assets()).codes(), content=[
    "img.not_asset",
  ])
  let stray = envelope(
    sections=slide_of(
      eyebrow("01"),
      entry() + "<span>5 < 6</span><img src=\"bad.png\">",
      pageno("project \u{b7} 1 / 1"),
    ),
  )
  json_inspect(validate_deck(stray, "project", no_assets()).codes(), content=[
    "img.not_asset",
  ])
}

///|
/// Frame tokens must be real markup, never strings inside quoted attributes.
/// A doctype decoy cannot replace the declaration and a close-tag decoy cannot
/// close an otherwise unclosed body.
test "attribute literals cannot satisfy doctype or body-close checks" {
  let doctype_decoy = envelope(
    doctype="",
    sections="<div title=\"<!doctype html>\"></div>" +
      slide_of(eyebrow("01"), entry(), pageno("project \u{b7} 1 / 1")),
  )
  json_inspect(validate_deck(doctype_decoy, "project", no_assets()).codes(), content=[
    "frame.doctype",
  ])
  let close_decoy = envelope(
    sections="<div title=\"</body>\"></div>" +
      slide_of(eyebrow("01"), entry(), pageno("project \u{b7} 1 / 1")),
    body_close="",
  )
  json_inspect(validate_deck(close_decoy, "project", no_assets()).codes(), content=[
    "frame.body",
  ])
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
  // URL/HTML metacharacters never pass merely because a raw filesystem entry
  // with the same spelling exists; browser decoding could target another path.
  let suspicious = [
    "assets/%2e%2e%2fsecret.png", "assets/a&sol;b.png", "assets/a?b.png", "assets/a#b.png",
    "assets/a\\b.png",
  ]
  let suspicious_files : @set.Set[String] = @set.Set(suspicious[:])
  for src in suspicious {
    let deck = envelope(
      sections=slide_of(
        eyebrow("01"),
        entry() + "<img src=\"\{src}\">",
        pageno("project \u{b7} 1 / 1"),
      ),
    )
    json_inspect(validate_deck(deck, "project", suspicious_files).codes(), content=[
      "img.not_asset",
    ])
  }
}

///|
/// Executable, embedded, navigation/submission, and meta HTTP directives block
/// through one category code. Tag/attribute matching is ASCII-case-insensitive,
/// and the diagnostic decodes the directive like the browser.
test "static contract rejects active embedded and navigating markup" {
  for
    markup in [
      "<ScRiPt type=\"application/json\">{}</ScRiPt>", "<IFRAME></IFRAME>", "<a>navigation</a>",
      "<form></form>", "<svg></svg>", "<!--><SCRIPT></SCRIPT>", "<!---><IFRAME></IFRAME>",
      "<!foo>", "<?x \"?><SCRIPT></SCRIPT>\">", "<meta name=\"viewport\" content=\"width=device-width\">",
    ] {
    json_inspect(
      validate_deck(deck_with_fragment(markup), "project", no_assets()).codes(),
      content=["static.active_markup"],
    )
  }
  let refresh = "<meta http-equiv=\"&#114efresh\" content=\"0; https://example.invalid\">"
  let refresh_report = validate_deck(
    deck_with_fragment(refresh),
    "project",
    no_assets(),
  )
  json_inspect(refresh_report.codes(), content=["static.active_markup"])
  assert_true(refresh_report.render().contains("<meta http-equiv=refresh>"))
}

///|
/// Event attributes and every non-image resource attribute block. An event-like
/// string inside another quoted attribute is inert and cannot hide the later
/// mixed-case real handler; input[src] proves src is allowed only on img.
test "static contract rejects event and non-image resource attributes" {
  let event = "<div title=\"<script onload=x>\" oNcLiCk=\"alert(1)\">x</div>"
  json_inspect(
    validate_deck(deck_with_fragment(event), "project", no_assets()).codes(),
    content=["static.event_handler"],
  )
  let resource = "<input type=\"image\" SRC=\"assets/local.png\">"
  json_inspect(
    validate_deck(deck_with_fragment(resource), "project", no_assets()).codes(),
    content=["static.resource"],
  )
}

///|
/// CSS imports and URL-bearing functions block in both style RAWTEXT and an
/// inline style attribute. The inline spelling uses an HTML numeric reference to
/// ensure the security pass sees the browser-decoded CSS, not only source text.
test "static contract rejects CSS imports and entity-obscured URLs" {
  let imported = envelope(
    style="<style>@IMPORT \"https://example.invalid/deck.css\";</style>",
  )
  json_inspect(validate_deck(imported, "project", no_assets()).codes(), content=[
    "static.css_resource",
  ])
  let inline = "<span style=\"background:u&#114l(https://example.invalid/x.png)\">x</span>"
  json_inspect(
    validate_deck(deck_with_fragment(inline), "project", no_assets()).codes(),
    content=["static.css_resource"],
  )
}

///|
/// HTML comments, quoted attribute values, entity-encoded markup, RCDATA, CSS
/// comments, and CSS strings are inert parser contexts. Their hostile-looking
/// text must not trigger the static gate; a normal gradient remains valid CSS.
test "static contract ignores comment quote entity and raw-text decoys" {
  let style = "<style>/* @import \"x\"; url(https://x) <script src=x> */\n.x::before{content:\"@import url(https://x) <iframe src=x>\"}\n.x{background:linear-gradient(#fff,#000)}</style>"
  let decoys = "<!-- <script src=x></script><iframe src=x></iframe> -->" +
    "<span title=\"<script src=x onload=x> href=https://x\">safe</span>" +
    "&lt;iframe src=https://x&gt;" +
    "<textarea><script src=https://x></script></textarea>"
  let deck = envelope(
    style~,
    sections=slide_of(
      eyebrow("01"),
      entry() + decoys,
      pageno("project \u{b7} 1 / 1"),
    ),
  )
  json_inspect(validate_deck(deck, "project", no_assets()).codes(), content=[])
}

///|
/// Skipping a real style RAWTEXT body ends exactly at its close tag: an iframe-
/// shaped CSS string stays inert, while a real iframe after the close is still
/// discovered and blocked.
test "static raw-text scan resumes at real closing tag" {
  let deck = envelope(
    style="<style>.x::before{content:\"<iframe src=x>\"}</style>",
    sections=slide_of(
      eyebrow("01"),
      entry() + "<IFRAME></IFRAME>",
      pageno("project \u{b7} 1 / 1"),
    ),
  )
  json_inspect(validate_deck(deck, "project", no_assets()).codes(), content=[
    "static.active_markup",
  ])
  // HTML RAWTEXT closes even when `</style>` looks quoted to CSS; the following
  // script is therefore real markup and must remain visible to the static scan.
  let quoted_close = envelope(
    style="<style>.x::before{content:\"</style><SCRIPT></SCRIPT>\"}",
  )
  json_inspect(validate_deck(quoted_close, "project", no_assets()).codes(), content=[
    "static.active_markup",
  ])
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
/// A well-formed furigana entry passes: `.jp` and `.jpf` share the same base
/// text, every `.jpf` kanji is covered per character (a `要点` run split across
/// two adjacent single-kanji ruby groups still passes), each `<ruby>` has one
/// all-kana `<rt>`, a kanji inside a `<code>` span is exempt from coverage, and
/// no ruby lives outside `.jpf`.
test "well-formed furigana entry passes" {
  let jpf = "<ruby>要<rt>よう</rt></ruby><ruby>点<rt>てん</rt></ruby>は<code>図</code>"
  let good = entry_of("要点は<code>図</code>", jpf, "A")
  json_inspect(
    validate_deck(deck_with_entry(good), "project", no_assets()).codes(),
    content=[],
  )
}

///|
/// Each seeded entry or furigana defect surfaces exactly its code: tiers out of
/// order (`entry.tiers`, which gates the rest); `.jp`/`.jpf` base text that
/// disagrees (`entry.ja_pairing`); an `<rt>` reading carrying a kanji
/// (`ruby.rt_not_kana`); a `<ruby>` with two `<rt>` (`ruby.rt_count`); a bare
/// kanji in `.jpf` with no covering ruby (`ruby.kanji_uncovered`); and a
/// `<ruby>` in the `.jp` tier, outside `.jpf` (`ruby.rt_outside_jpf`).
test "entry and furigana defects each map to their code" {
  let bad_tiers = "<div class=\"entry\"><div class=\"jpf\">a</div><div class=\"jp\">a</div><div class=\"en\">A</div></div>"
  json_inspect(
    validate_deck(deck_with_entry(bad_tiers), "project", no_assets()).codes(),
    content=["entry.tiers"],
  )
  let unpaired = entry_of("要", "<ruby>点<rt>てん</rt></ruby>", "A")
  json_inspect(
    validate_deck(deck_with_entry(unpaired), "project", no_assets()).codes(),
    content=["entry.ja_pairing"],
  )
  let rt_kanji = entry_of("要", "<ruby>要<rt>ヨ点</rt></ruby>", "A")
  json_inspect(
    validate_deck(deck_with_entry(rt_kanji), "project", no_assets()).codes(),
    content=["ruby.rt_not_kana"],
  )
  let two_rt = entry_of("要", "<ruby>要<rt>よ</rt><rt>う</rt></ruby>", "A")
  json_inspect(
    validate_deck(deck_with_entry(two_rt), "project", no_assets()).codes(),
    content=["ruby.rt_count"],
  )
  let uncovered = entry_of("図", "図", "A")
  json_inspect(
    validate_deck(deck_with_entry(uncovered), "project", no_assets()).codes(),
    content=["ruby.kanji_uncovered"],
  )
  let outside = entry_of(
    "<ruby>要<rt>よう</rt></ruby>", "<ruby>要<rt>よう</rt></ruby>", "A",
  )
  json_inspect(
    validate_deck(deck_with_entry(outside), "project", no_assets()).codes(),
    content=["ruby.rt_outside_jpf"],
  )
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
/// slide-text, entry/furigana, and image checks with slug `project`: the
/// hand-authored template (two slides, section numbers `01`/`02`, page footers
/// `project · n / 2`, and real three-tier ruby entries) is the positive contract.
/// Located via the repo root so it runs under `moon test` regardless of cwd;
/// skipped only if the root cannot be found.
async test "shipped template frame and slides are clean" {
  guard find_repo_root() is Some(root) else { return }
  let html = @fs.read_file("\{root}/templates/deck.html").text()
  let assets = list_assets("\{root}/templates")
  json_inspect(validate_deck(html, "project", assets).codes(), content=[])
}
