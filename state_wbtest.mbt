// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// `is_repo_marker` accepts only a `moon.mod` whose `name` field declares this
/// module at the start of a line, and rejects a foreign module, an empty file, a
/// mere dependency reference, the literal embedded mid-line in another field, and
/// a longer module name — the distinctions that keep `ascend` from anchoring on
/// an unrelated MoonBit project. Whitebox: the marker check is private.
test "is_repo_marker matches only the slide-gen module declaration" {
  assert_true(is_repo_marker("name = \"eturkes/slide-gen\"\n"))
  // Position-independent: other fields may precede the name declaration.
  assert_true(
    is_repo_marker(
      "license = \"Apache-2.0\"\nname = \"eturkes/slide-gen\"\nversion = \"0.1.0\"\n",
    ),
  )
  assert_false(is_repo_marker(""))
  assert_false(is_repo_marker("name = \"other/project\"\n"))
  // A dependency reference carries no `name = ` prefix, so it is not the marker.
  assert_false(is_repo_marker("import {\n  \"eturkes/slide-gen@0.1.0\",\n}\n"))
  // A top-level declaration begins its line: the same literal embedded mid-line
  // (e.g. inside another field's quoted value) is NOT a declaration — a bare
  // substring test would wrongly accept it.
  assert_false(is_repo_marker("prefixed name = \"eturkes/slide-gen\"\n"))
  // The trailing quote rejects a longer module name.
  assert_false(is_repo_marker("name = \"eturkes/slide-gen-extra\"\n"))
}
