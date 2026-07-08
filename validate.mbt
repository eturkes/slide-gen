// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Severity of a validator `Finding`: `Must` blocks a bundle, `Should` warns.
/// M2.1's checks are all `Must`; the `Should` variant is reserved for the
/// provenance warnings introduced in M2.2, so it is defined but not yet
/// constructed.
pub(all) enum Severity {
  Must
  Should
} derive(Eq)

///|
/// A single validation result: a machine-readable `code` (e.g. `frame.doctype`)
/// plus a human-readable `detail`, at a given `severity`.
pub(all) struct Finding {
  severity : Severity
  code : String
  detail : String
}

///|
/// The outcome of validating a deck: the accumulated findings in check order.
/// An empty `findings` array means the deck passed every check.
pub(all) struct Report {
  findings : Array[Finding]
}

///|
/// Construct a blocking (`Must`) finding.
fn must(code : String, detail : String) -> Finding {
  Finding::{ severity: Must, code, detail }
}

///|
/// Whether the report is free of any blocking (`Must`) finding — a `Should`-only
/// report still passes. `Must`-free is the promote gate the generate harness
/// (M2.3) checks before publishing a bundle.
pub fn Report::ok(self : Report) -> Bool {
  for f in self.findings {
    if f.severity == Must {
      return false
    }
  }
  true
}

///|
/// The codes of every finding, in check order — the stable surface the tests
/// assert against.
pub fn Report::codes(self : Report) -> Array[String] {
  self.findings.map(fn(f) { f.code })
}

///|
/// Render the report for humans: one severity-labeled line per finding
/// (`[MUST] code: detail` / `[SHOULD] code: detail`), or `ok` when empty.
pub fn Report::render(self : Report) -> String {
  if self.findings.length() == 0 {
    return "ok"
  }
  let sb = StringBuilder::new()
  for i, f in self.findings {
    if i > 0 {
      sb.write_string("\n")
    }
    let label = match f.severity {
      Must => "[MUST]"
      Should => "[SHOULD]"
    }
    sb.write_string("\{label} \{f.code}: \{f.detail}")
  }
  sb.to_string()
}

// -- Light scan primitives (codepoint space) --------------------------------
//
// No stdlib HTML parser: the deck is scanned as an `Array[Char]` with targeted,
// quote- and comment-aware string matching. ASCII case-folding covers HTML's
// case-insensitive tag/attribute names without lowering whole strings; text
// content (JA) is never case-folded.

///|
/// ASCII lowercase a single char (`A`-`Z` -> `a`-`z`); every other codepoint,
/// including all of the JA range, passes through unchanged.
fn lower_ascii(c : Char) -> Char {
  if c >= 'A' && c <= 'Z' {
    match (c.to_int() + 0x20).to_char() {
      Some(l) => l
      None => c
    }
  } else {
    c
  }
}

