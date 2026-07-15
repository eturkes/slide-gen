// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// `get_attr` reads double-, single-, and unquoted values plus boolean
/// attributes, matches the name case-insensitively, and returns `None` when the
/// attribute is absent. Whitebox: the scan primitives are private.
test "get_attr value forms" {
  let region = " Lang=\"ja\" data-x='7' n=3 flag ".to_array()
  let hi = region.length()
  inspect(get_attr(region, 0, hi, "lang").unwrap_or("<absent>"), content="ja")
  inspect(get_attr(region, 0, hi, "data-x").unwrap_or("<absent>"), content="7")
  inspect(get_attr(region, 0, hi, "n").unwrap_or("<absent>"), content="3")
  inspect(get_attr(region, 0, hi, "flag").unwrap_or("<absent>"), content="")
  inspect(
    get_attr(region, 0, hi, "missing").unwrap_or("<absent>"),
    content="<absent>",
  )
  // A duplicate attribute resolves to its first occurrence (HTML parse behavior).
  let dup = " class=\"a\" class=\"b\" ".to_array()
  inspect(
    get_attr(dup, 0, dup.length(), "class").unwrap_or("<absent>"),
    content="a",
  )
}

///|
/// `has_class` matches a whole whitespace-delimited class token, never a
/// substring of one — so `col-fig tall` has `tall` and `col-fig` but not `col`.
test "has_class whole-token match" {
  let region = " class=\"col-fig tall\" ".to_array()
  let hi = region.length()
  assert_true(has_class(region, 0, hi, "tall"))
  assert_true(has_class(region, 0, hi, "col-fig"))
  assert_false(has_class(region, 0, hi, "col"))
  assert_false(has_class(region, 0, hi, "fig"))
}

///|
/// `clean_doc` drops comments, blanks raw-text bodies, and treats each ordinary
/// tag as one quote-aware unit. Comment/raw-text-shaped attribute values remain
/// inert instead of hiding the real markup after their host tag.
test "clean_doc handles comments raw text and quoted decoys in one pass" {
  let a = clean_doc("a<!--b-->c".to_array())
  inspect(range_to_string(a, 0, a.length()), content="ac")
  let b = clean_doc("keep<!--x".to_array())
  inspect(range_to_string(b, 0, b.length()), content="keep")
  let c = clean_doc("<!--only-->".to_array())
  inspect(range_to_string(c, 0, c.length()), content="")
  let style = clean_doc("<style><img src=x></style>keep".to_array())
  inspect(
    range_to_string(style, 0, style.length()),
    content="<style></style>keep",
  )
  let script = clean_doc("x<script>a<b</script>y".to_array())
  inspect(
    range_to_string(script, 0, script.length()),
    content="x<script></script>y",
  )
  // </stylex> is not a name-boundary close, so blanking continues to the real one.
  let d = clean_doc("<style>x</stylex>y</style>z".to_array())
  inspect(range_to_string(d, 0, d.length()), content="<style></style>z")
  // Unterminated raw-text runs to end of document, so its remainder is blanked.
  let unclosed = clean_doc("<style>body{}".to_array())
  inspect(range_to_string(unclosed, 0, unclosed.length()), content="<style>")
  let quoted = clean_doc(
    "<div data-a='<!--' data-b=\"<style>\"></div><span>kept</span>".to_array(),
  )
  inspect(
    range_to_string(quoted, 0, quoted.length()),
    content="<div data-a='<!--' data-b=\"<style>\"></div><span>kept</span>",
  )
}

///|
/// `match_close` depth-matches a nested same-name element, so a child's close
/// tag does not end the parent: `<div><div></div></div>` resolves to the outer
/// `</div>` (its `<` at index 16, past-`>` at 22), not the inner one at 10.
test "match_close depth-matches nested same-name tags" {
  let doc = "<div><div></div></div>".to_array()
  // from = 5, just past the outer <div>'s '>'.
  let (close_lt, past_gt) = match_close(doc, "div", 5, doc.length())
  inspect("\{close_lt}|\{past_gt}", content="16|22")
}

///|
/// `find_by_class` reports outermost matches as siblings and never descends into
/// a match's body, so a nested same-class element is not double-counted: an outer
/// `.x` wrapping an inner `.x`, plus a sibling `.x`, yields exactly two elements.
test "find_by_class reports siblings, not nested duplicates" {
  let doc = "<div class=\"x\"><div class=\"x\">inner</div></div><div class=\"x\">sib</div>".to_array()
  let elems = find_by_class(doc, 0, doc.length(), ["x"])
  assert_eq(elems.length(), 2)
  // The second match is the sibling, not the nested inner .x.
  inspect(range_to_string(doc, elems[1].lo, elems[1].hi), content="sib")
}

