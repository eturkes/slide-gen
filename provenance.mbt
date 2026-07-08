// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// The outcome of schema-checking one `provenance.json` row: `Valid` if the row
/// satisfies the shape contract, or `Invalid(reason)` carrying a human-readable
/// reason. M2.2a-i checks shape only; the source-reference and quote-grep checks
/// that carry the row payload arrive in M2.2a-ii, which grows `Valid` a payload.
priv enum RowParse {
  Valid
  Invalid(String)
}

///|
/// Schema-check one provenance row (a decoded `Json` value). A row must be a JSON
/// object carrying a string `id`, a present non-null `slide`, a string `claim`,
/// and a `status` of `verified`, `inferred`, or `gap`. Every non-`gap` row must
/// additionally carry a non-empty string `src` and `quote` — folding "no verified
/// or inferred claim may omit its evidence" into the schema; a `gap` row may omit
/// both. The `Json` enum is hand-walked (its accessors are deprecated) so each
/// field yields a specific reason rather than one opaque decode failure.
fn parse_row(row : Json) -> RowParse {
  guard row is Json::Object(m) else {
    return Invalid("provenance row is not a JSON object")
  }
  guard m.get("id") is Some(Json::String(_)) else {
    return Invalid("provenance row is missing a string id")
  }
  match m.get("slide") {
    None | Some(Json::Null) => return Invalid("provenance row has no slide")
    _ => ()
  }
  guard m.get("claim") is Some(Json::String(_)) else {
    return Invalid("provenance row is missing a string claim")
  }
  guard m.get("status") is Some(Json::String(status)) else {
    return Invalid("provenance row is missing a string status")
  }
  if status != "verified" && status != "inferred" && status != "gap" {
    return Invalid("provenance row has an unknown status: \{status}")
  }
  if status != "gap" {
    guard m.get("src") is Some(Json::String(src)) else {
      return Invalid("provenance row is missing a string src")
    }
    if src == "" {
      return Invalid("provenance row has an empty src")
    }
    guard m.get("quote") is Some(Json::String(quote)) else {
      return Invalid("provenance row is missing a string quote")
    }
    if quote == "" {
      return Invalid("provenance row has an empty quote")
    }
  }
  Valid
}

///|
/// Validate a bundle's `provenance.json` text, pushing a `Must` finding per
/// problem into `out`. The document must parse as a JSON array (`prov.parse`
/// otherwise, covering both a syntax error and a non-array top level); each row
/// is schema-checked via `parse_row`, and a failing row pushes `prov.schema`
/// with its reason. This stays a plain (non-`async`) fn — it only parses and
/// walks JSON; M2.2a-ii promotes it to `async` once it adds the per-row source
/// check that reads files.
fn check_provenance(prov_text : String, out : Report) -> Unit {
  let j = try @json.parse(prov_text) catch {
    _ => {
      out.findings.push(must("prov.parse", "provenance.json is not valid JSON"))
      return
    }
  } noraise {
    j => j
  }
  guard j is Json::Array(rows) else {
    out.findings.push(must("prov.parse", "provenance.json is not a JSON array"))
    return
  }
  for row in rows {
    match parse_row(row) {
      Invalid(reason) => out.findings.push(must("prov.schema", reason))
      Valid => ()
    }
  }
}

///|
/// Validate a bundle's `gaps.md`, pushing `gaps.empty` when it discloses nothing.
/// Disclosure means at least one line is either the `no gaps` sentinel (matched
/// case-insensitively) or a Markdown bullet (`- ` after trimming). A gaps file of
/// only prose has failed to make an honest, machine-legible gap statement.
fn check_gaps(text : String, out : Report) -> Unit {
  let mut disclosed = false
  for line in text.split("\n") {
    let t = trim_ws(line.to_owned())
    if ci_eq(t, "no gaps") || t.has_prefix("- ") {
      disclosed = true
    }
  }
  if !disclosed {
    out.findings.push(
      must(
        "gaps.empty", "gaps.md discloses neither a gap bullet nor the \"no gaps\" sentinel",
      ),
    )
  }
}

///|
/// Validate a whole deck bundle rooted at `bundle_dir`, accumulating every
/// finding into one `Report`: the deck itself (envelope, slide-structure,
/// slide-text, entry/furigana, and image contract via `validate_deck`), its
/// `provenance.json` schema, and its `gaps.md` disclosure. A missing
/// `provenance.json` or `gaps.md` is itself a `Must` finding (`prov.missing` /
/// `gaps.missing`) — a bundle must ship both. `src_base` is the root the
/// provenance source paths resolve against; M2.2a-ii wires the per-row source
/// checks that consume it. Raises if `deck.html` is unreadable.
pub async fn validate_bundle_dir(
  bundle_dir : String,
  slug : String,
  src_base : String,
) -> Report {
  let _ = src_base
  let html = @fs.read_file("\{bundle_dir}/deck.html").text()
  let assets = list_assets(bundle_dir)
  let out = validate_deck(html, slug, assets)
  let prov_path = "\{bundle_dir}/provenance.json"
  if @fs.exists(prov_path) {
    check_provenance(@fs.read_file(prov_path).text(), out)
  } else {
    out.findings.push(must("prov.missing", "bundle has no provenance.json"))
  }
  let gaps_path = "\{bundle_dir}/gaps.md"
  if @fs.exists(gaps_path) {
    check_gaps(@fs.read_file(gaps_path).text(), out)
  } else {
    out.findings.push(must("gaps.missing", "bundle has no gaps.md"))
  }
  out
}
