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
/// citation resolving inside the bundle, to a missing file, to a directory
/// rather than a regular file, or past the file's line range fails its specific
/// code; and a `gap` row skips the check entirely.
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
    @fs.mkdir("\{root}/srcdir")
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
    // A directory exists but is not a regular file that can be quoted.
    let dircite = make_bundle(
      root,
      "dircite",
      Some(deck),
      Some(prov_one("verified", "srcdir:1-1", "x")),
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(dircite, "project", root).codes(), content=[
      "prov.src_missing",
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

///|
/// A provenance array of schema-valid `gap`-status rows, one per id. Their source
/// checks are skipped, so the ids populate the cross-reference set without any
/// real cited files.
fn prov_gap_rows(ids : Array[String]) -> String {
  let sb = StringBuilder::new()
  sb.write_char('[')
  for i in 0..<ids.length() {
    if i > 0 {
      sb.write_char(',')
    }
    let id = ids[i]
    sb.write_string(
      "{\"id\":\"\{id}\",\"slide\":1,\"claim\":\"x\",\"status\":\"gap\"}",
    )
  }
  sb.write_char(']')
  sb.to_string()
}

///|
/// `validate_bundle_dir`'s deck-to-provenance cross-reference: a deck
/// `data-claim` naming no schema-valid row fires `prov.dangling_claim`, while a
/// `data-claim` naming a row is silent. The rows are `gap` status so their source
/// checks are skipped, isolating the cross-reference from the source checks.
async test "validate_bundle_dir deck cross-reference" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-prov-xref")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    // A data-claim naming no provenance row is dangling.
    let dangling = make_bundle(
      root,
      "dangling",
      Some(
        deck_with_entry(
          entry_of("a", "a", "<span data-claim=\"ghost\">x</span>"),
        ),
      ),
      Some(prov_gap_rows(["c1"])),
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(dangling, "project", root).codes(), content=[
      "prov.dangling_claim",
    ])
    // A data-claim naming a schema-valid row is clean.
    let tagged = make_bundle(
      root,
      "tagged",
      Some(
        deck_with_entry(entry_of("a", "a", "<span data-claim=\"c1\">x</span>")),
      ),
      Some(prov_gap_rows(["c1"])),
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(tagged, "project", root).codes(), content=[])
    // A data-claim hidden inside an HTML comment is stripped before the
    // cross-ref runs, so it does not dangle. The inner `<a>` is load-bearing:
    // without real comment-stripping the tag walk's crude `<!` skip stops at the
    // `<a>`'s `>` and would then read `ghost` as a live claim, so a clean result
    // proves `validate_bundle_dir` cleans the deck first.
    let commented = make_bundle(
      root,
      "commented",
      Some(
        deck_with_entry(
          entry_of(
            "a", "a", "<span data-claim=\"c1\">x</span><!-- <a> <span data-claim=\"ghost\"> -->",
          ),
        ),
      ),
      Some(prov_gap_rows(["c1"])),
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(commented, "project", root).codes(), content=[])
    // A data-claim naming a schema-invalid row: the row is excluded from the id
    // set, so the claim both fails schema and dangles.
    let invalid = make_bundle(
      root,
      "invalid",
      Some(
        deck_with_entry(entry_of("a", "a", "<span data-claim=\"c1\">x</span>")),
      ),
      Some("[{\"id\":\"c1\",\"slide\":1,\"claim\":\"x\",\"status\":\"maybe\"}]"),
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(invalid, "project", root).codes(), content=[
      "prov.schema", "prov.dangling_claim",
    ])
    // An unparseable provenance.json yields an empty id set, so every deck
    // data-claim cascades to dangling on top of the parse finding.
    let parsefail = make_bundle(
      root,
      "parsefail",
      Some(
        deck_with_entry(entry_of("a", "a", "<span data-claim=\"c1\">x</span>")),
      ),
      Some("{"),
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(parsefail, "project", root).codes(), content=[
      "prov.parse", "prov.dangling_claim",
    ])
  }
}
