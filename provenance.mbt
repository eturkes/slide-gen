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
/// Lexically clean a slash-delimited path with Go `path.Clean` semantics.
/// Empty and `.` segments disappear; `..` pops a preceding ordinary segment,
/// remains visible when it would escape a relative path, and stops at an
/// absolute root. Repeated and trailing slashes collapse, absoluteness is
/// preserved, and an empty relative result becomes `.`. The operation is pure
/// and idempotent; it deliberately does not resolve symlinks.
fn normalize_path(path : String) -> String {
  let absolute = path.has_prefix("/")
  let segments : Array[String] = []
  for view in path.split("/") {
    let segment = view.to_owned()
    if segment == "" || segment == "." {
      continue
    }
    if segment == ".." {
      if segments.length() > 0 && segments[segments.length() - 1] != ".." {
        ignore(segments.pop())
      } else if !absolute {
        segments.push(segment)
      }
    } else {
      segments.push(segment)
    }
  }
  if segments.length() == 0 {
    return if absolute { "/" } else { "." }
  }
  let out = StringBuilder::new()
  if absolute {
    out.write_char('/')
  }
  for i, segment in segments {
    if i > 0 {
      out.write_char('/')
    }
    out.write_string(segment)
  }
  out.to_string()
}

///|
/// Whether `path` lies at or under `dir`, matched at a segment boundary so a
/// sibling sharing a name prefix (`/b` vs `/bx`) is not counted inside. Trailing
/// slashes on `dir` are stripped first, so a caller spelling a boundary with a
/// trailing `/` still anchors it. Guards both normalized boundaries: a source
/// must stay outside the generated deck home and inside the source base.
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
/// (`prov.src_range`), normalize inside `src_base` (`prov.src_outside`), stay
/// outside the whole generated `deck_home` (`prov.self_citation`), name an
/// existing regular file (`prov.src_missing` — a missing path, directory, or
/// device cannot be quoted), span an in-bounds line range (`prov.src_range`), and
/// literally contain `quote` in that slice (`prov.quote`). This existence check
/// kills invented quotes and fabricated citations, NOT misattribution or
/// cherry-picking; those still pass to human review.
async fn check_row(
  r : ProvRow,
  deck_home : String,
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
      let resolved = normalize_path(resolve_src(path, src_base))
      if is_inside(resolved, normalize_path(deck_home)) {
        out.findings.push(
          must(
            "prov.self_citation",
            "row \{r.id}: src cites a generated deck file",
          ),
        )
        return
      }
      if !is_inside(resolved, normalize_path(src_base)) {
        out.findings.push(
          must("prov.src_outside", "row \{r.id}: src escapes the source base"),
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
/// under `src_base` (self-citations rejected across the whole `deck_home`). This
/// is `async` because `check_row` reads the cited source files. Returns the set
/// of schema-valid row ids (empty on a parse failure) for the deck cross-reference
/// to match `data-claim` attributes against.
async fn check_provenance(
  prov_text : String,
  deck_home : String,
  src_base : String,
  out : Report,
) -> @set.Set[String] {
  let ids : @set.Set[String] = @set.Set([])
  let j = try @json.parse(prov_text) catch {
    _ => {
      out.findings.push(must("prov.parse", "provenance.json is not valid JSON"))
      return ids
    }
  } noraise {
    j => j
  }
  guard j is Json::Array(rows) else {
    out.findings.push(must("prov.parse", "provenance.json is not a JSON array"))
    return ids
  }
  for row in rows {
    match parse_row(row) {
      Invalid(reason) => out.findings.push(must("prov.schema", reason))
      Valid(r) => {
        ids.add(r.id)
        check_row(r, deck_home, src_base, out)
      }
    }
  }
  ids
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
/// Collect every `data-claim` attribute value carried by an open tag that lies
/// wholly within the half-open range `doc[start:end]`, in document order and at
/// any depth. The dangling-claim scan passes the whole cleaned deck
/// (`0, doc.length()`); the coverage check passes one element's own span
/// (`el.open_lt, el.hi`) to ask whether that element or a descendant carries a
/// claim. The bound is enforced, not assumed: an open tag whose `>` runs past
/// `end` is dropped, so a malformed unclosed descendant cannot pull a claim in
/// from beyond the range. An open tag is recognized only when a letter follows
/// `<` (mirroring `find_all_open_tags`), so a literal `<` in text
/// (`5 < 6`) is not read as a tag and a `data-claim`-shaped run in prose after it
/// is not collected; `get_attr` skips a `data-claim`-shaped run inside another
/// attribute's quoted value. Close tags and `<!...>` are stepped over via
/// `skip_tag`. Runs on the cleaned deck (comments and raw-text content blanked
/// upstream), so no `<` inside CSS/JS reaches this scan.
fn find_data_claims(doc : Array[Char], start : Int, end : Int) -> Array[String] {
  let out : Array[String] = []
  let mut i = start
  while i < end {
    if doc[i] == '<' && i + 1 < end && is_ascii_letter(doc[i + 1]) {
      let (_, lo, hi, past_gt) = scan_open_tag(doc, i)
      // Honor the half-open bound: collect only a tag whose `>` lands at or
      // before `end`. A tag running past `end` (a malformed unclosed descendant)
      // belongs beyond the range, so drop its claim rather than reach for it.
      if past_gt <= end {
        match get_attr(doc, lo, hi, "data-claim") {
          Some(id) => out.push(id)
          None => ()
        }
      }
      i = past_gt
    } else if doc[i] == '<' &&
      i + 1 < end &&
      (doc[i + 1] == '/' || doc[i + 1] == '!') {
      i = skip_tag(doc, i, end)
    } else {
      i = i + 1
    }
  }
  out
}

///|
/// Whether `s` contains a decimal digit, ASCII (`0`-`9`) or fullwidth
/// (U+FF10-FF19, common in Japanese text). Used to decide whether a text element
/// carries a number that ought to be sourced by a `data-claim`.
fn has_number(s : String) -> Bool {
  for c in s.to_array() {
    let o = c.to_int()
    if is_ascii_digit(c) || (o >= 0xFF10 && o <= 0xFF19) {
      return true
    }
  }
  false
}

///|
/// Cross-reference the deck against the provenance rows — one MUST check plus two
/// SHOULD coverage warnings:
///
/// - `prov.dangling_claim` (MUST): every deck `data-claim` must name a
///   schema-valid provenance row `id`, else the deck cites evidence that does not
///   exist.
/// - `prov.untagged_number` (SHOULD): a `.entry` or `.cap` whose text carries a
///   number should carry a `data-claim` — on itself or a descendant — so the
///   figure traces to a source. The scan spans the element's own tag
///   (`el.open_lt`), so a claim on the element itself counts.
/// - `prov.asset_uncited` (SHOULD): every committed `assets/*.png` should be
///   referenced by an `<img>` whose `data-claim` names a schema-valid row.
///   Iterating the `assets` set also flags an orphan PNG referenced by no
///   `<img>`. Extension match is case-sensitive, mirroring the exact-match asset
///   pipeline (`list_assets`/`check_imgs`); generated bundles emit `.png`.
fn check_deck_crossref(
  doc : Array[Char],
  assets : @set.Set[String],
  row_ids : @set.Set[String],
  out : Report,
) -> Unit {
  let n = doc.length()
  for id in find_data_claims(doc, 0, n) {
    if !row_ids.contains(id) {
      out.findings.push(
        must(
          "prov.dangling_claim",
          "deck data-claim \{id} names no schema-valid provenance row",
        ),
      )
    }
  }
  // SHOULD: a numbered .entry/.cap with no data-claim on itself or a descendant.
  for el in find_by_class(doc, 0, n, ["entry", "cap"]) {
    if has_number(inner_text(doc, el.lo, el.hi)) &&
      find_data_claims(doc, el.open_lt, el.hi).length() == 0 {
      out.findings.push(
        should(
          "prov.untagged_number",
          "a .\{el.token} carries a number with no data-claim",
        ),
      )
    }
  }
  // SHOULD: every committed PNG should be shown by a data-claim <img> whose claim
  // names a schema-valid row.
  let cited : Array[String] = []
  for lt in find_all_open_tags(doc, "img") {
    let (_, lo, hi, _) = scan_open_tag(doc, lt)
    match (get_attr(doc, lo, hi, "src"), get_attr(doc, lo, hi, "data-claim")) {
      (Some(src), Some(id)) => if row_ids.contains(id) { cited.push(src) }
      _ => ()
    }
  }
  let cited_set = @set.Set(cited[:])
  for asset in assets.iter() {
    if asset.has_suffix(".png") && !cited_set.contains(asset) {
      out.findings.push(
        should(
          "prov.asset_uncited",
          "asset \{asset} is referenced by no data-claim <img>",
        ),
      )
    }
  }
}

///|
/// Validate a whole deck bundle rooted at `bundle_dir`, accumulating every
/// finding into one `Report`: the deck itself (envelope, slide-structure,
/// slide-text, entry/furigana, and image contract via `validate_deck`), its
/// `provenance.json` schema, its `gaps.md` disclosure, and the deck-to-provenance
/// cross-reference (every deck `data-claim` names a schema-valid row). A missing
/// `provenance.json` or `gaps.md` is itself a `Must` finding (`prov.missing` /
/// `gaps.missing`) — a bundle must ship both. `src_base` is the root the
/// provenance source paths resolve against; `deck_home` is the whole generated
/// decks tree, which no row may cite. The per-row source and quote checks read
/// only lexically confined files under `src_base`. Raises if `deck.html` is
/// unreadable.
pub async fn validate_bundle_dir(
  bundle_dir : String,
  slug : String,
  src_base : String,
  deck_home : String,
) -> Report {
  let html = @fs.read_file("\{bundle_dir}/deck.html").text()
  let assets = list_assets(bundle_dir)
  let out = validate_deck(html, slug, assets)
  let prov_path = "\{bundle_dir}/provenance.json"
  let row_ids : @set.Set[String] = if @fs.exists(prov_path) {
    check_provenance(@fs.read_file(prov_path).text(), deck_home, src_base, out)
  } else {
    out.findings.push(must("prov.missing", "bundle has no provenance.json"))
    @set.Set([])
  }
  let gaps_path = "\{bundle_dir}/gaps.md"
  if @fs.exists(gaps_path) {
    check_gaps(@fs.read_file(gaps_path).text(), out)
  } else {
    out.findings.push(must("gaps.missing", "bundle has no gaps.md"))
  }
  let doc = strip_raw_text(strip_comments(html.to_array()))
  check_deck_crossref(doc, assets, row_ids, out)
  out
}
