// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Assemble a deck's HTML from envelope parts. Every part defaults to a valid
/// value, so overriding one seeds a single defect in isolation.
fn envelope(
  doctype? : String = "<!doctype html>",
  html_open? : String = "<html lang=\"ja\">",
  charset? : String = "<meta charset=\"utf-8\">",
  style? : String = "<style>body{}</style>",
  body_open? : String = "<body>",
  sections? : String = "<section class=\"slide\"></section>",
  body_close? : String = "</body>",
  html_close? : String = "</html>",
) -> String {
  "\{doctype}\n\{html_open}\n<head>\n\{charset}\n\{style}\n</head>\n\{body_open}\n\{sections}\n\{body_close}\n\{html_close}\n"
}

///|
/// The empty asset set.
fn no_assets() -> @set.Set[String] {
  let empty : Array[String] = []
  @set.Set(empty[:])
}

///|
/// A well-formed envelope with one empty slide passes clean; a decoy
/// `<section class="slide">` and `<img>` living inside an HTML comment are
/// stripped up front and ignored.
test "good envelope passes; commented decoys ignored" {
  json_inspect(validate_deck(envelope(), "project", no_assets()).codes(), content=[])
  let with_decoy = envelope(
    sections="<!-- <section class=\"slide\"></section> <img src=\"assets/z.png\"> --><section class=\"slide\"></section>",
  )
  json_inspect(validate_deck(with_decoy, "project", no_assets()).codes(), content=[])
  // An <img> written inside a CSS comment in <style> is raw text, not markup.
  let css_img = envelope(
    style="<style>/* swap for <img src=…> */ .col-fig img{width:100%}</style>",
  )
  json_inspect(validate_deck(css_img, "project", no_assets()).codes(), content=[])
}

///|
/// The public `Report` surface: a clean deck is `ok` and renders `ok`; a
/// defective deck is not `ok` and renders a severity-labeled line.
test "report ok and render" {
  let clean = validate_deck(envelope(), "project", no_assets())
  assert_true(clean.ok())
  inspect(clean.render(), content="ok")
  let bad = validate_deck(envelope(doctype=""), "project", no_assets())
  assert_false(bad.ok())
  inspect(bad.render(), content="[MUST] frame.doctype: missing <!doctype html>")
}

///|
/// Each seeded envelope defect surfaces exactly its code and nothing else.
test "envelope defects each map to their code" {
  json_inspect(
    validate_deck(envelope(doctype=""), "project", no_assets()).codes(),
    content=["frame.doctype"],
  )
  json_inspect(
    validate_deck(
      envelope(html_open="<html lang=\"en\">"),
      "project",
      no_assets(),
    ).codes(),
    content=["frame.html_lang"],
  )
  json_inspect(
    validate_deck(envelope(charset=""), "project", no_assets()).codes(),
    content=["frame.charset"],
  )
  json_inspect(
    validate_deck(envelope(style="<style>body{}"), "project", no_assets()).codes(),
    content=["frame.style"],
  )
  json_inspect(
    validate_deck(envelope(html_close=""), "project", no_assets()).codes(),
    content=["frame.body"],
  )
  json_inspect(
    validate_deck(envelope(sections=""), "project", no_assets()).codes(),
    content=["frame.no_slides"],
  )
}

///|
/// Image checks: a src outside `assets/` flags `img.not_asset`; a src under
/// `assets/` with no matching file flags `img.missing`; the same src with its
/// asset present passes clean.
test "image checks map to their codes" {
  let not_asset = envelope(
    sections="<section class=\"slide\"><img src=\"foo.png\"></section>",
  )
  json_inspect(validate_deck(not_asset, "project", no_assets()).codes(), content=[
    "img.not_asset",
  ])
  let missing = envelope(
    sections="<section class=\"slide\"><img src=\"assets/x.png\"></section>",
  )
  json_inspect(validate_deck(missing, "project", no_assets()).codes(), content=[
    "img.missing",
  ])
  let present : @set.Set[String] = @set.Set(["assets/x.png"][:])
  json_inspect(validate_deck(missing, "project", present).codes(), content=[])
}

///|
/// `validate_deck_dir` reads a bundle from disk: a deck referencing an asset that
/// exists passes; a bundle with no `assets/` directory and no images also passes,
/// proving a missing assets dir is not an error.
async test "validate_deck_dir over a disk bundle" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="slide-gen-validate")
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    @fs.mkdir("\{dir}/assets")
    @fs.write_file("\{dir}/assets/x.png", "", create_mode=CreateOrTruncate)
    let deck = envelope(
      sections="<section class=\"slide\"><img src=\"assets/x.png\"></section>",
    )
    @fs.write_file("\{dir}/deck.html", deck, create_mode=CreateOrTruncate)
    json_inspect(validate_deck_dir(dir, "project").codes(), content=[])
    let bare = @fs.tmpdir(prefix="slide-gen-validate-bare")
    group.add_defer(() => @fs.rmdir(bare, recursive=true))
    @fs.write_file(
      "\{bare}/deck.html",
      envelope(),
      create_mode=CreateOrTruncate,
    )
    json_inspect(validate_deck_dir(bare, "project").codes(), content=[])
  }
}

///|
/// The shipped `templates/deck.html` passes the envelope and image checks — the
/// real hand-authored template is the positive contract. Located via the repo
/// root so it runs under `moon test` regardless of cwd; skipped only if the root
/// cannot be found.
async test "shipped template envelope is clean" {
  guard find_repo_root() is Some(root) else { return }
  let html = @fs.read_file("\{root}/templates/deck.html").text()
  let assets = list_assets("\{root}/templates")
  json_inspect(validate_deck(html, "project", assets).codes(), content=[])
}