///|
/// Numeric HTML tag names are scanned and depth-matched in full: an `h2` class
/// match ends at `</h2>` and cannot consume a later sibling match.
test "find_by_class preserves numeric tag names" {
  let doc = "<h2 class=\"x\">head</h2><div class=\"x\">tail</div>".to_array()
  let elems = find_by_class(doc, 0, doc.length(), ["x"])
  assert_eq(elems.length(), 2)
  inspect(range_to_string(doc, elems[0].lo, elems[0].hi), content="head")
  inspect(range_to_string(doc, elems[1].lo, elems[1].hi), content="tail")
}

///|
/// `scan_deck` parses a `<section class="slide">` into one `Slide`: it tallies the
/// outermost `.eyebrow`/`.pageno`/`.entry` descendants (the nested `.n` and `.jp`
/// are inside skipped bodies, so they do not inflate the counts) and captures the
/// `.eyebrow .n` text and the `.pageno` text.
test "scan_deck parses one builder slide" {
  let html = "<section class=\"slide\"><div class=\"eyebrow\"><span class=\"n\">01</span></div><div class=\"entry\"><div class=\"jp\">a</div></div><div class=\"pageno\">p</div></section>"
  let slides = scan_deck(html.to_array())
  assert_eq(slides.length(), 1)
  inspect(
    "\{slides[0].eyebrow_count}|\{slides[0].pageno_count}|\{slides[0].entries.length()}",
    content="1|1|1",
  )
  inspect(
    "\{slides[0].eyebrow_n.unwrap_or("<none>")}|\{slides[0].pageno_text.unwrap_or("<none>")}",
    content="01|p",
  )
}

///|
/// `decode_entities` decodes named, decimal, and hexadecimal references, keeps an
/// unknown name or a reference missing its `;` literal, and is total on a bare
/// `&`.
test "decode_entities named, numeric, and literal fallback" {
  inspect(decode_entities("a&amp;b"), content="a&b")
  inspect(decode_entities("&lt;tag&gt;"), content="<tag>")
  inspect(decode_entities("x&#183;y"), content="x\u{b7}y")
  inspect(decode_entities("x&#xB7;y"), content="x\u{b7}y")
  inspect(decode_entities("&foo;"), content="&foo;")
  inspect(decode_entities("Q&A"), content="Q&A")
  inspect(decode_entities("&amp"), content="&amp")
}

///|
/// `decode_entities` is total and safe at the numeric boundaries: a surrogate
/// (`&#xD800;`) and an over-max code point (`&#x110000;`) are rejected and kept
/// literal (the `> 0x10FFFF` guard short-circuits before any accumulator
/// overflow, then `Int::to_char` rejects surrogates); the maximum scalar
/// `&#x10FFFF;` decodes (boundary inclusive, not off-by-one); long leading zeros
/// build the same code without overflow; named references are case-sensitive; and
/// a digitless numeric reference stays literal.
test "decode_entities boundary and totality" {
  inspect(decode_entities("&#xD800;"), content="&#xD800;")
  inspect(decode_entities("&#x110000;"), content="&#x110000;")
  assert_false(decode_entities("&#x10FFFF;") == "&#x10FFFF;")
  inspect(decode_entities("&#00000000000000183;"), content="\u{b7}")
  inspect(decode_entities("&AMP;"), content="&AMP;")
  inspect(decode_entities("&#;"), content="&#;")
  inspect(decode_entities("&#x;"), content="&#x;")
}

///|
/// Totality property: a `&` that does not begin a well-formed reference is kept
/// verbatim, so decoding a fragment with no valid reference is the identity and
/// never traps — including a decimal run long enough to overflow `Int` were the
/// `> 0x10FFFF` guard absent.
test "decode_entities leaves malformed references verbatim" {
  let malformed = [
    "&", "&#", "&#x", "&;", "&#;", "&#x;", "&xyz", "&#xG;", "a&&b", "&#z;", "&#99999999999999999999;",
  ]
  for m in malformed {
    assert_eq(decode_entities(m), m)
  }
}

///|
/// `inner_text` drops tags (quote-aware), decodes character references, and trims
/// surrounding ASCII whitespace, so an element body yields its plain text.
test "inner_text drops tags, decodes, and trims" {
  let doc = "  <span class=\"n\">01</span> A&amp;B \u{b7} 1 ".to_array()
  inspect(inner_text(doc, 0, doc.length()), content="01 A&B \u{b7} 1")
}

