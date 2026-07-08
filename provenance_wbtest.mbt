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
    Valid => "ok"
    Invalid(reason) => reason
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
