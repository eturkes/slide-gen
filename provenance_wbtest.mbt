// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Parse a JSON string into a `Json` value for the row tests, collapsing a parse
/// error to null (every case below passes well-formed JSON).
fn pj(s : String) -> Json {
  try @json.parse(s) catch {
    _ => Json::null()
  } noraise {
    j => j
  }
}

///|
/// Collapse a `parse_row` outcome to a string: `ok` for `Valid`, else the reason.
fn row_result(row : Json) -> String {
  match parse_row(row) {
    Valid(_) => "ok"
    Invalid(reason) => reason
  }
}

///|
/// Collapse a `parse_src_ref` outcome to `path|start|end`, or `none`.
fn ref_str(s : String) -> String {
  match parse_src_ref(s) {
    Some((p, a, b)) => "\{p}|\{a}|\{b}"
    None => "none"
  }
}

///|
/// Collapse a `line_slice` outcome to its text with newlines shown as `/`, or
/// `none` — keeping multi-line goldens on one source line.
fn slice_str(content : String, a : Int, b : Int) -> String {
  match line_slice(content, a, b) {
    Some(s) => {
      let sb = StringBuilder::new()
      for c in s.to_array() {
        if c == '\n' {
          sb.write_char('/')
        } else {
          sb.write_char(c)
        }
      }
      sb.to_string()
    }
    None => "none"
  }
}

///|
/// Run `check_gaps` over `text` and return the resulting codes.
fn gaps_codes(text : String) -> Array[String] {
  let out = Report::{ findings: [] }
  check_gaps(text, out)
  out.codes()
}

///|
/// `parse_row` accepts a fully-specified verified row and a gap row that omits
/// its evidence, and rejects — each with a specific reason — a verified row
/// missing its quote, a non-object row, an unknown status, and a row with no id.
test "parse_row schema outcomes" {
  inspect(
    row_result(
      pj(
        "{\"id\":\"c1\",\"slide\":1,\"claim\":\"x\",\"status\":\"verified\",\"src\":\"a.md:1-1\",\"quote\":\"q\"}",
      ),
    ),
    content="ok",
  )
  inspect(
    row_result(
      pj("{\"id\":\"c1\",\"slide\":1,\"claim\":\"x\",\"status\":\"gap\"}"),
    ),
    content="ok",
  )
  inspect(
    row_result(
      pj(
        "{\"id\":\"c1\",\"slide\":1,\"claim\":\"x\",\"status\":\"verified\",\"src\":\"a.md:1-1\"}",
      ),
    ),
    content="provenance row is missing a string quote",
  )
  inspect(
    row_result(pj("[1,2]")),
    content="provenance row is not a JSON object",
  )
  inspect(
    row_result(
      pj("{\"id\":\"c1\",\"slide\":1,\"claim\":\"x\",\"status\":\"maybe\"}"),
    ),
    content="provenance row has an unknown status: maybe",
  )
  inspect(
    row_result(pj("{\"slide\":1,\"claim\":\"x\",\"status\":\"gap\"}")),
    content="provenance row is missing a string id",
  )
}

///|
/// `check_gaps` treats the `no gaps` sentinel (case-insensitively) or any bullet
/// line as disclosure, and flags prose that discloses neither.
test "check_gaps disclosure" {
  json_inspect(gaps_codes("no gaps\n"), content=[])
  json_inspect(gaps_codes("Open gaps:\n- \u{7528}\u{8a9e}: reason\n"), content=[])
  json_inspect(gaps_codes("No Gaps\n"), content=[])
  json_inspect(gaps_codes("This deck is complete.\n"), content=["gaps.empty"])
}

///|
/// `parse_src_ref` splits the path at the LAST colon (so a colon-bearing path
/// survives) and the range at its FIRST dash, and rejects an empty path, a
/// reversed range, a non-positive start, and a missing dash or colon.
test "parse_src_ref splits path and range" {
  inspect(ref_str("a.md:2-5"), content="a.md|2|5")
  inspect(ref_str("a:b.md:1-2"), content="a:b.md|1|2")
  inspect(ref_str("x:5-2"), content="none")
  inspect(ref_str("x:0-1"), content="none")
  inspect(ref_str("x:5"), content="none")
  inspect(ref_str("x"), content="none")
  inspect(ref_str(":1-1"), content="none")
}

///|
/// `line_slice` returns an inclusive 1-based line range, joins multiple lines,
/// counts the trailing-newline empty segment, and rejects an out-of-range end.
test "line_slice extracts inclusive line ranges" {
  let content = "l1\nl2\nl3\nl4\n"
  inspect(slice_str(content, 2, 3), content="l2/l3")
  inspect(slice_str(content, 1, 1), content="l1")
  inspect(slice_str(content, 3, 9), content="none")
  inspect(slice_str("a\nb\n", 2, 2), content="b")
}

///|
/// `contains_substring` finds literal substrings in codepoint space (so a
/// Japanese needle matches at character boundaries), treats an empty needle as
/// present, and reports a longer-than-haystack needle as absent.
test "contains_substring literal search" {
  assert_true(contains_substring("beta gamma", "beta"))
  assert_false(contains_substring("beta gamma", "zzz"))
  assert_true(contains_substring("anything", ""))
  assert_true(
    contains_substring(
      "\u{5b66}\u{7fd2}\u{3068}\u{8a18}\u{61b6}", "\u{8a18}\u{61b6}",
    ),
  )
  assert_false(contains_substring("\u{5b66}\u{7fd2}", "\u{8a18}\u{61b6}"))
}

