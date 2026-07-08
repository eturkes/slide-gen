// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// The outcome of schema-checking one `provenance.json` row: `Valid(row)`
/// carrying the captured `ProvRow` for the source and quote checks, or
/// `Invalid(reason)` carrying a human-readable reason. Schema-checking proves the
/// row's shape; `check_row` then proves its source reference and quote against
/// the cited file.
priv enum RowParse {
  Valid(ProvRow)
  Invalid(String)
}

///|
/// A schema-valid row's fields that the source and quote checks read: its `id`
/// (names the row in a finding), `status` (a `gap` row is skipped as
/// unverifiable), and the optional `src`/`quote` (a non-`gap` row carries both,
/// proven non-empty by `parse_row`; a `gap` row may omit them). `slide` and
/// `claim` are validated present by `parse_row` but unread afterward, so they are
/// not stored.
priv struct ProvRow {
  id : String
  status : String
  src : String?
  quote : String?
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
  guard m.get("id") is Some(Json::String(id)) else {
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
  let src = match m.get("src") {
    Some(Json::String(s)) => Some(s)
    _ => None
  }
  let quote = match m.get("quote") {
    Some(Json::String(q)) => Some(q)
    _ => None
  }
  if status != "gap" {
    guard src is Some(s) else {
      return Invalid("provenance row is missing a string src")
    }
    if s == "" {
      return Invalid("provenance row has an empty src")
    }
    guard quote is Some(q) else {
      return Invalid("provenance row is missing a string quote")
    }
    if q == "" {
      return Invalid("provenance row has an empty quote")
    }
  }
  Valid(ProvRow::{ id, status, src, quote })
}

///|
/// Parse a non-empty run of ASCII digits as a positive decimal, or `None` if it
/// is empty, holds a non-digit, or is long enough to overflow a 32-bit `Int` (a
/// line number never needs ten digits). Leading zeros are accepted.
fn parse_int(s : String) -> Int? {
  let cs = s.to_array()
  let n = cs.length()
  if n == 0 || n > 9 {
    return None
  }
  let mut v = 0
  for c in cs {
    if !is_ascii_digit(c) {
      return None
    }
    v = v * 10 + (c.to_int() - '0'.to_int())
  }
  Some(v)
}

///|
/// Split a `path:Lstart-Lend` source reference into its path and inclusive line
/// range. The path is split off at the LAST colon, so a path that itself holds a
/// colon (a URL scheme, a drive letter) survives; the range is split at its FIRST
/// dash into two decimals. Returns `None` unless both parse and form a forward
/// 1-based range (`start >= 1`, `end >= start`) — rejecting an empty path, a
/// missing colon or dash, a non-positive start, and a reversed range.
fn parse_src_ref(src : String) -> (String, Int, Int)? {
  let cs = src.to_array()
  let n = cs.length()
  let mut colon = -1
  for i in 0..<n {
    if cs[i] == ':' {
      colon = i
    }
  }
  if colon < 1 {
    return None
  }
  let mut dash = -1
  for i in (colon + 1)..<n {
    if cs[i] == '-' {
      dash = i
      break
    }
  }
  if dash < 0 {
    return None
  }
  let path = range_to_string(cs, 0, colon)
  let start = parse_int(range_to_string(cs, colon + 1, dash))
  let end = parse_int(range_to_string(cs, dash + 1, n))
  match (start, end) {
    (Some(s), Some(e)) =>
      if s >= 1 && e >= s {
        Some((path, s, e))
      } else {
        None
      }
    _ => None
  }
}

///|
/// Extract the inclusive 1-based line range `[start, end]` from `content` as a
/// newline-joined string, or `None` if the range falls outside the file. Lines
/// are the `\n`-split segments (a trailing newline yields a final empty segment,
/// counted in the length), so a citation past the last line is rejected rather
/// than silently clamped.
fn line_slice(content : String, start : Int, end : Int) -> String? {
  let lines = content.split("\n").to_array()
  let len = lines.length()
  if start < 1 || end < start || end > len {
    return None
  }
  let sb = StringBuilder::new()
  for i in (start - 1)..<end {
    if i > start - 1 {
      sb.write_char('\n')
    }
    sb.write_stringview(lines[i])
  }
  Some(sb.to_string())
}

///|
/// Whether `needle` occurs literally within `hay`, compared in codepoint space so
/// a multibyte Japanese quote matches at character boundaries. An empty needle
/// matches everywhere; a needle longer than the haystack cannot match.
fn contains_substring(hay : String, needle : String) -> Bool {
  let h = hay.to_array()
  let nd = needle.to_array()
  let hn = h.length()
  let nn = nd.length()
  if nn == 0 {
    return true
  }
  if nn > hn {
    return false
  }
  for i in 0..<(hn - nn + 1) {
    let mut ok = true
    for k in 0..<nn {
      if h[i + k] != nd[k] {
        ok = false
        break
      }
    }
    if ok {
      return true
    }
  }
  false
}

///|
/// Resolve a provenance source path against `base`: an absolute path (leading
/// `/`) stands alone; a relative path hangs off `base`, the root the deck's
/// sources are cited relative to.
fn resolve_src(path : String, base : String) -> String {
  if path.has_prefix("/") {
    path
  } else {
    "\{base}/\{path}"
  }
}

///|
/// Whether `path` lies at or under `dir`, matched at a segment boundary so a
/// sibling sharing a name prefix (`/b` vs `/bx`) is not counted inside. Trailing
/// slashes on `dir` are stripped first, so a caller that spells `bundle_dir` with
/// a trailing `/` still anchors the boundary — otherwise a plain self-citation
/// slips past the prefix test. Guards the self-citation check: a row must cite a
/// source OUTSIDE the generated bundle, never one of the bundle's own files.
fn is_inside(path : String, dir : String) -> Bool {
  let cs = dir.to_array()
  let mut n = cs.length()
  while n > 0 && cs[n - 1] == '/' {
    n = n - 1
  }
  let d = range_to_string(cs, 0, n)
  path == d || path.has_prefix("\{d}/")
}

///|
/// Verify one schema-valid row's source reference against the cited file, pushing
/// a `Must` finding (named by the row `id`) for each failure. A `gap` row is
/// unverifiable and skipped. Otherwise `src` must parse as `path:Lstart-Lend`
/// (`prov.src_range`), must resolve OUTSIDE the bundle (`prov.self_citation` — no
/// row may cite a generated bundle file), must name an existing regular file
/// (`prov.src_missing` — a missing path, or a directory or device that cannot be
/// quoted), must span an in-bounds line range (`prov.src_range`),
/// and that line slice must literally contain `quote` (`prov.quote`). This is an
/// existence check that kills invented quotes and fabricated citations, NOT a
/// truth check — misattribution and cherry-picking still pass to human review.
async fn check_row(
  r : ProvRow,
  bundle_dir : String,
  src_base : String,
  out : Report,
) -> Unit {
  guard r.status != "gap" else { return }
  guard r.src is Some(src) else { return }
  guard r.quote is Some(quote) else { return }
  match parse_src_ref(src) {
    None =>
      out.findings.push(
        must(
          "prov.src_range",
          "row \{r.id}: src is not a path:Lstart-Lend reference",
        ),
      )
    Some((path, start, end)) => {
      let resolved = resolve_src(path, src_base)
      if is_inside(resolved, bundle_dir) {
        out.findings.push(
          must(
            "prov.self_citation",
            "row \{r.id}: src cites a file inside the bundle",
          ),
        )
        return
      }
      if !@fs.exists(resolved) {
        out.findings.push(
          must(
            "prov.src_missing",
            "row \{r.id}: src file does not exist: \{path}",
          ),
        )
        return
      }
      // Read only a regular file. A directory, device, or FIFO cited as a source
      // would otherwise be handed to `read_file`: a character device or an empty
      // FIFO can block or exhaust memory before any finding is emitted, and a
      // directory's read error would masquerade as a quote miss. `@fs.kind`
      // follows symlinks (matching `read_file`); any stat error classifies the
      // path as non-regular.
      let is_regular = try @fs.kind(resolved) catch {
        _ => false
      } noraise {
        @fs.Regular => true
        _ => false
      }
      guard is_regular else {
        out.findings.push(
          must(
            "prov.src_missing",
            "row \{r.id}: src is not a regular file: \{path}",
          ),
        )
        return
      }
      let text = try @fs.read_file(resolved).text() catch {
        _ => ""
      } noraise {
        t => t
      }
      match line_slice(text, start, end) {
        None =>
          out.findings.push(
            must(
              "prov.src_range",
              "row \{r.id}: src line range is out of bounds",
            ),
          )
        Some(slice) =>
          if !contains_substring(slice, quote) {
            out.findings.push(
              must(
                "prov.quote",
                "row \{r.id}: quote does not occur in the cited line range",
              ),
            )
          }
      }
    }
  }
}

///|
/// Validate a bundle's `provenance.json` text, pushing a `Must` finding per
/// problem into `out`. The document must parse as a JSON array (`prov.parse`
/// otherwise, covering both a syntax error and a non-array top level); each row
/// is schema-checked via `parse_row` (a failing row pushes `prov.schema` with its
/// reason) and, when schema-valid, source-checked via `check_row` against files
/// under `src_base` (self-citations resolved relative to `bundle_dir`). This is
/// `async` because `check_row` reads the cited source files.
async fn check_provenance(
  prov_text : String,
  bundle_dir : String,
  src_base : String,
  out : Report,
) -> Unit {
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
      Valid(r) => check_row(r, bundle_dir, src_base, out)
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
/// provenance source paths resolve against; the per-row source and quote checks
/// read the cited files under it. Raises if `deck.html` is unreadable.
pub async fn validate_bundle_dir(
  bundle_dir : String,
  slug : String,
  src_base : String,
) -> Report {
  let html = @fs.read_file("\{bundle_dir}/deck.html").text()
  let assets = list_assets(bundle_dir)
  let out = validate_deck(html, slug, assets)
  let prov_path = "\{bundle_dir}/provenance.json"
  if @fs.exists(prov_path) {
    check_provenance(@fs.read_file(prov_path).text(), bundle_dir, src_base, out)
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
