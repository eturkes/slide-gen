// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Severity of a validator `Finding`: `Must` blocks a bundle, `Should` warns.
/// M2.1's checks are all `Must`; the `Should` variant is constructed by the
/// M2.2 provenance coverage warnings (untagged numbers, uncited assets).
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
/// Construct an advisory (`Should`) finding — a warning that does not block a
/// bundle. First used by the M2.2 provenance coverage warnings.
fn should(code : String, detail : String) -> Finding {
  Finding::{ severity: Should, code, detail }
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
/// HTML tag-name continuation in the tokenizer's tag-name state. Tags still
/// begin with an ASCII letter, then every codepoint up to structural whitespace,
/// `/`, or `>` belongs to the name. Thus no punctuation can be misread as a
/// boundary that turns a look-alike (`rt_foo`) into a real `rt` tag.
fn is_tag_name_char(c : Char) -> Bool {
  !is_space(c) && c != '/' && c != '>' && c != '\u{0}'
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
/// Whether `<` at `i` begins an ordinary open tag. HTML tag names begin with an
/// ASCII letter; requiring that letter keeps a stray text `<` (`5 < 6`) out of
/// the markup path instead of letting it swallow the next real tag.
fn is_open_tag_start(doc : Array[Char], i : Int, end : Int) -> Bool {
  i >= 0 && i + 1 < end && doc[i] == '<' && is_ascii_letter(doc[i + 1])
}

///|
/// Whether `<` at `i` begins an ordinary close tag.
fn is_close_tag_start(doc : Array[Char], i : Int, end : Int) -> Bool {
  i >= 0 &&
  i + 2 < end &&
  doc[i] == '<' &&
  doc[i + 1] == '/' &&
  is_ascii_letter(doc[i + 2])
}

///|
/// Whether `<` at `i` begins markup that must be stepped over atomically. Open
/// and close tags plus declarations/processing instructions qualify; a stray
/// text `<` does not. Stepping a complete tag via `skip_tag` is what prevents a
/// comment/raw-text-shaped substring inside a quoted attribute from changing
/// parser context.
fn is_markup_start(doc : Array[Char], i : Int, end : Int) -> Bool {
  is_open_tag_start(doc, i, end) ||
  is_close_tag_start(doc, i, end) ||
  (
    i >= 0 &&
    i + 1 < end &&
    doc[i] == '<' &&
    (doc[i + 1] == '!' || doc[i + 1] == '?')
  )
}

///|
/// Append `doc[lo:hi]` verbatim to `out`.
fn append_range(
  out : Array[Char],
  doc : Array[Char],
  lo : Int,
  hi : Int,
) -> Unit {
  for i in lo..<hi {
    out.push(doc[i])
  }
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
/// Clean the document in one context-aware pass: remove HTML comments and blank
/// `<style>`/`<script>` raw text while retaining their tags. Ordinary tags are
/// copied atomically via the quote-aware `skip_tag`, so `<!--` or `<style>`
/// inside an attribute value cannot switch cleaning context and hide later
/// markup. Raw-text end tags follow browser tokenization, comments swallow to
/// their terminator (or EOF), and an unterminated raw-text element blanks to EOF.
fn clean_doc(doc : Array[Char]) -> Array[Char] {
  let out : Array[Char] = []
  let n = doc.length()
  let comment_open = ['<', '!', '-', '-']
  let comment_close = ['-', '-', '>']
  let mut i = 0
  while i < n {
    if ci_matches_at(doc, i, comment_open) {
      // The shortest valid empty comment is `<!--->`: its `-->` overlaps the
      // opener's final hyphen, so closing-tag search begins two codepoints into
      // the opener rather than only after it.
      let mut close = i + 2
      while close < n && !ci_matches_at(doc, close, comment_close) {
        close = close + 1
      }
      i = if close < n { close + comment_close.length() } else { n }
    } else if is_open_tag_start(doc, i, n) {
      match raw_text_open(doc, i) {
        Some(tag) => {
          let past_gt = skip_tag(doc, i, n)
          append_range(out, doc, i, past_gt)
          let close = find_raw_close_tag(doc, tag, past_gt)
          if close >= 0 {
            let close_past = skip_tag(doc, close, n)
            append_range(out, doc, close, close_past)
            i = close_past
          } else {
            i = n
          }
        }
        None => {
          let past_gt = skip_tag(doc, i, n)
          append_range(out, doc, i, past_gt)
          i = past_gt
        }
      }
    } else if is_markup_start(doc, i, n) {
      let past_gt = skip_tag(doc, i, n)
      append_range(out, doc, i, past_gt)
      i = past_gt
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
  while i < n && is_tag_name_char(doc[i]) {
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
/// One parsed attribute. `name` is ASCII-lowercased (HTML attribute names are
/// case-insensitive); `value` is the authored value before character-reference
/// decoding. Boolean attributes carry an empty value.
priv struct Attr {
  name : String
  value : String
}

///|
/// Parse every attribute in `doc[lo:hi]`, preserving duplicate attributes so a
/// security scan cannot hide an event/resource attribute behind an earlier
/// duplicate. Double-, single-, and unquoted values are supported; malformed
/// unterminated values consume the remaining region, matching the browser's
/// fail-closed shape closely enough that later text cannot become a new tag.
fn scan_attrs(doc : Array[Char], lo : Int, hi : Int) -> Array[Attr] {
  let out : Array[Attr] = []
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
    let name_out = StringBuilder::new()
    for k in ns..<i {
      name_out.write_char(lower_ascii(doc[k]))
    }
    let attr_name = name_out.to_string()
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
    out.push(Attr::{ name: attr_name, value })
  }
  out
}

///|
/// Read attribute `name` (matched case-insensitively) from the attribute region
/// `doc[lo:hi]`. Returns the value for `name="v"`, `name='v'`, or `name=v`; an
/// empty string for a boolean attribute (`name` with no `=`); and `None` when
/// `name` is absent. The first occurrence wins, matching HTML duplicate-
/// attribute parsing; `scan_attrs` remains available to security checks that
/// must inspect every authored duplicate.
fn get_attr(doc : Array[Char], lo : Int, hi : Int, name : String) -> String? {
  for attr in scan_attrs(doc, lo, hi) {
    if ci_eq(attr.name, name) {
      return Some(attr.value)
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
    if is_open_tag_start(doc, i, n) {
      if ci_matches_at(doc, i + 1, needle) {
        let after = i + 1 + m
        if after >= n ||
          is_space(doc[after]) ||
          doc[after] == '>' ||
          doc[after] == '/' {
          out.push(i)
        }
      }
      i = skip_tag(doc, i, n)
    } else if is_markup_start(doc, i, n) {
      i = skip_tag(doc, i, n)
    } else {
      i = i + 1
    }
  }
  out
}

///|
/// Index of the first raw-text `</name>` end tag at or after `from`. Raw-text
/// parsing deliberately examines every character: browsers close `<style>` or
/// `<script>` on an end-tag sequence even when it looks quoted to CSS/JS.
fn find_raw_close_tag(doc : Array[Char], name : String, from : Int) -> Int {
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
/// Index of the first real `</name>` close tag at or after `from`, matched
/// case-insensitively at a tag-name boundary. Ordinary markup is walked one tag
/// at a time, so a close-tag literal inside an attribute cannot satisfy a frame
/// or depth check; stray text `<` advances one character and cannot swallow the
/// next tag.
fn find_close_tag(doc : Array[Char], name : String, from : Int) -> Int {
  let needle = name.to_array()
  let n = doc.length()
  let m = needle.length()
  let mut i = from
  while i < n {
    if is_close_tag_start(doc, i, n) && ci_matches_at(doc, i + 2, needle) {
      let after = i + 2 + m
      if after >= n ||
        is_space(doc[after]) ||
        doc[after] == '>' ||
        doc[after] == '/' {
        return i
      }
      i = skip_tag(doc, i, n)
    } else if is_markup_start(doc, i, n) {
      i = skip_tag(doc, i, n)
    } else {
      i = i + 1
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
    if is_close_tag_start(doc, i, end) {
      match is_close_tag_at(doc, i, needle, end) {
        Some(past) => {
          depth = depth - 1
          if depth == 0 {
            return (i, past)
          }
          i = past
        }
        None => i = skip_tag(doc, i, end)
      }
    } else if is_open_tag_start(doc, i, end) {
      // A same-name open tag raises depth; any other tag is skipped whole
      // (quote-aware), so a `>` inside an attribute value never mis-splits.
      if ci_matches_at(doc, i + 1, needle) {
        let after = i + 1 + m
        if after >= end ||
          is_space(doc[after]) ||
          doc[after] == '>' ||
          doc[after] == '/' {
          depth = depth + 1
        }
      }
      i = skip_tag(doc, i, end)
    } else if is_markup_start(doc, i, end) {
      i = skip_tag(doc, i, end)
    } else {
      i = i + 1
    }
  }
  (end, end)
}

///|
/// Classify the tag beginning at `<` index `i` within `doc[:end]`, returning
/// `(name, is_close, past_gt)`: the ASCII-lowercase tag name, whether it is a
/// closing tag (`</name>`), and the index just past the tag's `>` (quote-aware).
/// The name is empty for a nameless tag. Used by the furigana scans, which must
/// react to both the open and close of `<ruby>`/`<rt>`/`<code>`.
fn classify_tag(doc : Array[Char], i : Int, end : Int) -> (String, Bool, Int) {
  let is_close = i + 1 < end && doc[i + 1] == '/'
  let name_start = if is_close { i + 2 } else { i + 1 }
  let mut j = name_start
  while j < end && is_tag_name_char(doc[j]) {
    j = j + 1
  }
  // A name is accepted only when a structural boundary follows. `rt2` and
  // `ruby-foo` remain distinct full names and therefore cannot match the
  // furigana tags `rt`/`ruby`.
  let bounded = j >= end || is_space(doc[j]) || doc[j] == '>' || doc[j] == '/'
  let name = if bounded {
    let sb = StringBuilder::new()
    for k in name_start..<j {
      sb.write_char(lower_ascii(doc[k]))
    }
    sb.to_string()
  } else {
    ""
  }
  (name, is_close, skip_tag(doc, i, end))
}

// -- Element discovery -------------------------------------------------------

///|
/// A matched element: the class `token` it matched on, the `open_lt` index of
/// its own opening `<` (so a check can scan the element's own attributes, not
/// only its descendants — e.g. a `data-claim` on the `.entry`/`.cap` itself),
/// and the half-open `[lo, hi)` span of its inner HTML (between the open tag's
/// `>` and the close tag's `<`). The tag name is filtered inside `find_by_class`
/// (via `want_tag`), so callers never need it on the result.
priv struct Elem {
  token : String
  open_lt : Int
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
    if is_open_tag_start(doc, i, end) {
      let (tag, lo, hi, past_gt) = scan_open_tag(doc, i)
      match match_class(doc, lo, hi, tokens) {
        Some(tk) =>
          if want_tag == "" || want_tag == tag {
            let (close_lt, close_past) = match_close(doc, tag, past_gt, end)
            out.push(Elem::{ token: tk, open_lt: i, lo: past_gt, hi: close_lt })
            i = close_past
          } else {
            // Right class, wrong tag: descend so a nested wanted element
            // (e.g. a real `<section class="slide">` under `<div class="slide">`)
            // is not hidden behind this element's skipped body.
            i = past_gt
          }
        None => i = past_gt
      }
    } else if is_markup_start(doc, i, end) {
      i = skip_tag(doc, i, end)
    } else {
      i = i + 1
    }
  }
  out
}

// -- Text extraction and entity decoding ------------------------------------

///|
/// The two-digit decimal form of a slide number: `1` -> `01`, `10` -> `10`. The
/// `.eyebrow .n` check compares against this for a slide's 1-based index.
fn two_digit(n : Int) -> String {
  if n < 10 {
    "0\{n}"
  } else {
    "\{n}"
  }
}

///|
/// Trim leading and trailing ASCII/HTML whitespace from `s`; interior whitespace
/// and non-ASCII spaces (a decoded NBSP is content) are preserved.
fn trim_ws(s : String) -> String {
  let cs = s.to_array()
  let n = cs.length()
  let mut lo = 0
  while lo < n && is_space(cs[lo]) {
    lo = lo + 1
  }
  let mut hi = n
  while hi > lo && is_space(cs[hi - 1]) {
    hi = hi - 1
  }
  range_to_string(cs, lo, hi)
}

///|
/// The character an HTML named reference denotes, for the small set the deck
/// uses plus ASCII punctuation that could otherwise disguise a URL/CSS token,
/// or `None` for any other name. These semicolon-terminated forms are a
/// deliberate subset of HTML5's named references, not the full table; `Tab` and
/// `NewLine` retain their standard case-sensitive spellings.
fn named_entity(name : String) -> Char? {
  match name {
    "NewLine" => Some('\n')
    "Tab" => Some('\t')
    "amp" => Some('&')
    "lt" => Some('<')
    "gt" => Some('>')
    "quot" => Some('"')
    "apos" => Some('\'')
    "nbsp" => Some('\u{a0}')
    "middot" => Some('\u{b7}')
    "ast" => Some('*')
    "bsol" => Some('\\')
    "colon" => Some(':')
    "commat" => Some('@')
    "lpar" => Some('(')
    "period" => Some('.')
    "rpar" => Some(')')
    "semi" => Some(';')
    "sol" => Some('/')
    _ => None
  }
}

///|
/// The value of digit `c` in `base` (10 or 16), or `None` if `c` is not a digit
/// of that base.
fn hex_val(c : Char, base : Int) -> Int? {
  let v = if c >= '0' && c <= '9' {
    c.to_int() - '0'.to_int()
  } else if c >= 'a' && c <= 'f' {
    c.to_int() - 'a'.to_int() + 10
  } else if c >= 'A' && c <= 'F' {
    c.to_int() - 'A'.to_int() + 10
  } else {
    -1
  }
  if v >= 0 && v < base {
    Some(v)
  } else {
    None
  }
}

///|
/// Parse an HTML character reference beginning at `&` (index `i`) within
/// `cs[:n]`, returning the decoded character and the index just past its
/// terminating `;`, or `None` when the text is not a well-formed reference.
/// Handles named (`&amp;`), decimal (`&#183;`), and hexadecimal (`&#xB7;`) forms;
/// a code point above `U+10FFFF` or in the surrogate range is rejected.
fn parse_entity(cs : Array[Char], i : Int, n : Int) -> (Char, Int)? {
  if i + 1 >= n {
    return None
  }
  if cs[i + 1] == '#' {
    let mut j = i + 2
    let base = if j < n && (cs[j] == 'x' || cs[j] == 'X') {
      j = j + 1
      16
    } else {
      10
    }
    let start = j
    let mut code = 0
    while j < n {
      match hex_val(cs[j], base) {
        Some(d) => {
          code = code * base + d
          if code > 0x10FFFF {
            return None
          }
          j = j + 1
        }
        None => break
      }
    }
    if j == start || j >= n || cs[j] != ';' {
      return None
    }
    match code.to_char() {
      Some(ch) => Some((ch, j + 1))
      None => None
    }
  } else {
    let start = i + 1
    let mut j = start
    while j < n && is_ascii_letter(cs[j]) {
      j = j + 1
    }
    if j == start || j >= n || cs[j] != ';' {
      return None
    }
    match named_entity(range_to_string(cs, start, j)) {
      Some(ch) => Some((ch, j + 1))
      None => None
    }
  }
}

///|
/// Decode every well-formed HTML character reference in `s`; a stray `&` that
/// does not begin a valid reference is kept literally, so the function is total.
fn decode_entities(s : String) -> String {
  let cs = s.to_array()
  let n = cs.length()
  let sb = StringBuilder::new()
  let mut i = 0
  while i < n {
    if cs[i] == '&' {
      match parse_entity(cs, i, n) {
        Some((ch, next)) => {
          sb.write_char(ch)
          i = next
        }
        None => {
          sb.write_char(cs[i])
          i = i + 1
        }
      }
    } else {
      sb.write_char(cs[i])
      i = i + 1
    }
  }
  sb.to_string()
}

///|
/// Parse a numeric character reference in an HTML attribute, where the trailing
/// semicolon is optional under browser error recovery. The strict text decoder
/// intentionally retains malformed references; the browser-boundary scan needs
/// the recovered value so spellings such as `u&#114l(` cannot disguise `url(`.
fn parse_attr_numeric_entity(
  cs : Array[Char],
  i : Int,
  n : Int,
) -> (Char, Int)? {
  if i + 2 >= n || cs[i] != '&' || cs[i + 1] != '#' {
    return None
  }
  let mut j = i + 2
  let base = if j < n && (cs[j] == 'x' || cs[j] == 'X') {
    j = j + 1
    16
  } else {
    10
  }
  let start = j
  let mut code = 0
  while j < n {
    match hex_val(cs[j], base) {
      Some(digit) => {
        code = code * base + digit
        if code > 0x10FFFF {
          return None
        }
        j = j + 1
      }
      None => break
    }
  }
  if j == start {
    return None
  }
  let past = if j < n && cs[j] == ';' { j + 1 } else { j }
  match code.to_char() {
    Some(ch) => Some((ch, past))
    None => None
  }
}

///|
/// Decode character references as consumed from an HTML attribute. Named
/// references retain the validator's semicolon-terminated subset; numeric
/// decimal/hex references additionally follow the browser's missing-semicolon
/// recovery. Used only for security-sensitive attribute values, leaving the
/// existing visible-text normalization contract unchanged.
fn decode_attr_entities(s : String) -> String {
  let cs = s.to_array()
  let n = cs.length()
  let sb = StringBuilder::new()
  let mut i = 0
  while i < n {
    if cs[i] == '&' {
      let parsed = match parse_attr_numeric_entity(cs, i, n) {
        Some(hit) => Some(hit)
        None => parse_entity(cs, i, n)
      }
      match parsed {
        Some((ch, next)) => {
          sb.write_char(ch)
          i = next
        }
        None => {
          sb.write_char(cs[i])
          i = i + 1
        }
      }
    } else {
      sb.write_char(cs[i])
      i = i + 1
    }
  }
  sb.to_string()
}

///|
/// The text content of the element body `doc[lo:hi]`: drop every tag (quote-aware
/// via `skip_tag`), decode character references, and trim surrounding ASCII
/// whitespace. Reads an `.eyebrow .n` and a `.pageno` for the slide-text checks.
fn inner_text(doc : Array[Char], lo : Int, hi : Int) -> String {
  let sb = StringBuilder::new()
  let mut i = lo
  while i < hi {
    if is_markup_start(doc, i, hi) {
      i = skip_tag(doc, i, hi)
    } else {
      sb.write_char(doc[i])
      i = i + 1
    }
  }
  trim_ws(decode_entities(sb.to_string()))
}

// -- Static/offline browser boundary ----------------------------------------

///|
/// Return the index after a canonical `-->` for the HTML comment beginning at
/// `i`. A malformed/unterminated opener advances only past `<!--`, making the
/// remainder visible to the fail-closed security scan: browsers abruptly close
/// some malformed comments (for example `<!-->`), while treating others as
/// comments, and scanning the ambiguous remainder can only over-reject. Callers
/// first establish a real opener outside a tag; quoted comment-shaped attribute
/// values remain inside the atomically skipped host tag.
fn skip_html_comment(doc : Array[Char], i : Int, end : Int) -> Int {
  let close = ['-', '-', '>']
  let mut j = i + 2
  while j < end && !ci_matches_at(doc, j, close) {
    j = j + 1
  }
  if j < end {
    j + close.length()
  } else if i + 4 < end {
    i + 4
  } else {
    end
  }
}

///|
/// Whether `i` begins a real `<!doctype html...>` declaration at an HTML-space
/// or `>` boundary. The frame check and static scanner share this recognition:
/// the doctype is the sole allowed declaration/processing-instruction shape.
fn is_html_doctype_at(doc : Array[Char], i : Int, end : Int) -> Bool {
  let needle = "<!doctype html".to_array()
  if !ci_matches_at(doc, i, needle) {
    return false
  }
  let after = i + needle.length()
  after >= end || is_space(doc[after]) || doc[after] == '>'
}

///|
/// Elements outside the inert, self-contained slide surface. The list covers
/// executable/conditional markup, nested browsing or plugin/media content,
/// navigation/submission, document URL/style mutation, foreign embedded
/// namespaces, and obsolete raw-text containers that alter parser context.
fn is_unsafe_static_tag(tag : String) -> Bool {
  match tag {
    "a"
    | "applet"
    | "area"
    | "audio"
    | "base"
    | "embed"
    | "fencedframe"
    | "foreignobject"
    | "form"
    | "frame"
    | "frameset"
    | "iframe"
    | "isindex"
    | "link"
    | "marquee"
    | "math"
    | "noembed"
    | "noframes"
    | "noscript"
    | "object"
    | "picture"
    | "plaintext"
    | "portal"
    | "script"
    | "source"
    | "svg"
    | "track"
    | "video"
    | "xmp" => true
    _ => false
  }
}

///|
/// Tags whose bodies HTML parses as RAWTEXT/RCDATA rather than ordinary child
/// markup. Security discovery checks the real opening tag and its attributes,
/// then skips the body to its browser-recognized end tag so `<script>`/`href=`
/// text inside CSS, title text, or a rejected container is never a decoy finding.
fn is_raw_text_container(tag : String) -> Bool {
  match tag {
    "iframe"
    | "noembed"
    | "noframes"
    | "noscript"
    | "script"
    | "style"
    | "textarea"
    | "title"
    | "xmp" => true
    _ => false
  }
}

///|
/// HTML attributes whose values can identify, fetch, navigate to, submit to, or
/// embed a resource in current/legacy Chromium parsing surfaces. `img src` is
/// the sole exception and is delegated to `check_imgs`, which already requires
/// one direct, present `assets/*.png` file without producing duplicate findings.
fn is_resource_attr(name : String) -> Bool {
  match name {
    "action"
    | "archive"
    | "attributionsrc"
    | "background"
    | "cite"
    | "classid"
    | "code"
    | "codebase"
    | "data"
    | "dynsrc"
    | "formaction"
    | "href"
    | "imagesrcset"
    | "longdesc"
    | "lowsrc"
    | "manifest"
    | "ping"
    | "poster"
    | "profile"
    | "src"
    | "srcdoc"
    | "srcset"
    | "usemap"
    | "xlink:href" => true
    _ => false
  }
}

///|
/// CSS identifier continuation relevant to boundary-checking URL-bearing
/// function names. A reverse solidus is included because it can escape an
/// identifier codepoint; the main scan rejects any such escape outside a
/// comment/string rather than trying to maintain a partial CSS decoder.
fn is_css_name_char(c : Char) -> Bool {
  let o = c.to_int()
  is_ascii_letter(c) ||
  is_ascii_digit(c) ||
  c == '-' ||
  c == '_' ||
  c == '\\' ||
  o >= 0x80
}

///|
/// Skip a CSS `/* ... */` comment beginning at `i`, or consume to EOF when it
/// never closes. CSS comments produce no tokens, so resource-shaped text inside
/// one is inert.
fn skip_css_comment(css : Array[Char], i : Int, end : Int) -> Int {
  let mut j = i + 2
  while j + 1 < end {
    if css[j] == '*' && css[j + 1] == '/' {
      return j + 2
    }
    j = j + 1
  }
  end
}

///|
/// Skip a quoted CSS string. Backslash escapes keep the next codepoint inside
/// the string; an unescaped newline ends a bad string token so scanning resumes
/// there. URL-shaped prose in `content:` remains inert, while later declarations
/// after a malformed newline still receive scrutiny.
fn skip_css_string(css : Array[Char], i : Int, end : Int) -> Int {
  let quote = css[i]
  let mut j = i + 1
  while j < end {
    if css[j] == quote {
      return j + 1
    }
    if css[j] == '\\' {
      j = if j + 1 < end { j + 2 } else { end }
    } else if css[j] == '\n' || css[j] == '\r' || css[j] == '\u{0c}' {
      return j
    } else {
      j = j + 1
    }
  }
  end
}

///|
/// Skip CSS whitespace and comments between an identifier and `(`. CSS's exact
/// tokenizer is stricter for some separated forms; accepting extra trivia here
/// is intentionally conservative for an offline contract.
fn skip_css_trivia(css : Array[Char], from : Int, end : Int) -> Int {
  let mut i = from
  let mut again = true
  while again {
    again = false
    while i < end && is_space(css[i]) {
      i = i + 1
    }
    if i + 1 < end && css[i] == '/' && css[i + 1] == '*' {
      i = skip_css_comment(css, i, end)
      again = true
    }
  }
  i
}

///|
/// Whether URL-bearing CSS function `name` begins at `i` as a whole ASCII-case-
/// insensitive identifier and is followed (allowing conservative trivia) by
/// `(`. A substring inside a longer identifier such as `noturl` never matches.
fn css_function_at(
  css : Array[Char],
  i : Int,
  end : Int,
  name : String,
) -> Bool {
  let needle = name.to_array()
  if !ci_matches_at(css, i, needle) || (i > 0 && is_css_name_char(css[i - 1])) {
    return false
  }
  let after = i + needle.length()
  if after < end && is_css_name_char(css[after]) {
    return false
  }
  let call = skip_css_trivia(css, after, end)
  call < end && css[call] == '('
}

///|
/// Whether authored CSS can identify an external/local resource. HTML character
/// references are decoded only for `style=` attributes; `<style>` is RAWTEXT and
/// therefore passes literal text. Real comments and strings are skipped. The
/// scan rejects `@import`, CSS URL functions (`url`/`src`), image functions that
/// accept bare URL strings, and any escape outside a string/comment (an escape
/// can disguise those identifiers). This deliberately small fail-closed scanner
/// implements the deck's no-resource CSS subset, not a general CSS parser.
fn css_has_resource(css : String, decode_html_entities : Bool) -> Bool {
  let source = if decode_html_entities {
    decode_attr_entities(css)
  } else {
    css
  }
  let cs = source.to_array()
  let n = cs.length()
  if decode_html_entities {
    // A residual/literal ampersand could be an unsupported named HTML reference
    // whose browser-decoded punctuation changes CSS string/comment context.
    // Inline styles need no ampersand grammar, so fail closed instead of carrying
    // a partial 2,000+-name entity table.
    for c in cs {
      if c == '&' {
        return true
      }
    }
  }
  let import_name = "import".to_array()
  let resource_functions = [
    "url", "src", "image", "image-set", "-webkit-image-set",
  ]
  let mut i = 0
  while i < n {
    if i + 1 < n && cs[i] == '/' && cs[i + 1] == '*' {
      i = skip_css_comment(cs, i, n)
    } else if cs[i] == '"' || cs[i] == '\'' {
      i = skip_css_string(cs, i, n)
    } else if cs[i] == '\\' {
      return true
    } else if cs[i] == '@' && ci_matches_at(cs, i + 1, import_name) {
      let after = i + 1 + import_name.length()
      if after >= n || !is_css_name_char(cs[after]) {
        return true
      }
      i = i + 1
    } else {
      for name in resource_functions {
        if css_function_at(cs, i, n, name) {
          return true
        }
      }
      i = i + 1
    }
  }
  false
}

///|
/// Enforce the browser-input boundary on the original HTML before `clean_doc`
/// blanks CSS/script bodies. One context-aware pass ignores HTML comments and
/// quoted tag literals; inspects every real tag + duplicate attribute; scans
/// real `<style>` RAWTEXT and `style=` CSS; and skips all RAWTEXT/RCDATA bodies.
/// Each category reports at most its first issue, keeping one malformed deck
/// concise while preserving four stable blocking codes.
fn check_static_contract(html : Array[Char], out : Report) -> Unit {
  let n = html.length()
  let comment_open = ['<', '!', '-', '-']
  let mut active : String? = None
  let mut event : String? = None
  let mut resource : String? = None
  let mut css_resource : String? = None
  let mut i = 0
  while i < n {
    if ci_matches_at(html, i, comment_open) {
      i = skip_html_comment(html, i, n)
    } else if is_open_tag_start(html, i, n) {
      let (tag, lo, hi, past_gt) = scan_open_tag(html, i)
      if active is None && is_unsafe_static_tag(tag) {
        active = Some("<\{tag}>")
      }
      let attrs = scan_attrs(html, lo, hi)
      for attr in attrs {
        if event is None && attr.name.has_prefix("on") {
          event = Some("\{tag}[\{attr.name}]")
        }
        if resource is None &&
          is_resource_attr(attr.name) &&
          !(tag == "img" && attr.name == "src") {
          resource = Some("\{tag}[\{attr.name}]")
        }
        if css_resource is None &&
          attr.name == "style" &&
          css_has_resource(attr.value, true) {
          css_resource = Some("\{tag}[style]")
        }
        if active is None && tag == "meta" && attr.name == "http-equiv" {
          let directive = trim_ws(decode_attr_entities(attr.value))
          active = Some("<meta http-equiv=\{directive}>")
        }
      }
      if active is None && tag == "meta" {
        let charset_only = attrs.length() == 1 &&
          attrs[0].name == "charset" &&
          ci_eq(trim_ws(decode_attr_entities(attrs[0].value)), "utf-8")
        if !charset_only {
          active = Some("<meta>")
        }
      }
      if tag == "plaintext" {
        i = n
      } else if is_raw_text_container(tag) {
        let close = find_raw_close_tag(html, tag, past_gt)
        let body_hi = if close >= 0 { close } else { n }
        if tag == "style" &&
          css_resource is None &&
          css_has_resource(range_to_string(html, past_gt, body_hi), false) {
          css_resource = Some("<style>")
        }
        i = if close >= 0 { skip_tag(html, close, n) } else { n }
      } else {
        i = past_gt
      }
    } else if is_markup_start(html, i, n) {
      if active is None &&
        i + 1 < n &&
        (html[i + 1] == '!' || html[i + 1] == '?') &&
        !is_html_doctype_at(html, i, n) {
        active = Some("<declaration-or-processing-instruction>")
      }
      i = skip_tag(html, i, n)
    } else {
      i = i + 1
    }
  }
  match active {
    Some(location) =>
      out.findings.push(
        must(
          "static.active_markup",
          "active, embedded, or navigating markup is not allowed: \{location}",
        ),
      )
    None => ()
  }
  match event {
    Some(location) =>
      out.findings.push(
        must(
          "static.event_handler",
          "event-handler attributes are not allowed: \{location}",
        ),
      )
    None => ()
  }
  match resource {
    Some(location) =>
      out.findings.push(
        must(
          "static.resource",
          "only <img src=\"assets/*.png\"> may carry a resource attribute: \{location}",
        ),
      )
    None => ()
  }
  match css_resource {
    Some(location) =>
      out.findings.push(
        must(
          "static.css_resource",
          "CSS imports, URL-bearing functions, token escapes, and ambiguous entities are not allowed: \{location}",
        ),
      )
    None => ()
  }
}

// -- Slide model -------------------------------------------------------------

///|
/// One tier of an `.entry`: its class (`jp`, `jpf`, or `en`) and the raw inner
/// HTML between the tier element's open and close tags.
priv struct Tier {
  cls : String
  html : String
}

///|
/// One `.entry` within a slide: its raw inner HTML (`raw`, scanned by the
/// ruby-outside-`.jpf` check) and its tier elements in document order (`tiers`,
/// read by the tier-order, JA-pairing, and furigana checks).
priv struct Entry {
  raw : String
  tiers : Array[Tier]
}

///|
/// A parsed `<section class="slide">`: the counts of its `.eyebrow` and `.pageno`
/// children, its list of `.entry` elements, and the text of its first
/// `.eyebrow`'s unique `.n` and its first `.pageno` (`None` when absent, or — for
/// `eyebrow_n` — when that eyebrow's `.n` is not unique). Counts drive the
/// "exactly one" checks, the entry list drives "at least one entry", and the
/// captured texts drive the slide-number and page-number format checks.
priv struct Slide {
  eyebrow_count : Int
  pageno_count : Int
  entries : Array[Entry]
  eyebrow_n : String?
  pageno_text : String?
}

///|
/// Parse every `<section class="slide">` into a `Slide`, tallying its outermost
/// `.eyebrow`/`.pageno`/`.entry` descendants and capturing the text of the first
/// `.eyebrow`'s `.n` (only when it holds exactly one) and the first `.pageno`.
/// Only `<section>` elements count as
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
    let mut eyebrow_n : String? = None
    let mut pageno_text : String? = None
    for part in find_by_class(doc, el.lo, el.hi, ["eyebrow", "pageno", "entry"]) {
      match part.token {
        "eyebrow" => {
          eyebrow_count = eyebrow_count + 1
          if eyebrow_count == 1 {
            let ns = find_by_class(doc, part.lo, part.hi, ["n"])
            if ns.length() == 1 {
              eyebrow_n = Some(inner_text(doc, ns[0].lo, ns[0].hi))
            }
          }
        }
        "pageno" => {
          pageno_count = pageno_count + 1
          if pageno_count == 1 {
            pageno_text = Some(inner_text(doc, part.lo, part.hi))
          }
        }
        "entry" => {
          let tiers : Array[Tier] = []
          for t in find_by_class(doc, part.lo, part.hi, ["jp", "jpf", "en"]) {
            tiers.push(Tier::{
              cls: t.token,
              html: range_to_string(doc, t.lo, t.hi),
            })
          }
          entries.push(Entry::{
            raw: range_to_string(doc, part.lo, part.hi),
            tiers,
          })
        }
        _ => ()
      }
    }
    slides.push(Slide::{
      eyebrow_count,
      pageno_count,
      entries,
      eyebrow_n,
      pageno_text,
    })
  }
  slides
}

// -- Checks ------------------------------------------------------------------

///|
/// Whether the cleaned document carries a real `<!doctype html>` declaration.
/// Markup is stepped atomically, so a doctype-shaped string inside an attribute
/// cannot satisfy the envelope check.
fn has_html_doctype(doc : Array[Char]) -> Bool {
  let n = doc.length()
  let mut i = 0
  while i < n {
    if i + 1 < n && doc[i] == '<' && doc[i + 1] == '!' {
      if is_html_doctype_at(doc, i, n) {
        return true
      }
      i = skip_tag(doc, i, n)
    } else if is_markup_start(doc, i, n) {
      i = skip_tag(doc, i, n)
    } else {
      i = i + 1
    }
  }
  false
}

///|
/// Document-envelope checks: the doctype, the `<html lang="ja">` root, a UTF-8
/// charset, a `<style>` closed before `<body>`, and a complete `<body>`/`</html>`
/// close. Findings are appended to `out` in this order.
fn check_frame(doc : Array[Char], out : Report) -> Unit {
  if !has_html_doctype(doc) {
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
/// Per-slide structure and text checks. Structure: exactly one `.eyebrow`
/// (`slide.eyebrow_count`), exactly one `.pageno` (`slide.pageno_count`), and at
/// least one `.entry` (`slide.no_entry`) — counted over each slide's OUTERMOST
/// layout slots. Text (gated on its owning count being 1, so a missing or
/// duplicated slot reports only the count code): the sole `.eyebrow`'s single
/// `.n` must read the two-digit 1-based slide number (`slide.eyebrow_n`), and
/// the sole `.pageno` must read `"<slug> · <n> / <total>"`
/// (`slide.pageno_format`). Each `.entry` is then checked by `check_entry`
/// (tier order, JA pairing, and furigana).
fn check_slides(slides : Array[Slide], slug : String, out : Report) -> Unit {
  let total = slides.length()
  for idx, s in slides {
    let num = idx + 1
    if s.eyebrow_count != 1 {
      out.findings.push(
        must("slide.eyebrow_count", "slide must have exactly one .eyebrow"),
      )
    } else {
      let want_n = two_digit(num)
      let n_ok = match s.eyebrow_n {
        Some(t) => t == want_n
        None => false
      }
      if !n_ok {
        out.findings.push(
          must("slide.eyebrow_n", "slide .eyebrow .n must be \{want_n}"),
        )
      }
    }
    if s.pageno_count != 1 {
      out.findings.push(
        must("slide.pageno_count", "slide must have exactly one .pageno"),
      )
    } else {
      let want_pageno = "\{slug} \u{b7} \{num} / \{total}"
      let pageno_ok = match s.pageno_text {
        Some(t) => t == want_pageno
        None => false
      }
      if !pageno_ok {
        out.findings.push(
          must("slide.pageno_format", "slide .pageno must be \{want_pageno}"),
        )
      }
    }
    if s.entries.length() == 0 {
      out.findings.push(
        must("slide.no_entry", "slide must have at least one .entry"),
      )
    }
    for e in s.entries {
      check_entry(e, out)
    }
  }
}

///|
/// Whether `c` is a CJK ideograph (kanji): the main block plus Extension A, the
/// compatibility ideographs, and Extension B and beyond. Kanji in a `.jpf` tier
/// must carry furigana; kana, punctuation, Latin, and digits do not.
fn is_kanji(c : Char) -> Bool {
  let o = c.to_int()
  (o >= 0x3400 && o <= 0x4DBF) ||
  (o >= 0x4E00 && o <= 0x9FFF) ||
  (o >= 0xF900 && o <= 0xFAFF) ||
  (o >= 0x20000 && o <= 0x2FA1F)
}

///|
/// Whether `c` is Japanese kana: hiragana (U+3040–309F) or katakana
/// (U+30A0–30FF, which includes the long-vowel mark ー). A furigana `<rt>`
/// reading must be all kana.
fn is_kana(c : Char) -> Bool {
  let o = c.to_int()
  (o >= 0x3040 && o <= 0x309F) || (o >= 0x30A0 && o <= 0x30FF)
}

///|
/// Whether every non-whitespace character of `s` is kana. An `<rt>` reading is
/// required to be all kana; interior whitespace is ignored and an empty reading
/// is vacuously all-kana.
fn all_kana(s : String) -> Bool {
  for c in s.to_array() {
    if !is_space(c) && !is_kana(c) {
      return false
    }
  }
  true
}

///|
/// Whether `s` holds at least one kana character. Paired with `all_kana`, it
/// rejects an empty or whitespace-only `<rt>`, which — though vacuously all-kana
/// — supplies no reading at all.
fn has_kana(s : String) -> Bool {
  for c in s.to_array() {
    if is_kana(c) {
      return true
    }
  }
  false
}

///|
/// Collapse each run of ASCII/HTML whitespace in `s` to a single space and trim
/// the ends, so two JA tiers compare equal up to insignificant layout whitespace.
fn collapse_ws(s : String) -> String {
  let cs = s.to_array()
  let sb = StringBuilder::new()
  let mut pending = false
  let mut started = false
  for i in 0..<cs.length() {
    if is_space(cs[i]) {
      pending = true
    } else {
      if pending && started {
        sb.write_char(' ')
      }
      sb.write_char(cs[i])
      started = true
      pending = false
    }
  }
  sb.to_string()
}

///|
/// Normalize a JA tier's inner HTML to comparable plain text: strip tags but keep
/// their text nodes, DROP each `<rt>` reading (so a furigana tier reduces to its
/// base text), decode character references, and collapse/trim whitespace. A
/// well-formed entry's `.jp` and `.jpf` normalize equal; a kanji dropped or
/// substituted between the tiers makes them differ.
fn normalize_ja(html : String) -> String {
  let cs = html.to_array()
  let n = cs.length()
  let sb = StringBuilder::new()
  let mut i = 0
  while i < n {
    if is_markup_start(cs, i, n) {
      let (name, is_close, past_gt) = classify_tag(cs, i, n)
      if name == "rt" && !is_close {
        let (_, close_past) = match_close(cs, "rt", past_gt, n)
        i = close_past
      } else {
        i = past_gt
      }
    } else {
      sb.write_char(cs[i])
      i = i + 1
    }
  }
  collapse_ws(decode_entities(sb.to_string()))
}

///|
/// Furigana checks within a `.jpf` tier's inner HTML, in one pass over the
/// characters while tracking whether the scan is inside a `<ruby>`, an `<rt>`, or
/// a `<code>` span:
///  - `ruby.rt_count`: every `<ruby>` is closed, non-nested, and holds exactly
///    one `<rt>`; every `<rt>` is closed and lives inside a `<ruby>`.
///  - `ruby.rt_not_kana`: every `<rt>` reading is non-empty and all kana.
///  - `ruby.kanji_uncovered`: every kanji outside a `<code>` span must sit in a
///    ruby base (inside `<ruby>` but outside its `<rt>`), so a bare kanji lacking
///    furigana flags. Coverage is per kanji CHARACTER, not per run, so a kanji
///    run split across adjacent ruby groups (要点 as 要 + 点) still passes; an
///    unclosed `<code>` grants no lasting exemption.
/// Each code is reported at most once.
fn check_jpf_ruby(html : String, out : Report) -> Unit {
  let cs = html.to_array()
  let n = cs.length()
  let mut in_ruby = false
  let mut code_depth = 0
  let mut in_rt = false
  let mut rt_in_ruby = 0
  let mut rt_start = 0
  let mut bad_rt_count = false
  let mut bad_rt_kana = false
  let mut uncovered = false
  let mut code_hid_kanji = false
  let mut i = 0
  while i < n {
    if is_markup_start(cs, i, n) {
      let (name, is_close, past_gt) = classify_tag(cs, i, n)
      match (name, is_close) {
        ("ruby", false) => {
          // A `<ruby>` opening inside another is malformed for this flat-ruby
          // convention; flag it rather than let the inner frame's `<rt>` stand
          // in for the outer's.
          if in_ruby {
            bad_rt_count = true
          }
          in_ruby = true
          rt_in_ruby = 0
        }
        ("ruby", true) => {
          if !in_ruby {
            bad_rt_count = true
          }
          // `in_rt` still set at the close means the `<rt>` never closed, so its
          // reading went unchecked: treat the ruby as malformed.
          if rt_in_ruby != 1 || in_rt {
            bad_rt_count = true
          }
          in_ruby = false
          in_rt = false
        }
        ("rt", false) => {
          // `<rt>` is meaningful only inside a `<ruby>`; a stray one is malformed.
          if !in_ruby || in_rt {
            bad_rt_count = true
          }
          in_rt = true
          rt_in_ruby = rt_in_ruby + 1
          rt_start = past_gt
        }
        ("rt", true) => {
          if !in_rt {
            bad_rt_count = true
          } else {
            // A reading must carry at least one kana and nothing but kana; an
            // empty or whitespace-only `<rt>` supplies no furigana.
            let reading = decode_entities(range_to_string(cs, rt_start, i))
            if !has_kana(reading) || !all_kana(reading) {
              bad_rt_kana = true
            }
          }
          in_rt = false
        }
        ("code", false) => code_depth = code_depth + 1
        ("code", true) => if code_depth > 0 { code_depth = code_depth - 1 }
        _ => ()
      }
      i = past_gt
    } else {
      let mut visible = cs[i]
      let mut next = i + 1
      if cs[i] == '&' {
        match parse_entity(cs, i, n) {
          Some((decoded, past)) => {
            visible = decoded
            next = past
          }
          None => ()
        }
      }
      if !in_rt && !in_ruby && is_kanji(visible) {
        // A kanji exempted only by an open `<code>` is tracked, not cleared: an
        // unclosed `<code>` must not grant a lasting coverage exemption.
        if code_depth > 0 {
          code_hid_kanji = true
        } else {
          uncovered = true
        }
      }
      i = next
    }
  }
  // End-of-scan structural guards: an unclosed `<ruby>` or `<rt>` never reached
  // its close-tag check, and an unclosed `<code>` that swallowed a kanji granted
  // a bogus exemption.
  if in_ruby || in_rt {
    bad_rt_count = true
  }
  if code_depth > 0 && code_hid_kanji {
    uncovered = true
  }
  if bad_rt_count {
    out.findings.push(
      must(
        "ruby.rt_count", "every <ruby> must be closed and hold exactly one <rt>",
      ),
    )
  }
  if bad_rt_kana {
    out.findings.push(must("ruby.rt_not_kana", "<rt> reading must be all kana"))
  }
  if uncovered {
    out.findings.push(
      must("ruby.kanji_uncovered", "kanji in .jpf must sit inside a ruby base"),
    )
  }
}

///|
/// Entry- and furigana-level checks for one `.entry`. Its tiers must be exactly
/// `.jp`, `.jpf`, `.en` in DOM order (`entry.tiers`); when they are not, only
/// that code is reported (one root cause, one finding, gating the rest — as the
/// slide count/text checks do). When well-formed: the JA tiers must pair, their
/// normalized base text equal (`entry.ja_pairing`); the `.jpf` ruby must be
/// well-formed (`check_jpf_ruby`); and no `<ruby>`/`<rt>` may live outside the
/// `.jpf` tier (`ruby.rt_outside_jpf`, counted across the whole entry against its
/// `.jpf`).
fn check_entry(e : Entry, out : Report) -> Unit {
  let tiers_ok = e.tiers.length() == 3 &&
    e.tiers[0].cls == "jp" &&
    e.tiers[1].cls == "jpf" &&
    e.tiers[2].cls == "en"
  if !tiers_ok {
    out.findings.push(
      must("entry.tiers", "entry must have .jp, .jpf, .en in order"),
    )
    return
  }
  let jp = e.tiers[0].html
  let jpf = e.tiers[1].html
  if normalize_ja(jp) != normalize_ja(jpf) {
    out.findings.push(
      must("entry.ja_pairing", ".jp and .jpf must carry the same JA text"),
    )
  }
  check_jpf_ruby(jpf, out)
  let raw = e.raw.to_array()
  let jpf_arr = jpf.to_array()
  let outside = find_all_open_tags(raw, "ruby").length() +
    find_all_open_tags(raw, "rt").length() -
    find_all_open_tags(jpf_arr, "ruby").length() -
    find_all_open_tags(jpf_arr, "rt").length()
  if outside > 0 {
    out.findings.push(
      must("ruby.rt_outside_jpf", "<ruby>/<rt> may appear only in .jpf"),
    )
  }
}

///|
/// Whether `src` is one literal direct bundled PNG URL. The filename follows the
/// CLI's representable-name policy and excludes URL/parser metacharacters that
/// could be decoded into a query, fragment, path separator, or HTML reference;
/// thus the filesystem name checked by `list_assets` is the browser path used.
fn is_direct_asset_png(src : String) -> Bool {
  let (parent, name) = split_path(src)
  if parent != "assets" ||
    name == "" ||
    !name.has_suffix(".png") ||
    !representable(name) {
    return false
  }
  for c in name.to_array() {
    if c == '%' || c == '&' || c == '?' || c == '#' || c == '\\' {
      return false
    }
  }
  true
}

///|
/// Image checks: every `<img>` must have one literal direct `assets/*.png` `src`
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
        if !is_direct_asset_png(src) {
          out.findings.push(
            must(
              "img.not_asset",
              "<img src=\"\{src}\"> must name one direct assets/*.png file",
            ),
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
/// Validate a deck's HTML against the static/offline browser boundary, envelope,
/// slide-structure, slide-text, entry/furigana, and image contract, returning a
/// structured `Report`. `slug` is the project name the per-slide `.pageno` check
/// expects. `assets` holds the bundle's `assets/<name>` files. The security pass
/// reads original parser contexts; ordinary structural scans share one cleaned
/// document with comments and raw-text content removed.
pub fn validate_deck(
  html : String,
  slug : String,
  assets : @set.Set[String],
) -> Report {
  let raw = html.to_array()
  let doc = clean_doc(raw)
  let out = Report::{ findings: [] }
  check_static_contract(raw, out)
  check_frame(doc, out)
  let slides = scan_deck(doc)
  if slides.length() == 0 {
    out.findings.push(must("frame.no_slides", "no <section class=\"slide\">"))
  }
  check_slides(slides, slug, out)
  check_imgs(doc, assets, out)
  out
}

///|
/// The bundle's safe asset set: `assets/<name>.png` for each direct regular,
/// non-symlink file in a real `dir/assets/` directory. Missing/invalid asset
/// roots and entries yield no usable paths here; whole-bundle validation emits
/// their blocking layout findings separately.
pub async fn list_assets(dir : String) -> @set.Set[String] {
  let names : Array[String] = []
  let assets_dir = "\{dir}/assets"
  let is_real_dir = try @fs.kind(assets_dir, follow_symlink=false) catch {
    _ => false
  } noraise {
    @fs.Directory => true
    _ => false
  }
  if is_real_dir {
    let entries = try @fs.readdir(assets_dir) catch {
      _ => []
    } noraise {
      entries => entries
    }
    for name in entries {
      if name.has_suffix(".png") {
        let regular = try
          @fs.kind("\{assets_dir}/\{name}", follow_symlink=false)
        catch {
          _ => false
        } noraise {
          @fs.Regular => true
          _ => false
        }
        if regular {
          names.push("assets/\{name}")
        }
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