///|
/// `resolve_src` hangs a relative path off the base and leaves an absolute path
/// alone; `is_inside` matches at a segment boundary, so `/bx` is not inside `/b`,
/// and it strips trailing slashes on `dir` so `/b/` anchors the same as `/b`.
test "resolve_src and is_inside anchor paths" {
  inspect(resolve_src("a.md", "/base"), content="/base/a.md")
  inspect(resolve_src("/abs/a.md", "/base"), content="/abs/a.md")
  assert_true(is_inside("/b/x", "/b"))
  assert_true(is_inside("/b", "/b"))
  assert_false(is_inside("/bx", "/b"))
  assert_false(is_inside("/other/x", "/b"))
  assert_true(is_inside("/b/x", "/b/"))
  assert_true(is_inside("/b", "/b/"))
  assert_false(is_inside("/bx", "/b/"))
}

///|
/// `find_data_claims` collects `data-claim` values at every nesting depth in
/// document order — an outer element, a nested child, and a void `<img>` — and
/// walks tag by tag so close tags are skipped.
test "find_data_claims collects at every depth" {
  let doc = "<div data-claim=\"a\"><span data-claim=\"b\">1</span></div><img data-claim=\"c\">".to_array()
  json_inspect(find_data_claims(doc, 0, doc.length()), content=["a", "b", "c"])
}

///|
/// `find_data_claims` rejects three decoys: a `data-claim`-shaped run inside
/// another attribute's quoted value is not an attribute (so `decoy` is skipped);
/// a literal `<` in text does not open a tag, so the real tagged claim following
/// it is still collected rather than swallowed to the next `>`; and a close tag
/// carries nothing. Only the two genuine open-tag attributes come back.
test "find_data_claims skips decoys and treats a text `<` as text" {
  let doc = "<div title=\"data-claim=decoy\">5 < 6 <span data-claim=\"real\">x</span></div><img data-claim=\"v\">".to_array()
  json_inspect(find_data_claims(doc, 0, doc.length()), content=["real", "v"])
}

///|
/// `find_data_claims` honors its half-open `end`: an open tag whose `>` runs
/// past `end` contributes no claim, so an element-scoped scan cannot reach a
/// claim from beyond its own span (a malformed unclosed descendant). The same
/// tag under the whole-doc range is still collected.
test "find_data_claims honors the end bound" {
  let doc = "<a data-claim=\"c1\">".to_array()
  json_inspect(find_data_claims(doc, 0, 2), content=[])
  json_inspect(find_data_claims(doc, 0, doc.length()), content=["c1"])
}

///|
/// Run `check_deck_crossref` over a fragment's cleaned HTML and return the codes,
/// so the cross-reference checks can be exercised without a bundle on disk.
fn crossref_codes(
  html : String,
  assets : Array[String],
  row_ids : Array[String],
) -> Array[String] {
  let doc = strip_raw_text(strip_comments(html.to_array()))
  let out = Report::{ findings: [] }
  check_deck_crossref(doc, @set.Set(assets[:]), @set.Set(row_ids[:]), out)
  out.codes()
}

///|
/// The cross-reference's claim linkage and untagged-number warning: a
/// `data-claim` on the element itself exempts a numbered `.entry` (proving the
/// scan covers the element's own tag via `open_lt`, not just its descendants); a
/// `data-claim` naming no row still dangles even when tagged; and a bare numbered
/// `.entry` warns `prov.untagged_number`.
test "check_deck_crossref claim linkage and untagged numbers" {
  // A data-claim on the .entry itself exempts its number.
  json_inspect(
    crossref_codes("<div class=\"entry\" data-claim=\"c1\">25</div>", [], ["c1"]),
    content=[],
  )
  // A data-claim naming no row dangles (and, being tagged, is not untagged).
  json_inspect(
    crossref_codes("<div class=\"entry\" data-claim=\"ghost\">25</div>", [], [
      "c1",
    ]),
    content=["prov.dangling_claim"],
  )
  // A numbered .entry with no data-claim warns.
  json_inspect(crossref_codes("<div class=\"entry\">25</div>", [], []), content=[
    "prov.untagged_number",
  ])
}

///|
/// The asset-citation warning: an `<img>` whose `data-claim` names a schema-valid
/// row cites its PNG; the same `<img>` without a `data-claim` leaves the PNG
/// uncited; and a non-PNG asset is never flagged (the `.png` filter).
test "check_deck_crossref asset citation" {
  // A data-claim <img> naming a row cites its asset.
  json_inspect(
    crossref_codes(
      "<img src=\"assets/z.png\" data-claim=\"c1\">",
      ["assets/z.png"],
      ["c1"],
    ),
    content=[],
  )
  // The same <img> without a data-claim leaves the asset uncited.
  json_inspect(
    crossref_codes("<img src=\"assets/z.png\">", ["assets/z.png"], []),
    content=["prov.asset_uncited"],
  )
  // A non-PNG asset is never flagged.
  json_inspect(crossref_codes("<div></div>", ["assets/data.csv"], []), content=[])
}

///|
/// `has_number` detects a decimal digit, ASCII or fullwidth (U+FF10-FF19), and
/// nothing else.
test "has_number detects ASCII and fullwidth digits" {
  assert_true(has_number("2024"))
  assert_true(has_number("about 5"))
  assert_true(has_number("\u{FF11}")) // fullwidth 1
  assert_false(has_number("no digits"))
  assert_false(has_number(""))
}
