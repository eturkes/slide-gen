// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Write a bundle under `base/name`, creating `deck.html`, `provenance.json`, and
/// `gaps.md` only when its argument is `Some`, so a test can omit a file to seed
/// a missing-file defect. Returns the bundle path.
async fn make_bundle(
  base : String,
  name : String,
  deck : String?,
  prov : String?,
  gaps : String?,
) -> String {
  let bundle = "\{base}/\{name}"
  @fs.mkdir(bundle)
  match deck {
    Some(d) =>
      @fs.write_file("\{bundle}/deck.html", d, create_mode=CreateOrTruncate)
    None => ()
  }
  match prov {
    Some(p) =>
      @fs.write_file(
        "\{bundle}/provenance.json",
        p,
        create_mode=CreateOrTruncate,
      )
    None => ()
  }
  match gaps {
    Some(g) =>
      @fs.write_file("\{bundle}/gaps.md", g, create_mode=CreateOrTruncate)
    None => ()
  }
  bundle
}

///|
/// `validate_bundle_dir` passes a clean bundle (valid deck + a schema-valid
/// provenance array + a `no gaps` disclosure) and fires exactly the right code
/// for each seeded provenance or gaps defect: a missing, unparseable, or
/// non-array `provenance.json`, a schema-invalid row, and a missing or
/// undisclosed `gaps.md`.
async test "validate_bundle_dir over seeded bundles" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-prov")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let deck = envelope()
    let good = "[{\"id\":\"c1\",\"slide\":1,\"claim\":\"x\",\"status\":\"verified\",\"src\":\"a.md:1-1\",\"quote\":\"q\"}]"
    let bad_row = "[{\"id\":\"c1\",\"slide\":1,\"claim\":\"x\",\"status\":\"maybe\"}]"
    // Clean bundle.
    let clean = make_bundle(
      root,
      "clean",
      Some(deck),
      Some(good),
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(clean, "project", root).codes(), content=[])
    // Missing provenance.json.
    let noprov = make_bundle(
      root,
      "noprov",
      Some(deck),
      None,
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(noprov, "project", root).codes(), content=[
      "prov.missing",
    ])
    // A non-array JSON top level.
    let objprov = make_bundle(
      root,
      "objprov",
      Some(deck),
      Some("{}"),
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(objprov, "project", root).codes(), content=[
      "prov.parse",
    ])
    // Malformed JSON.
    let badjson = make_bundle(
      root,
      "badjson",
      Some(deck),
      Some("{"),
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(badjson, "project", root).codes(), content=[
      "prov.parse",
    ])
    // A schema-invalid row (unknown status).
    let badrow = make_bundle(
      root,
      "badrow",
      Some(deck),
      Some(bad_row),
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(badrow, "project", root).codes(), content=[
      "prov.schema",
    ])
    // Missing gaps.md.
    let nogaps = make_bundle(root, "nogaps", Some(deck), Some(good), None)
    json_inspect(validate_bundle_dir(nogaps, "project", root).codes(), content=[
      "gaps.missing",
    ])
    // Prose-only gaps.md discloses nothing.
    let prosegaps = make_bundle(
      root,
      "prosegaps",
      Some(deck),
      Some(good),
      Some("all covered\n"),
    )
    json_inspect(validate_bundle_dir(prosegaps, "project", root).codes(), content=[
      "gaps.empty",
    ])
  }
}