///|
/// `find_all_open_tags` is quote-aware: a `<meta>` written inside a quoted
/// attribute value is stepped over as part of its host tag, so only the real
/// `<meta>` element is reported — the property the frame checks rely on to stay
/// fail-closed against attribute-embedded tag literals.
test "find_all_open_tags ignores a tag literal inside a quoted attribute" {
  let doc = "<div data-x=\"<meta charset=x>\"><meta charset=\"utf-8\"></div>".to_array()
  let metas = find_all_open_tags(doc, "meta")
  assert_eq(metas.length(), 1)
  // The one reported open tag is the real element, not the attribute literal.
  let (_, lo, hi, _) = scan_open_tag(doc, metas[0])
  inspect(
    get_attr(doc, lo, hi, "charset").unwrap_or("<absent>"),
    content="utf-8",
  )
}

///|
/// `match_close` on a void `name` returns `(from, from)` (no content span), and
/// on an unbalanced element that never closes it returns `(end, end)`.
test "match_close: void element and unbalanced input" {
  let img = "<img>tail".to_array()
  let (a, b) = match_close(img, "img", 5, img.length())
  inspect("\{a}|\{b}", content="5|5")
  let div = "<div>abc".to_array()
  let (c, d) = match_close(div, "div", 5, div.length())
  inspect("\{c}|\{d}", content="8|8")
}

///|
/// `normalize_ja` reduces a JA tier to comparable base text: it strips tags but
/// keeps their text nodes, drops each `<rt>` reading, decodes character
/// references, and collapses/trims whitespace. So a `.jpf` furigana tier
/// normalizes to the same string as its bare-kanji `.jp` counterpart.
test "normalize_ja drops rt, strips tags, decodes, and collapses" {
  inspect(
    normalize_ja("<ruby>要<rt>よう</rt></ruby>点<code>x</code>"),
    content="要点x",
  )
  inspect(normalize_ja("  a &amp;  b  "), content="a & b")
}

///|
/// `is_kanji` and `is_kana` classify by Unicode range: a CJK ideograph is kanji
/// but not kana, a hiragana or katakana character is kana but not kanji, and a
/// Latin letter is neither.
test "is_kanji and is_kana ranges" {
  assert_true(is_kanji('要'))
  assert_false(is_kanji('よ'))
  assert_false(is_kanji('a'))
  assert_true(is_kana('よ'))
  assert_true(is_kana('ヨ'))
  assert_false(is_kana('要'))
  assert_false(is_kana('a'))
}

///|
/// `check_jpf_ruby` covers kanji per character (a `要点` run split across two
/// adjacent single-kanji ruby groups is fully covered), exempts a kanji inside a
/// `<code>` span, and flags a bare kanji sitting outside any ruby or code as
/// `ruby.kanji_uncovered`.
test "check_jpf_ruby per-kanji coverage and code exemption" {
  let split = Report::{ findings: [] }
  check_jpf_ruby(
    "<ruby>要<rt>よう</rt></ruby><ruby>点<rt>てん</rt></ruby>", split,
  )
  json_inspect(split.codes(), content=[])
  let coded = Report::{ findings: [] }
  check_jpf_ruby("<code>図</code>", coded)
  json_inspect(coded.codes(), content=[])
  let bare = Report::{ findings: [] }
  check_jpf_ruby("要点", bare)
  json_inspect(bare.codes(), content=["ruby.kanji_uncovered"])
  let encoded = Report::{ findings: [] }
  check_jpf_ruby("&#x8981;", encoded)
  json_inspect(encoded.codes(), content=["ruby.kanji_uncovered"])
}

///|
/// An unclosed `<ruby>` never reaches its close-tag `rt_count` check mid-scan, so
/// the end-of-scan guard must still flag it (`ruby.rt_count`); its lone open kanji
/// counts as covered (inside the open ruby base), proving the guard is what fires.
test "check_jpf_ruby flags an unclosed ruby" {
  let unclosed = Report::{ findings: [] }
  check_jpf_ruby("<ruby>要<rt>よう</rt>", unclosed)
  json_inspect(unclosed.codes(), content=["ruby.rt_count"])
}

///|
/// `scan_deck` fills each `.entry` with its tier elements in document order and
/// captures the raw inner HTML of each tier, so the entry checks see `.jp`,
/// `.jpf`, `.en` and the furigana markup inside `.jpf`.
test "scan_deck fills entry tiers" {
  let html = "<section class=\"slide\"><div class=\"eyebrow\"><span class=\"n\">01</span></div><div class=\"entry\"><div class=\"jp\">要</div><div class=\"jpf\"><ruby>要<rt>よう</rt></ruby></div><div class=\"en\">A</div></div><div class=\"pageno\">p</div></section>"
  let slides = scan_deck(html.to_array())
  assert_eq(slides.length(), 1)
  let e = slides[0].entries[0]
  json_inspect(e.tiers.map(fn(t) { t.cls }), content=["jp", "jpf", "en"])
  inspect(e.tiers[1].html, content="<ruby>要<rt>よう</rt></ruby>")
}

