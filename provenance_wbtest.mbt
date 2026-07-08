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
