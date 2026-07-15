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
  slide : Int
  status : String
  src : String?
  quote : String?
}

///|
/// Schema-valid provenance rows plus their unique ID set and whether any row is
/// an unresolved gap. The deck cross-reference consumes rows for reverse parity
/// and slide checks; gaps.md consumes `has_gap` to reject a contradictory
/// `no gaps` sentinel.
priv struct ProvIndex {
  rows : Array[ProvRow]
  ids : @set.Set[String]
  has_gap : Bool
}

///|
/// Filesystem-resolved source confinement result. `Allowed` carries the
/// canonical path that is subsequently lstat/read, avoiding a second traversal
/// through the authored symlink spelling.
priv enum SourceBoundary {
  Allowed(String)
  SelfCitation
  Outside
  Missing
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
  if trim_ws(id) == "" {
    return Invalid("provenance row has an empty id")
  }
  guard m.get("slide") is Some(Json::Number(slide_number, ..)) &&
    slide_number >= 1.0 &&
    slide_number <= 2147483647.0 &&
    slide_number.trunc() == slide_number else {
    return Invalid("provenance row slide is not a positive integer")
  }
  let slide = slide_number.to_int()
  guard m.get("claim") is Some(Json::String(claim)) else {
    return Invalid("provenance row is missing a string claim")
  }
  if trim_ws(claim) == "" {
    return Invalid("provenance row has an empty claim")
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
  if status == "gap" {
    if m.get("src") is Some(_) || m.get("quote") is Some(_) {
      return Invalid("gap provenance row must omit src and quote")
    }
  } else {
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
  Valid(ProvRow::{ id, slide, status, src, quote })
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
/// The direct child of normalized `base` containing normalized `path`, or
/// `None` when `path` is the base itself. The caller has already established the
/// lexical inside relation.
fn direct_child(path : String, base : String) -> String? {
  let b = normalize_path(base)
  let p = normalize_path(path)
  if p == b {
    return None
  }
  let base_parts = b
    .split("/")
    .filter(fn(part) { !part.is_empty() })
    .map(fn(part) { part.to_owned() })
    .to_array()
  let path_parts = p
    .split("/")
    .filter(fn(part) { !part.is_empty() })
    .map(fn(part) { part.to_owned() })
    .to_array()
  if path_parts.length() <= base_parts.length() {
    return None
  }
  let first = path_parts[base_parts.length()]
  if b == "/" {
    Some("/\{first}")
  } else {
    Some("\{b}/\{first}")
  }
}

///|
/// Resolve an existing lexical source path and enforce real filesystem
/// boundaries. Canonical targets under the canonical source base are allowed.
/// A target outside that base is allowed only when the path's DIRECT source-base
/// child is itself a symlink to a directory and the target remains inside that
/// canonical directory; this preserves M1's symlinked-sibling-project support
/// while rejecting nested symlink escapes. Canonical deck-home targets are
/// always self-citations, including via a symlink.
async fn resolve_source_boundary(
  resolved : String,
  src_base : String,
  deck_home : String,
) -> SourceBoundary {
  let real = try @fs.realpath(resolved) catch {
    _ => return Missing
  } noraise {
    path => normalize_path(path)
  }
  let real_deck = try @fs.realpath(deck_home) catch {
    _ => normalize_path(deck_home)
  } noraise {
    path => normalize_path(path)
  }
  if is_inside(real, real_deck) {
    return SelfCitation
  }
  let real_base = try @fs.realpath(src_base) catch {
    _ => return Outside
  } noraise {
    path => normalize_path(path)
  }
  if is_inside(real, real_base) {
    return Allowed(real)
  }
  guard direct_child(resolved, src_base) is Some(child) else { return Outside }
  let child_is_symlinked_dir = try
    @fs.kind(child, follow_symlink=false) == @fs.SymLink &&
    @fs.kind(child, follow_symlink=true) == @fs.Directory
  catch {
    _ => false
  } noraise {
    allowed => allowed
  }
  if !child_is_symlinked_dir {
    return Outside
  }
  let real_child = try @fs.realpath(child) catch {
    _ => return Outside
  } noraise {
    path => normalize_path(path)
  }
  if is_inside(real, real_child) {
    Allowed(real)
  } else {
    Outside
  }
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
      let real_source = match
        resolve_source_boundary(resolved, src_base, deck_home) {
        Allowed(real) => real
        SelfCitation => {
          out.findings.push(
            must(
              "prov.self_citation",
              "row \{r.id}: src resolves to a generated deck file",
            ),
          )
          return
        }
        Outside => {
          out.findings.push(
            must(
              "prov.src_outside",
              "row \{r.id}: src resolves outside the allowed source roots",
            ),
          )
          return
        }
        Missing => {
          out.findings.push(
            must(
              "prov.src_missing",
              "row \{r.id}: src file does not exist: \{path}",
            ),
          )
          return
        }
      }
      // Read only a regular file. A directory, device, or FIFO cited as a source
      // would otherwise be handed to `read_file`: a character device or an empty
      // FIFO can block or exhaust memory before any finding is emitted, and a
      // directory's read error would masquerade as a quote miss. The canonical
      // target is lstat'd without following its final component; any stat error
      // classifies the path as non-regular.
      let is_regular = try @fs.kind(real_source, follow_symlink=false) catch {
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
      guard read_regular_text(real_source) is Some(text) else {
        out.findings.push(
          must("prov.src_missing", "row \{r.id}: src is unreadable: \{path}"),
        )
        return
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
/// is `async` because `check_row` reads the cited source files. Returns the
/// unique schema-valid row index (empty on a parse failure) for exact deck
/// cross-reference and gaps consistency checks. Duplicate IDs are blocking and
/// only their first row enters the index, preventing follow-on ambiguity.
async fn check_provenance(
  prov_text : String,
  deck_home : String,
  src_base : String,
  out : Report,
) -> ProvIndex {
  let ids : @set.Set[String] = @set.Set([])
  let valid_rows : Array[ProvRow] = []
  let mut has_gap = false
  let j = try @json.parse(prov_text) catch {
    _ => {
      out.findings.push(must("prov.parse", "provenance.json is not valid JSON"))
      return ProvIndex::{ rows: valid_rows, ids, has_gap }
    }
  } noraise {
    j => j
  }
  guard j is Json::Array(rows) else {
    out.findings.push(must("prov.parse", "provenance.json is not a JSON array"))
    return ProvIndex::{ rows: valid_rows, ids, has_gap }
  }
  for row in rows {
    match parse_row(row) {
      Invalid(reason) => out.findings.push(must("prov.schema", reason))
      Valid(r) => {
        if ids.contains(r.id) {
          out.findings.push(
            must("prov.duplicate_id", "duplicate provenance row id: \{r.id}"),
          )
          continue
        }
        ids.add(r.id)
        valid_rows.push(r)
        if r.status == "gap" {
          has_gap = true
        }
        check_row(r, deck_home, src_base, out)
      }
    }
  }
  ProvIndex::{ rows: valid_rows, ids, has_gap }
}

///|
/// Validate a bundle's `gaps.md` and return whether it is the exact `no gaps`
/// sentinel. The file is either that one sentinel or a bullet-bearing gap list;
/// mixing the sentinel with other content is contradictory, and prose without a
/// bullet is not a machine-legible disclosure.
fn check_gaps(text : String, out : Report) -> Bool {
  let whole = trim_ws(text)
  if whole == "no gaps" {
    return true
  }
  let mut has_bullet = false
  let mut has_sentinel_line = false
  for line in text.split("\n") {
    let t = trim_ws(line.to_owned())
    if t == "no gaps" {
      has_sentinel_line = true
    }
    if t.has_prefix("- ") {
      has_bullet = true
    }
  }
  if has_sentinel_line {
    out.findings.push(
      must(
        "gaps.contradiction", "gaps.md mixes the no-gaps sentinel with other content",
      ),
    )
  } else if !has_bullet {
    out.findings.push(
      must(
        "gaps.empty", "gaps.md discloses neither a gap bullet nor the \"no gaps\" sentinel",
      ),
    )
  }
  false
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
    } else if is_markup_start(doc, i, end) {
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
/// Cross-reference the deck against the provenance rows — exact/unique claim-ID
/// parity and slide ownership are blocking, followed by two SHOULD coverage
/// warnings:
///
/// - `prov.dangling_claim` (MUST): every deck `data-claim` must name a
///   schema-valid provenance row `id`, else the deck cites evidence that does not
///   exist.
/// - `prov.unreferenced_row` (MUST): every schema-valid row ID must occur on a
///   deck element; together with the dangling check this enforces exact set
///   parity in both directions.
/// - `prov.slide_mismatch` (MUST): a row's positive integer `slide` must name a
///   slide carrying that row ID.
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
  provenance : ProvIndex,
  out : Report,
) -> Unit {
  let n = doc.length()
  let deck_ids : @set.Set[String] = @set.Set([])
  for id in find_data_claims(doc, 0, n) {
    if !deck_ids.contains(id) && !provenance.ids.contains(id) {
      out.findings.push(
        must(
          "prov.dangling_claim",
          "deck data-claim \{id} names no schema-valid provenance row",
        ),
      )
    }
    deck_ids.add(id)
  }
  let slides = find_by_class(doc, 0, n, ["slide"], want_tag="section")
  for row in provenance.rows {
    if !deck_ids.contains(row.id) {
      out.findings.push(
        must(
          "prov.unreferenced_row",
          "provenance row \{row.id} appears on no deck element",
        ),
      )
      continue
    }
    let mut on_declared_slide = false
    let mut on_other_slide = false
    for index, slide in slides {
      if find_data_claims(doc, slide.open_lt, slide.hi).any(fn(id) {
          id == row.id
        }) {
        if index + 1 == row.slide {
          on_declared_slide = true
        } else {
          on_other_slide = true
        }
      }
    }
    if !on_declared_slide || on_other_slide {
      out.findings.push(
        must(
          "prov.slide_mismatch",
          "provenance row \{row.id} must be claimed only on slide \{row.slide}",
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
      (Some(src), Some(id)) =>
        if provenance.ids.contains(id) {
          cited.push(src)
        }
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
/// The single blocking report for an unusable deck entry.
fn missing_deck_report() -> Report {
  Report::{
    findings: [
      must(
        "deck.missing", "deck.html missing, empty, non-regular, or a symlink",
      ),
    ],
  }
}

///|
/// Read one real regular file without following its final path component. A
/// missing, unreadable, non-regular, or symlink entry returns `None`.
async fn read_regular_text(path : String) -> String? {
  let regular = try @fs.kind(path, follow_symlink=false) catch {
    _ => false
  } noraise {
    @fs.Regular => true
    _ => false
  }
  if !regular {
    return None
  }
  try @fs.read_file(path).text() catch {
    _ => None
  } noraise {
    text => Some(text)
  }
}

///|
/// Validate the closed bundle layout around the already-collected safe asset
/// set. Only mandatory files plus conditional `figures.py`/`assets/` belong at
/// the root. Every assets entry is a direct real `.png`; any PNG set requires a
/// real SPDX-marked figure script, while a script without assets is incomplete.
async fn check_bundle_layout(
  bundle_dir : String,
  assets : @set.Set[String],
  out : Report,
) -> Unit {
  let root_entries = try @fs.readdir(bundle_dir) catch {
    _ => []
  } noraise {
    entries => entries
  }
  for name in root_entries {
    if name != "deck.html" &&
      name != "provenance.json" &&
      name != "gaps.md" &&
      name != "figures.py" &&
      name != "assets" {
      out.findings.push(
        must("bundle.unexpected", "unexpected bundle-root entry: \{name}"),
      )
    }
  }
  let assets_dir = "\{bundle_dir}/assets"
  let assets_kind = try @fs.kind(assets_dir, follow_symlink=false) catch {
    _ => None
  } noraise {
    kind => Some(kind)
  }
  match assets_kind {
    None => ()
    Some(@fs.Directory) => {
      let entries = try @fs.readdir(assets_dir) catch {
        _ => []
      } noraise {
        names => names
      }
      if entries.length() == 0 {
        out.findings.push(
          must(
            "asset.empty", "text-only bundles must omit the assets directory",
          ),
        )
      }
      for name in entries {
        let path = "\{assets_dir}/\{name}"
        let valid = name.has_suffix(".png") &&
          (try @fs.kind(path, follow_symlink=false) catch {
            _ => false
          } noraise {
            @fs.Regular => true
            _ => false
          })
        if !valid {
          out.findings.push(
            must(
              "asset.invalid",
              "asset must be a direct real assets/*.png file: \{name}",
            ),
          )
        }
      }
    }
    Some(_) =>
      out.findings.push(
        must("asset.invalid", "bundle assets entry is not a real directory"),
      )
  }
  let asset_count = assets.to_array().length()
  let figures_path = "\{bundle_dir}/figures.py"
  let figures_kind = try @fs.kind(figures_path, follow_symlink=false) catch {
    _ => None
  } noraise {
    kind => Some(kind)
  }
  match figures_kind {
    None =>
      if asset_count > 0 {
        out.findings.push(
          must("figures.missing", "bundle PNG assets require figures.py"),
        )
      }
    Some(@fs.Regular) =>
      match read_regular_text(figures_path) {
        None =>
          out.findings.push(must("figures.invalid", "figures.py is unreadable"))
        Some(text) => {
          if !text.has_prefix(
              "# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception\n",
            ) {
            out.findings.push(
              must("figures.spdx", "figures.py lacks the required SPDX header"),
            )
          }
          if asset_count == 0 {
            out.findings.push(
              must("figures.no_assets", "figures.py produced no bundled PNG"),
            )
          }
        }
      }
    Some(_) =>
      out.findings.push(
        must("figures.invalid", "figures.py is not a real regular file"),
      )
  }
}

///|
/// Validate a whole deck bundle rooted at `bundle_dir`, accumulating every
/// finding into one `Report`: the deck itself (envelope, slide-structure,
/// slide-text, entry/furigana, and image contract via `validate_deck`), its
/// `provenance.json` schema, its `gaps.md` disclosure, and the deck-to-provenance
/// exact deck/provenance ID parity, the closed no-follow file layout, and
/// conditional figure contract. Missing/non-regular/symlink mandatory files are
/// blocking. `src_base` is the lexical source root; realpath confinement permits
/// canonical paths under it plus directly symlinked sibling project roots, while
/// `deck_home` is rejected both lexically and canonically.
pub async fn validate_bundle_dir(
  bundle_dir : String,
  slug : String,
  src_base : String,
  deck_home : String,
) -> Report {
  let bundle_is_real_dir = try
    @fs.kind(bundle_dir, follow_symlink=false)
  catch {
    _ => false
  } noraise {
    @fs.Directory => true
    _ => false
  }
  guard bundle_is_real_dir else { return missing_deck_report() }
  let deck_path = "\{bundle_dir}/deck.html"
  guard read_regular_text(deck_path) is Some(html) else {
    return missing_deck_report()
  }
  guard html.length() > 0 else { return missing_deck_report() }
  let assets = list_assets(bundle_dir)
  let out = validate_deck(html, slug, assets)
  check_bundle_layout(bundle_dir, assets, out)
  let prov_path = "\{bundle_dir}/provenance.json"
  let provenance = match read_regular_text(prov_path) {
    Some(text) => check_provenance(text, deck_home, src_base, out)
    None => {
      out.findings.push(
        must(
          "prov.missing", "bundle provenance.json is missing, unreadable, non-regular, or a symlink",
        ),
      )
      ProvIndex::{ rows: [], ids: @set.Set([]), has_gap: false }
    }
  }
  let gaps_path = "\{bundle_dir}/gaps.md"
  let mut says_no_gaps = false
  match read_regular_text(gaps_path) {
    Some(text) => says_no_gaps = check_gaps(text, out)
    None =>
      out.findings.push(
        must(
          "gaps.missing", "bundle gaps.md is missing, unreadable, non-regular, or a symlink",
        ),
      )
  }
  if provenance.has_gap && says_no_gaps {
    out.findings.push(
      must(
        "gaps.contradiction", "gaps.md says no gaps but provenance contains a gap row",
      ),
    )
  }
  let doc = clean_doc(html.to_array())
  check_deck_crossref(doc, assets, provenance, out)
  out
}