///|
/// `classify_tag` retains a complete numeric/custom tag name, so `<rt2>` and
/// `<ruby-foo>` remain distinct from `<rt>`/`<ruby>`.
test "classify_tag preserves complete tag names" {
  let rt2 = "<rt2>".to_array()
  let (name_rt2, _, _) = classify_tag(rt2, 0, rt2.length())
  inspect(name_rt2, content="rt2")
  let ruby_foo = "<ruby-foo>".to_array()
  let (name_rf, _, _) = classify_tag(ruby_foo, 0, ruby_foo.length())
  inspect(name_rf, content="ruby-foo")
  let rt_foo = "<rt_foo>".to_array()
  let (name_rt_foo, _, _) = classify_tag(rt_foo, 0, rt_foo.length())
  inspect(name_rt_foo, content="rt_foo")
  let real = "<rt>".to_array()
  let (name_rt, is_close, _) = classify_tag(real, 0, real.length())
  inspect(name_rt, content="rt")
  assert_false(is_close)
}

///|
/// A fake `<ruby-foo>` tag opens no real ruby, so the kanji it wraps gets no
/// coverage and flags `ruby.kanji_uncovered` — proof the boundary check keeps
/// look-alike tags from satisfying the furigana contract.
test "check_jpf_ruby treats a fake ruby tag as no ruby" {
  let r = Report::{ findings: [] }
  check_jpf_ruby("<ruby-foo>要</ruby-foo>", r)
  json_inspect(r.codes(), content=["ruby.kanji_uncovered"])
}

///|
/// A `<ruby>` whose `<rt>` never closes before `</ruby>` would leave the reading
/// unchecked, so it flags `ruby.rt_count` like the unclosed-`<ruby>` guard.
test "check_jpf_ruby flags an unclosed rt inside a closed ruby" {
  let r = Report::{ findings: [] }
  check_jpf_ruby("<ruby>要<rt>x</ruby>", r)
  json_inspect(r.codes(), content=["ruby.rt_count"])
}

///|
/// An `<rt>` outside any `<ruby>` is malformed and flags `ruby.rt_count`.
test "check_jpf_ruby flags a stray rt outside ruby" {
  let r = Report::{ findings: [] }
  check_jpf_ruby("<rt>よう</rt>", r)
  json_inspect(r.codes(), content=["ruby.rt_count"])
}

///|
/// A closing `</rt>` without a matching opener is malformed even when all text
/// before it happens to be kana; it cannot pass by borrowing that prefix as a
/// synthetic reading.
test "check_jpf_ruby flags a stray closing rt" {
  let r = Report::{ findings: [] }
  check_jpf_ruby("かな</rt>", r)
  json_inspect(r.codes(), content=["ruby.rt_count"])
}

///|
/// An empty `<rt>` supplies no reading, so it flags `ruby.rt_not_kana` rather
/// than passing on vacuous all-kana.
test "check_jpf_ruby flags an empty rt reading" {
  let r = Report::{ findings: [] }
  check_jpf_ruby("<ruby>要<rt></rt></ruby>", r)
  json_inspect(r.codes(), content=["ruby.rt_not_kana"])
}

///|
/// A `<ruby>` nested in another has no independent `<rt>`; nesting flags
/// `ruby.rt_count` rather than letting the inner rt stand in for the outer.
test "check_jpf_ruby rejects nested ruby" {
  let r = Report::{ findings: [] }
  check_jpf_ruby("<ruby><ruby>要<rt>よう</rt></ruby></ruby>", r)
  json_inspect(r.codes(), content=["ruby.rt_count"])
}

///|
/// An unclosed `<code>` grants no lasting coverage exemption: a kanji it swallows
/// flags `ruby.kanji_uncovered`, while an unclosed `<code>` holding no kanji stays
/// clean, so the guard fires on real omissions only.
test "check_jpf_ruby denies an unclosed code a coverage exemption" {
  let hid = Report::{ findings: [] }
  check_jpf_ruby("<code>図要", hid)
  json_inspect(hid.codes(), content=["ruby.kanji_uncovered"])
  let empty = Report::{ findings: [] }
  check_jpf_ruby("<code>abc", empty)
  json_inspect(empty.codes(), content=[])
}
