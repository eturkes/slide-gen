// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// `get_attr` reads double-, single-, and unquoted values plus boolean
/// attributes, matches the name case-insensitively, and returns `None` when the
/// attribute is absent. Whitebox: the scan primitives are private.
test "get_attr value forms" {
  let region = " Lang=\"ja\" data-x='7' n=3 flag ".to_array()
  let hi = region.length()
  inspect(get_attr(region, 0, hi, "lang").unwrap_or("<absent>"), content="ja")
  inspect(get_attr(region, 0, hi, "data-x").unwrap_or("<absent>"), content="7")
  inspect(get_attr(region, 0, hi, "n").unwrap_or("<absent>"), content="3")
  inspect(get_attr(region, 0, hi, "flag").unwrap_or("<absent>"), content="")
  inspect(
    get_attr(region, 0, hi, "missing").unwrap_or("<absent>"),
    content="<absent>",
  )
  // A duplicate attribute resolves to its first occurrence (HTML parse behavior).
  let dup = " class=\"a\" class=\"b\" ".to_array()
  inspect(
    get_attr(dup, 0, dup.length(), "class").unwrap_or("<absent>"),
    content="a",
  )
}

///|
/// `has_class` matches a whole whitespace-delimited class token, never a
/// substring of one — so `col-fig tall` has `tall` and `col-fig` but not `col`.
test "has_class whole-token match" {
  let region = " class=\"col-fig tall\" ".to_array()
  let hi = region.length()
  assert_true(has_class(region, 0, hi, "tall"))
  assert_true(has_class(region, 0, hi, "col-fig"))
  assert_false(has_class(region, 0, hi, "col"))
  assert_false(has_class(region, 0, hi, "fig"))
}

///|
/// `strip_comments` drops a well-formed comment; an unterminated comment swallows
/// the rest of the document.
test "strip_comments removes comments and swallows unterminated" {
  let a = strip_comments("a<!--b-->c".to_array())
  inspect(range_to_string(a, 0, a.length()), content="ac")
  let b = strip_comments("keep<!--x".to_array())
  inspect(range_to_string(b, 0, b.length()), content="keep")
  let c = strip_comments("<!--only-->".to_array())
  inspect(range_to_string(c, 0, c.length()), content="")
}

///|
/// `strip_raw_text` blanks `<style>`/`<script>` content but keeps their tags; a
/// close tag matches only at a name boundary (`</stylex>` does not close); and an
/// unterminated raw-text element is blanked to end of document.
test "strip_raw_text blanks raw-text content" {
  let a = strip_raw_text("<style><img src=x></style>keep".to_array())
  inspect(range_to_string(a, 0, a.length()), content="<style></style>keep")
  let b = strip_raw_text("x<script>a<b</script>y".to_array())
  inspect(range_to_string(b, 0, b.length()), content="x<script></script>y")
  // </stylex> is not a name-boundary close, so blanking continues to the real one.
  let d = strip_raw_text("<style>x</stylex>y</style>z".to_array())
  inspect(range_to_string(d, 0, d.length()), content="<style></style>z")
  // Unterminated raw-text runs to end of document, so its remainder is blanked.
  let c = strip_raw_text("<style>body{}".to_array())
  inspect(range_to_string(c, 0, c.length()), content="<style>")
}

///|
/// `index_ci` finds a needle case-insensitively and returns `-1` when absent.
test "index_ci case-insensitive and absent" {
  assert_eq(index_ci("Hello".to_array(), "ell".to_array()), 1)
  assert_eq(index_ci("HELLO".to_array(), "ell".to_array()), 1)
  assert_eq(index_ci("abc".to_array(), "xyz".to_array()), -1)
}
