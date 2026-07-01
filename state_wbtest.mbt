// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// `is_repo_marker` accepts only a `moon.mod` that declares this module name and
/// rejects a foreign module, an empty file, and a mere dependency reference —
/// the distinction that keeps `ascend` from anchoring on an unrelated MoonBit
/// project. Whitebox: the marker check is private to the anchor logic.
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
}
