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
/// `strip_comments` drops a well-formed comment; an unterminated comment swallows
/// the rest of the document.
test "strip_comments removes comments and swallows unterminated" {
  let a = strip_comments("a<!--b-->c".to_array())
  inspect(range_to_string(a, 0, a.length()), content="ac")
  let b = strip_comments("keep<!--x".to_array())
  inspect(range_to_string(b, 0, b.length()), content="keep")
  let c = strip_comments("<!--only-->".to_array())
  inspect(range_to_string(c, 0, c.length()), content="")
}

///|
/// `strip_raw_text` blanks `<style>`/`<script>` content but keeps their tags; a
/// close tag matches only at a name boundary (`</stylex>` does not close); and an
/// unterminated raw-text element is blanked to end of document.
test "strip_raw_text blanks raw-text content" {
  let a = strip_raw_text("<style><img src=x></style>keep".to_array())
  inspect(range_to_string(a, 0, a.length()), content="<style></style>keep")
  let b = strip_raw_text("x<script>a<b</script>y".to_array())
  inspect(range_to_string(b, 0, b.length()), content="x<script></script>y")
  // </stylex> is not a name-boundary close, so blanking continues to the real one.
  let d = strip_raw_text("<style>x</stylex>y</style>z".to_array())
  inspect(range_to_string(d, 0, d.length()), content="<style></style>z")
  // Unterminated raw-text runs to end of document, so its remainder is blanked.
  let c = strip_raw_text("<style>body{}".to_array())
  inspect(range_to_string(c, 0, c.length()), content="<style>")
}

///|
/// `index_ci` finds a needle case-insensitively and returns `-1` when absent.
test "index_ci case-insensitive and absent" {
  assert_eq(index_ci("Hello".to_array(), "ell".to_array()), 1)
  assert_eq(index_ci("HELLO".to_array(), "ell".to_array()), 1)
  assert_eq(index_ci("abc".to_array(), "xyz".to_array()), -1)
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