///|
/// Whether `c` is an ASCII letter.
fn is_ascii_letter(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

///|
/// Whether `c` is an ASCII digit.
fn is_ascii_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// Whether `c` may appear in an HTML attribute name (letters, digits, and the
/// `- _ : .` punctuation that covers `charset`, `lang`, `class`, `src`, and
/// data attributes).
fn is_attr_name_char(c : Char) -> Bool {
  is_ascii_letter(c) ||
  is_ascii_digit(c) ||
  c == '-' ||
  c == '_' ||
  c == ':' ||
  c == '.'
}

///|
/// Whether `c` is ASCII/HTML whitespace (space, tab, LF, FF, CR) — the set that
/// separates tags, attributes, and class tokens. Deliberately not full Unicode
/// whitespace: an NBSP or ideographic space is content, not markup structure.
fn is_space(c : Char) -> Bool {
  c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\u{0c}'
}

///|
/// Build a `String` from the half-open slice `doc[lo:hi]`.
fn range_to_string(doc : Array[Char], lo : Int, hi : Int) -> String {
  let sb = StringBuilder::new()
  for i in lo..<hi {
    sb.write_char(doc[i])
  }
  sb.to_string()
}

///|
/// Whether `needle` (assumed already ASCII-lowercase) matches `doc` at index `i`
/// under ASCII case-folding. Out-of-range starts return `false`.
fn ci_matches_at(doc : Array[Char], i : Int, needle : Array[Char]) -> Bool {
  let m = needle.length()
  if i < 0 || i + m > doc.length() {
    return false
  }
  for k in 0..<m {
    if lower_ascii(doc[i + k]) != needle[k] {
      return false
    }
  }
  true
}

///|
/// First index at which `needle` (ASCII-lowercase) occurs in `doc` under ASCII
/// case-folding, or `-1` if absent. An empty needle matches at `0`.
fn index_ci(doc : Array[Char], needle : Array[Char]) -> Int {
  let n = doc.length()
  let m = needle.length()
  for i in 0..<(n - m + 1) {
    if ci_matches_at(doc, i, needle) {
      return i
    }
  }
  -1
}

///|
/// ASCII case-insensitive string equality — for comparing attribute values
/// (`lang`, `charset`) whose canonical forms are ASCII.
fn ci_eq(a : String, b : String) -> Bool {
  let ca = a.to_array()
  let cb = b.to_array()
  if ca.length() != cb.length() {
    return false
  }
  for i in 0..<ca.length() {
    if lower_ascii(ca[i]) != lower_ascii(cb[i]) {
      return false
    }
  }
  true
}

///|
/// Remove every HTML comment `<!--...-->` from `doc`, returning a new char array.
/// Comments are stripped once, up front, so all later scans operate on markup
/// only: the template embeds `<section class="slide">` and `<img src="assets/…">`
/// literals inside its head comment, and those must not be mistaken for real
/// elements. An unterminated comment swallows the rest of the document (matching
/// browser behavior).
fn strip_comments(doc : Array[Char]) -> Array[Char] {
  let out : Array[Char] = []
  let n = doc.length()
  let open = ['<', '!', '-', '-']
  let close = ['-', '-', '>']
  let mut i = 0
  while i < n {
    if ci_matches_at(doc, i, open) {
      let mut j = i + 4
      while j < n && !ci_matches_at(doc, j, close) {
        j = j + 1
      }
      i = if j < n { j + 3 } else { n }
    } else {
      out.push(doc[i])
      i = i + 1
    }
  }
  out
}

///|
/// Whether an open `<style>` or `<script>` tag — a raw-text element whose content
/// browsers do not parse as HTML — begins at `<` index `i`, returning the tag
/// name if so. A tag-name boundary (whitespace, `>`, `/`, or end) is required, so
/// `<styles>` does not match; a close tag (`</style>`) never matches.
fn raw_text_open(doc : Array[Char], i : Int) -> String? {
  for tag in ["style", "script"] {
    let needle = tag.to_array()
    if ci_matches_at(doc, i + 1, needle) {
      let after = i + 1 + needle.length()
      if after >= doc.length() {
        return Some(tag)
      }
      let c = doc[after]
      if is_space(c) || c == '>' || c == '/' {
        return Some(tag)
      }
    }
  }
  None
}

///|
/// Blank the content of `<style>` and `<script>` raw-text elements, keeping their
/// open and close tags. Browsers do not parse markup inside these elements, so a
/// `<img src=…>` or `<section class="slide">` written in CSS (as the template's
/// placeholder note is) must not be scanned as a real element. Run after
/// `strip_comments`. The close tag matches only at a name boundary, so
/// `</stylex>` does not close a `<style>`. An unterminated raw-text element runs
/// to end of document (browsers keep consuming raw text), so its remainder is
/// blanked too — an unclosed `<style>` then cascades to `frame.style` plus
/// `frame.body`/`frame.no_slides`, which matches its blank render.
fn strip_raw_text(doc : Array[Char]) -> Array[Char] {
  let out : Array[Char] = []
  let n = doc.length()
  let mut i = 0
  while i < n {
    if doc[i] == '<' {
      match raw_text_open(doc, i) {
        Some(tag) => {
          let past_gt = skip_tag(doc, i, n)
          for k in i..<past_gt {
            out.push(doc[k])
          }
          let close = find_close_tag(doc, tag, past_gt)
          i = if close >= 0 { close } else { n }
        }
        None => {
          out.push(doc[i])
          i = i + 1
        }
      }
    } else {
      out.push(doc[i])
      i = i + 1
    }
  }
  out
}

// -- Tag and attribute scanning ---------------------------------------------

///|
/// From `<` at index `i`, return the index just past the closing `>`, honoring
/// quoted attribute values (a `>` inside `"..."`/`'...'` does not close the tag).
/// Returns `end` if the tag is never closed before `end`.
fn skip_tag(doc : Array[Char], i : Int, end : Int) -> Int {
  let mut j = i
  let mut in_quote = false
  let mut quote = ' '
  while j < end {
    let c = doc[j]
    if in_quote {
      if c == quote {
        in_quote = false
      }
    } else if c == '"' || c == '\'' {
      in_quote = true
      quote = c
    } else if c == '>' {
      return j + 1
    }
    j = j + 1
  }
  end
}

///|
/// Parse the open tag beginning at `<` index `lt` into
/// `(tag, attrs_lo, attrs_hi, past_gt)`: the ASCII-lowercased tag name, the
/// half-open `[attrs_lo, attrs_hi)` span of its attribute region (between the
/// tag name and the closing `>`), and the index just past `>`.
fn scan_open_tag(doc : Array[Char], lt : Int) -> (String, Int, Int, Int) {
  let n = doc.length()
  let name_start = lt + 1
  let mut i = name_start
  while i < n && is_ascii_letter(doc[i]) {
    i = i + 1
  }
  let sb = StringBuilder::new()
  for k in name_start..<i {
    sb.write_char(lower_ascii(doc[k]))
  }
  let tag = sb.to_string()
  let attrs_lo = i
  let past_gt = skip_tag(doc, lt, n)
  let attrs_hi = if past_gt >= 1 && past_gt <= n && doc[past_gt - 1] == '>' {
    past_gt - 1
  } else {
    past_gt
  }
  (tag, attrs_lo, attrs_hi, past_gt)
}

///|
/// Read attribute `name` (matched case-insensitively) from the attribute region
/// `doc[lo:hi]`. Returns the value for `name="v"`, `name='v'`, or `name=v`; an
/// empty string for a boolean attribute (`name` with no `=`); and `None` when
/// `name` is absent. The first occurrence wins.
fn get_attr(doc : Array[Char], lo : Int, hi : Int, name : String) -> String? {
  let mut i = lo
  while i < hi {
    while i < hi && !is_attr_name_char(doc[i]) {
      i = i + 1
    }
    if i >= hi {
      break
    }
    let ns = i
    while i < hi && is_attr_name_char(doc[i]) {
      i = i + 1
    }
    let attr_name = range_to_string(doc, ns, i)
    while i < hi && is_space(doc[i]) {
      i = i + 1
    }
    let mut value = ""
    if i < hi && doc[i] == '=' {
      i = i + 1
      while i < hi && is_space(doc[i]) {
        i = i + 1
      }
      if i < hi && (doc[i] == '"' || doc[i] == '\'') {
        let q = doc[i]
        i = i + 1
        let vs = i
        while i < hi && doc[i] != q {
          i = i + 1
        }
        value = range_to_string(doc, vs, i)
        if i < hi {
          i = i + 1
        }
      } else {
        let vs = i
        while i < hi && !is_space(doc[i]) && doc[i] != '>' {
          i = i + 1
        }
        value = range_to_string(doc, vs, i)
      }
    }
    if ci_eq(attr_name, name) {
      return Some(value)
    }
  }
  None
}

///|
/// Whether the class-attribute segment `cs[s:e]` equals `tk` exactly. Class
/// tokens are case-sensitive, unlike tag and attribute names.
fn seg_eq(cs : Array[Char], s : Int, e : Int, tk : Array[Char]) -> Bool {
  if e - s != tk.length() {
    return false
  }
  for k in 0..<tk.length() {
    if cs[s + k] != tk[k] {
      return false
    }
  }
  true
}

///|
/// Whether the whitespace-separated `value` contains `token` as a whole token —
/// so `class="col-fig tall"` has token `tall` but not `col`.
fn has_token(value : String, token : String) -> Bool {
  let cs = value.to_array()
  let tk = token.to_array()
  let n = cs.length()
  let mut i = 0
  while i < n {
    while i < n && is_space(cs[i]) {
      i = i + 1
    }
    let s = i
    while i < n && !is_space(cs[i]) {
      i = i + 1
    }
    if i > s && seg_eq(cs, s, i, tk) {
      return true
    }
  }
  false
}

///|
/// Whether the open tag with attribute region `doc[lo:hi]` carries class
/// `token`.
fn has_class(doc : Array[Char], lo : Int, hi : Int, token : String) -> Bool {
  match get_attr(doc, lo, hi, "class") {
    Some(v) => has_token(v, token)
    None => false
  }
}

///|
/// Indices of every `<` that opens a `name` tag (matched case-insensitively):
/// requires a tag-name boundary (whitespace, `>`, `/`, or end) after `name` so
/// `<html>` matches but `<htmlx>` does not, and skips close tags (`</name>`).
/// Walks tag by tag via `skip_tag`, so a `<name>` sitting inside a quoted
/// attribute value of an earlier tag is stepped over as part of that tag, never
/// mistaken for a real open tag — the same quote-safety `find_by_class` gives
/// slide discovery. Runs on the cleaned doc (raw-text content already blanked),
/// so no `<` inside CSS/JS reaches this scan.
fn find_all_open_tags(doc : Array[Char], name : String) -> Array[Int] {
  let out : Array[Int] = []
  let needle = name.to_array()
  let n = doc.length()
  let m = needle.length()
  let mut i = 0
  while i < n {
    if doc[i] == '<' {
      if i + 1 < n && doc[i + 1] != '/' && ci_matches_at(doc, i + 1, needle) {
        let after = i + 1 + m
        if after >= n ||
          is_space(doc[after]) ||
          doc[after] == '>' ||
          doc[after] == '/' {
          out.push(i)
        }
      }
      i = skip_tag(doc, i, n)
    } else {
      i = i + 1
    }
  }
  out
}

///|
/// Index of the first `</name>` close tag at or after `from` (matched
/// case-insensitively), requiring a name boundary (whitespace, `>`, `/`, or end)
/// after `name` so `</style>` matches but `</stylex>` does not. Returns the index
/// of its `<`, or `-1` when absent.
fn find_close_tag(doc : Array[Char], name : String, from : Int) -> Int {
  let needle = name.to_array()
  let n = doc.length()
  let m = needle.length()
  for i in from..<n {
    if doc[i] == '<' &&
      i + 1 < n &&
      doc[i + 1] == '/' &&
      ci_matches_at(doc, i + 2, needle) {
      let after = i + 2 + m
      if after >= n {
        return i
      }
      let c = doc[after]
      if is_space(c) || c == '>' || c == '/' {
        return i
      }
    }
  }
  -1
}

///|
/// Whether `tag` (ASCII-lowercase) names an HTML void element — one that never
/// has content or a close tag. `match_close` returns an empty span for these so
/// a `<img>`/`<br>` is not treated as an unclosed container.
fn is_void_tag(tag : String) -> Bool {
  match tag {
    "area"
    | "base"
    | "br"
    | "col"
    | "embed"
    | "hr"
    | "img"
    | "input"
    | "link"
    | "meta"
    | "param"
    | "source"
    | "track"
    | "wbr" => true
    _ => false
  }
}

///|
/// If a `</name>` close tag begins at index `i` within `doc[:end]`, return the
/// index just past its `>`; otherwise `None`. A name boundary (whitespace, `>`,
/// `/`, or region end) is required, so `</div>` does not match `</division>`.
fn is_close_tag_at(
  doc : Array[Char],
  i : Int,
  name : Array[Char],
  end : Int,
) -> Int? {
  let m = name.length()
  if i + 2 + m > end || doc[i] != '<' || doc[i + 1] != '/' {
    return None
  }
  if !ci_matches_at(doc, i + 2, name) {
    return None
  }
  let after = i + 2 + m
  if after < end {
    let c = doc[after]
    if !(is_space(c) || c == '>' || c == '/') {
      return None
    }
  }
  Some(skip_tag(doc, i, end))
}

///|
/// Given `from` positioned just past a `name` open tag's `>`, find that element's
/// matching close within `doc[:end]`, returning `(close_lt, past_gt)`: the index
/// of the close tag's `<` and the index just past its `>`. Depth-matched, so a
/// nested same-name element's close does not end the parent (`<div><div></div>`
/// resolves to the outer `</div>`). A void `name` has no content, yielding
/// `(from, from)`; an unbalanced element yields `(end, end)`.
fn match_close(
  doc : Array[Char],
  name : String,
  from : Int,
  end : Int,
) -> (Int, Int) {
  if is_void_tag(name) {
    return (from, from)
  }
  let needle = name.to_array()
  let m = needle.length()
  let mut depth = 1
  let mut i = from
  while i < end {
    if doc[i] == '<' {
      match is_close_tag_at(doc, i, needle, end) {
        Some(past) => {
          depth = depth - 1
          if depth == 0 {
            return (i, past)
          }
          i = past
        }
        None => {
          // A same-name open tag raises depth; any other tag is skipped whole
          // (quote-aware), so a `>` inside an attribute value never mis-splits.
          let mut opened = false
          if i + 1 < end &&
            doc[i + 1] != '/' &&
            ci_matches_at(doc, i + 1, needle) {
            let after = i + 1 + m
            if after >= end ||
              is_space(doc[after]) ||
              doc[after] == '>' ||
              doc[after] == '/' {
              opened = true
            }
          }
          if opened {
            depth = depth + 1
          }
          i = skip_tag(doc, i, end)
        }
      }
    } else {
      i = i + 1
    }
  }
  (end, end)
}

// -- Element discovery -------------------------------------------------------

///|
/// A matched element: the class `token` it matched on and the half-open
/// `[lo, hi)` span of its inner HTML (between the open tag's `>` and the close
/// tag's `<`). The tag name is filtered inside `find_by_class` (via `want_tag`),
/// so callers never need it on the result.
priv struct Elem {
  token : String
  lo : Int
  hi : Int
}

///|
/// The first of `tokens` that appears as a whole class on the open tag with
/// attribute region `doc[lo:hi]`, or `None` if the element carries none of them.
fn match_class(
  doc : Array[Char],
  lo : Int,
  hi : Int,
  tokens : Array[String],
) -> String? {
  for tk in tokens {
    if has_class(doc, lo, hi, tk) {
      return Some(tk)
    }
  }
  None
}

///|
/// The outermost elements within `doc[start:end]` whose class carries one of
/// `tokens`, in document order. A match's body is skipped (via `match_close`), so
/// a nested same-class element is not reported as a sibling; non-matching
/// elements are descended into. Every tag is skipped past its real `>`, so a `<`
/// inside a quoted attribute value is never mistaken for a tag.
///
/// `want_tag` (default `""` = any) constrains a match to that ASCII-lowercase
/// tag name: a class match on a different tag is treated as a non-match and
/// descended into, so a real `<section class="slide">` nested inside a
/// `<div class="slide">` wrapper is still found rather than hidden behind the
/// wrapper's skipped body.
fn find_by_class(
  doc : Array[Char],
  start : Int,
  end : Int,
  tokens : Array[String],
  want_tag? : String = "",
) -> Array[Elem] {
  let out : Array[Elem] = []
  let mut i = start
  while i < end {
    if doc[i] == '<' {
      if i + 1 < end && (doc[i + 1] == '/' || doc[i + 1] == '!') {
        i = skip_tag(doc, i, end)
      } else {
        let (tag, lo, hi, past_gt) = scan_open_tag(doc, i)
        match match_class(doc, lo, hi, tokens) {
          Some(tk) =>
            if want_tag == "" || want_tag == tag {
              let (close_lt, close_past) = match_close(doc, tag, past_gt, end)
              out.push(Elem::{ token: tk, lo: past_gt, hi: close_lt })
              i = close_past
            } else {
              // Right class, wrong tag: descend so a nested wanted element
              // (e.g. a real `<section class="slide">` under `<div class="slide">`)
              // is not hidden behind this element's skipped body.
              i = past_gt
            }
          None => i = past_gt
        }
      }
    } else {
      i = i + 1
    }
  }
  out
}

// -- Slide model -------------------------------------------------------------

///|
/// One `.entry` within a slide. An empty marker in M2.1b; M2.1c fills it with the
/// three-tier text and furigana it carries.
priv struct Entry {}

///|
/// A parsed `<section class="slide">`: the counts of its `.eyebrow` and `.pageno`
/// children and its list of `.entry` elements. The counts drive the "exactly one"
/// checks; the list drives the "at least one entry" check.
priv struct Slide {
  eyebrow_count : Int
  pageno_count : Int
  entries : Array[Entry]
}

///|
/// Parse every `<section class="slide">` into a `Slide`, tallying its outermost
/// `.eyebrow`/`.pageno`/`.entry` descendants. Only `<section>` elements count as
/// slides (a `<div class="slide">` is not a slide, but a real
/// `<section class="slide">` nested inside one is still found — `want_tag`
/// descends through the non-section wrapper). Replaces the M2.1a slide count:
/// `scan_deck(doc).length()` is the slide total.
fn scan_deck(doc : Array[Char]) -> Array[Slide] {
  let slides : Array[Slide] = []
  for el in find_by_class(doc, 0, doc.length(), ["slide"], want_tag="section") {
    let mut eyebrow_count = 0
    let mut pageno_count = 0
    let entries : Array[Entry] = []
    for part in find_by_class(doc, el.lo, el.hi, ["eyebrow", "pageno", "entry"]) {
      match part.token {
        "eyebrow" => eyebrow_count = eyebrow_count + 1
        "pageno" => pageno_count = pageno_count + 1
        "entry" => entries.push(Entry::{  })
        _ => ()
      }
    }
    slides.push(Slide::{ eyebrow_count, pageno_count, entries })
  }
  slides
}

// -- Checks ------------------------------------------------------------------

///|
/// Document-envelope checks: the doctype, the `<html lang="ja">` root, a UTF-8
/// charset, a `<style>` closed before `<body>`, and a complete `<body>`/`</html>`
/// close. Findings are appended to `out` in this order.
fn check_frame(doc : Array[Char], out : Report) -> Unit {
  let doctype = "<!doctype html".to_array()
  let dt = index_ci(doc, doctype)
  let doctype_ok = if dt >= 0 {
    let after = dt + doctype.length()
    after >= doc.length() || is_space(doc[after]) || doc[after] == '>'
  } else {
    false
  }
  if !doctype_ok {
    out.findings.push(must("frame.doctype", "missing <!doctype html>"))
  }
  let html_tags = find_all_open_tags(doc, "html")
  let lang_ok = if html_tags.length() > 0 {
    let (_, lo, hi, _) = scan_open_tag(doc, html_tags[0])
    match get_attr(doc, lo, hi, "lang") {
      Some(v) => ci_eq(v, "ja")
      None => false
    }
  } else {
    false
  }
  if !lang_ok {
    out.findings.push(must("frame.html_lang", "<html> lang must be \"ja\""))
  }
  let mut charset_ok = false
  for lt in find_all_open_tags(doc, "meta") {
    let (_, lo, hi, _) = scan_open_tag(doc, lt)
    match get_attr(doc, lo, hi, "charset") {
      Some(v) => if ci_eq(v, "utf-8") { charset_ok = true }
      None => ()
    }
  }
  if !charset_ok {
    out.findings.push(must("frame.charset", "missing <meta charset=\"utf-8\">"))
  }
  // Tag- and attribute-aware (not exact-literal): `<body class="deck">` and
  // `<style media="screen">` are still recognized, and a `</style>` only counts
  // when it follows the `<style>` it closes (a stray earlier `</style>` cannot
  // satisfy the check for a later, unclosed `<style>`).
  let body_tags = find_all_open_tags(doc, "body")
  let body_lt = if body_tags.length() > 0 { body_tags[0] } else { -1 }
  let style_tags = find_all_open_tags(doc, "style")
  let style_lt = if style_tags.length() > 0 { style_tags[0] } else { -1 }
  let style_close = if style_lt >= 0 {
    find_close_tag(doc, "style", style_lt)
  } else {
    -1
  }
  let style_ok = style_lt >= 0 &&
    style_close >= 0 &&
    (body_lt < 0 || style_close < body_lt)
  if !style_ok {
    out.findings.push(
      must("frame.style", "<style> must be present and closed before <body>"),
    )
  }
  let body_ok = body_lt >= 0 &&
    find_close_tag(doc, "body", body_lt) >= 0 &&
    find_close_tag(doc, "html", body_lt) >= 0
  if !body_ok {
    out.findings.push(must("frame.body", "missing <body>, </body>, or </html>"))
  }
}

///|
/// Per-slide structure checks: every slide must carry exactly one `.eyebrow`
/// (`slide.eyebrow_count`) and exactly one `.pageno` (`slide.pageno_count`), and
/// at least one `.entry` (`slide.no_entry`). Text and furigana checks are added
/// in later M2.1 slices.
fn check_slides(slides : Array[Slide], out : Report) -> Unit {
  for s in slides {
    if s.eyebrow_count != 1 {
      out.findings.push(
        must("slide.eyebrow_count", "slide must have exactly one .eyebrow"),
      )
    }
    if s.pageno_count != 1 {
      out.findings.push(
        must("slide.pageno_count", "slide must have exactly one .pageno"),
      )
    }
    if s.entries.length() == 0 {
      out.findings.push(
        must("slide.no_entry", "slide must have at least one .entry"),
      )
    }
  }
}

///|
/// Image checks: every `<img>` must have a `src` under `assets/`
/// (`img.not_asset`) that names an asset file present in the bundle
/// (`img.missing`). `assets` holds `assets/<name>` paths from `list_assets`.
fn check_imgs(
  doc : Array[Char],
  assets : @set.Set[String],
  out : Report,
) -> Unit {
  for lt in find_all_open_tags(doc, "img") {
    let (_, lo, hi, _) = scan_open_tag(doc, lt)
    match get_attr(doc, lo, hi, "src") {
      None => out.findings.push(must("img.not_asset", "<img> without src"))
      Some(src) =>
        if !src.has_prefix("assets/") {
          out.findings.push(
            must("img.not_asset", "<img src=\"\{src}\"> not under assets/"),
          )
        } else if !assets.contains(src) {
          out.findings.push(
            must("img.missing", "<img src=\"\{src}\"> has no matching asset"),
          )
        }
    }
  }
}

// -- Public API --------------------------------------------------------------

///|
/// Validate a deck's HTML against the envelope, slide-structure, and image
/// contract, returning a structured `Report`. `slug` is the project name used by
/// the per-slide text checks added in M2.1b-ii (unused here). `assets` holds the
/// bundle's `assets/<name>` files. Comments and raw-text content are stripped
/// once before any scan.
pub fn validate_deck(
  html : String,
  slug : String,
  assets : @set.Set[String],
) -> Report {
  // Reserved for M2.1b's `.pageno` check; declared unused for now.
  let _ = slug
  let doc = strip_raw_text(strip_comments(html.to_array()))
  let out = Report::{ findings: [] }
  check_frame(doc, out)
  let slides = scan_deck(doc)
  if slides.length() == 0 {
    out.findings.push(must("frame.no_slides", "no <section class=\"slide\">"))
  }
  check_slides(slides, out)
  check_imgs(doc, assets, out)
  out
}

///|
/// The bundle's asset set: `assets/<name>` for each regular file in `dir/assets/`.
/// A missing `dir/assets/` is not an error — a deck may ship zero figures — so it
/// yields the empty set. Subdirectories are skipped: only files can back an
/// `<img src>`, so a directory must never satisfy an `img.missing` check.
pub async fn list_assets(dir : String) -> @set.Set[String] {
  let names : Array[String] = []
  let assets_dir = "\{dir}/assets"
  if @fs.exists(assets_dir) {
    for name in @fs.readdir(assets_dir) {
      match @fs.kind("\{assets_dir}/\{name}", follow_symlink=true) {
        @fs.Regular => names.push("assets/\{name}")
        _ => ()
      }
    }
  }
  @set.Set(names[:])
}

///|
/// Validate the deck bundle rooted at `dir`: read `dir/deck.html`, collect its
/// assets, and run `validate_deck`. Raises if `deck.html` is unreadable.
pub async fn validate_deck_dir(dir : String, slug : String) -> Report {
  let html = @fs.read_file("\{dir}/deck.html").text()
  let assets = list_assets(dir)
  validate_deck(html, slug, assets)
}
