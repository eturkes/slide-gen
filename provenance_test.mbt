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
/// `gap`-status provenance row + a `no gaps` disclosure) and fires exactly the
/// right code for each seeded provenance or gaps defect: a missing, unparseable,
/// or non-array `provenance.json`, a schema-invalid row, and a missing or
/// undisclosed `gaps.md`. The baseline row is `gap` status so its source check is
/// skipped, keeping this a schema/shell test; source and quote checks are proven
/// separately below with real cited files.
async test "validate_bundle_dir over seeded bundles" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-prov")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let deck = envelope()
    let good = "[{\"id\":\"c1\",\"slide\":1,\"claim\":\"x\",\"status\":\"gap\"}]"
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

///|
/// A one-row provenance array citing `src` with `quote` at the given `status`,
/// for the source-check bundle tests.
fn prov_one(status : String, src : String, quote : String) -> String {
  "[{\"id\":\"c1\",\"slide\":1,\"claim\":\"x\",\"status\":\"\{status}\",\"src\":\"\{src}\",\"quote\":\"\{quote}\"}]"
}

///|
/// `validate_bundle_dir`'s per-row source check: a verified row whose quote
/// literally occurs in the cited line slice passes; a quote absent from that
/// slice — even one present elsewhere in the file — fails `prov.quote`; a
/// citation resolving inside the bundle, to a missing file, or past the file's
/// line range fails its specific code; and a `gap` row skips the check entirely.
async test "validate_bundle_dir source and quote checks" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-prov-src")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let deck = envelope()
    @fs.write_file(
      "\{root}/src.md",
      "alpha\nbeta gamma\ndelta\n",
      create_mode=CreateOrTruncate,
    )
    // Clean: quote "beta" occurs in the cited line 2.
    let clean = make_bundle(
      root,
      "clean",
      Some(deck),
      Some(prov_one("verified", "src.md:2-2", "beta")),
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(clean, "project", root).codes(), content=[])
    // Quote absent from the file entirely.
    let badquote = make_bundle(
      root,
      "badquote",
      Some(deck),
      Some(prov_one("verified", "src.md:2-2", "zzz")),
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(badquote, "project", root).codes(), content=[
      "prov.quote",
    ])
    // Quote in the file but off the cited line (line 3, not the cited line 2).
    let offline = make_bundle(
      root,
      "offline",
      Some(deck),
      Some(prov_one("verified", "src.md:2-2", "delta")),
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(offline, "project", root).codes(), content=[
      "prov.quote",
    ])
    // Self-citation: a relative path resolving inside the bundle.
    let selfcite = make_bundle(
      root,
      "selfcite",
      Some(deck),
      Some(prov_one("verified", "selfcite/deck.html:1-1", "x")),
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(selfcite, "project", root).codes(), content=[
      "prov.self_citation",
    ])
    // Missing source file.
    let missing = make_bundle(
      root,
      "missing",
      Some(deck),
      Some(prov_one("verified", "nope.md:1-1", "x")),
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(missing, "project", root).codes(), content=[
      "prov.src_missing",
    ])
    // Line range past the end of the file.
    let oor = make_bundle(
      root,
      "oor",
      Some(deck),
      Some(prov_one("verified", "src.md:50-60", "x")),
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(oor, "project", root).codes(), content=[
      "prov.src_range",
    ])
    // A gap row carries no verifiable source, so the check is skipped.
    let gap = make_bundle(
      root,
      "gap",
      Some(deck),
      Some("[{\"id\":\"c1\",\"slide\":1,\"claim\":\"x\",\"status\":\"gap\"}]"),
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(gap, "project", root).codes(), content=[])
  }
}
