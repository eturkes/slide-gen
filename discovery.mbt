// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Enumerate candidate sibling project directories directly under `parent`.
///
/// Candidate = a direct child resolving to a directory: a real directory, or a
/// symlink whose target is a directory. Skipped: dotfile entries, plain files,
/// symlinks to non-directories, broken symlinks, and the entry named `exclude`
/// (the repo's own directory). No recursion — only the top level is scanned.
/// Names are returned sorted ascending.
///
/// `@fs.kind` follows symlinks by default and raises on an unresolvable target,
/// so one follow-stat both accepts symlinks-to-directories and rejects broken
/// links; the lstat-then-stat split sketched in planning proved redundant once
/// `kind` semantics were verified against the upstream tests.
pub async fn discover(parent : String, exclude~ : String) -> Array[String] {
  let candidates : Array[String] = []
  // include_hidden=true surfaces dotfiles so the dot-skip below is the single,
  // default-independent source of truth for hidden-entry exclusion.
  for name in @fs.readdir(parent, include_hidden=true) {
    guard name != exclude && !name.has_prefix(".") else { continue }
    let full = "\{parent}/\{name}"
    let is_dir = try @fs.kind(full) catch {
      _ => false
    } noraise {
      @fs.Directory => true
      _ => false
    }
    if is_dir {
      candidates.push(name)
    }
  }
  // `String`'s default `Compare` is shortlex (length first), so `Array::sort`
  // would order by length, not dictionary order. `list` is human-facing →
  // sort lexicographically by codepoint instead.
  candidates.sort_by(lex_compare)
  candidates
}

///|
/// Compare two strings lexicographically by Unicode codepoint (dictionary
/// order), unlike `String`'s built-in shortlex `Compare`. Shorter string first
/// on a shared prefix.
fn lex_compare(a : String, b : String) -> Int {
  let ca = a.to_array()
  let cb = b.to_array()
  let n = if ca.length() < cb.length() { ca.length() } else { cb.length() }
  for i in 0..<n {
    if ca[i] < cb[i] {
      return -1
    } else if ca[i] > cb[i] {
      return 1
    }
  }
  ca.length() - cb.length()
}

///|
/// Split an absolute path into (parent directory, final component) at the last
/// `/`. A single trailing slash is ignored; a root-level path ("/foo") yields
/// parent "/"; a path with no slash yields parent ".".
pub fn split_path(path : String) -> (String, String) {
  let p = if path.length() > 1 && path.has_suffix("/") {
    path[:path.length() - 1].to_owned()
  } else {
    path
  }
  match p.rev_find("/") {
    Some(i) => {
      let parent = p[:i].to_owned()
      (if parent == "" { "/" } else { parent }, p[i + 1:].to_owned())
    }
    None => (".", p)
  }
}
