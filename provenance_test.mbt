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
    json_inspect(validate_bundle_dir(clean, "project", root, root).codes(), content=[])
    // Missing provenance.json.
    let noprov = make_bundle(
      root,
      "noprov",
      Some(deck),
      None,
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(noprov, "project", root, root).codes(), content=[
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
    json_inspect(validate_bundle_dir(objprov, "project", root, root).codes(), content=[
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
    json_inspect(validate_bundle_dir(badjson, "project", root, root).codes(), content=[
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
    json_inspect(validate_bundle_dir(badrow, "project", root, root).codes(), content=[
      "prov.schema",
    ])
    // Missing gaps.md.
    let nogaps = make_bundle(root, "nogaps", Some(deck), Some(good), None)
    json_inspect(validate_bundle_dir(nogaps, "project", root, root).codes(), content=[
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
    json_inspect(
      validate_bundle_dir(prosegaps, "project", root, root).codes(),
      content=["gaps.empty"],
    )
  }
}

///|
/// deck.html is the bundle's first hard gate: absent, empty, non-regular, and
/// symlink entries all return the single `deck.missing` report instead of raising
/// while reading or following the path.
async test "validate_bundle_dir guards unusable deck entries" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-prov-deck")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let missing = make_bundle(
      root,
      "missing",
      None,
      Some("[]"),
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(missing, "project", root, root).codes(), content=[
      "deck.missing",
    ])
    let empty = make_bundle(
      root,
      "empty",
      Some(""),
      Some("[]"),
      Some("no gaps\n"),
    )
    json_inspect(validate_bundle_dir(empty, "project", root, root).codes(), content=[
      "deck.missing",
    ])
    let directory = make_bundle(
      root,
      "directory",
      None,
      Some("[]"),
      Some("no gaps\n"),
    )
    @fs.mkdir("\{directory}/deck.html")
    json_inspect(
      validate_bundle_dir(directory, "project", root, root).codes(),
      content=["deck.missing"],
    )
    let target = "\{root}/target.html"
    @fs.write_file(target, envelope(), create_mode=CreateOrTruncate)
    let symlink = make_bundle(
      root,
      "symlink",
      None,
      Some("[]"),
      Some("no gaps\n"),
    )
    @fs.symlink("\{symlink}/deck.html", target~)
    json_inspect(validate_bundle_dir(symlink, "project", root, root).codes(), content=[
      "deck.missing",
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
/// citation resolving anywhere under the generated deck home, escaping the
/// source base, naming a missing file or directory, or extending past the file's
/// line range fails its specific code; and a `gap` row skips the check entirely.
async test "validate_bundle_dir source and quote checks" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-prov-src")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let src_base = "\{root}/sources"
    let deck_home = "\{src_base}/decks"
    @fs.mkdir(src_base)
    @fs.mkdir(deck_home)
    let deck = envelope()
    @fs.write_file(
      "\{src_base}/src.md",
      "alpha\nbeta gamma\ndelta\n",
      create_mode=CreateOrTruncate,
    )
    @fs.mkdir("\{src_base}/srcdir")
    @fs.write_file(
      "\{root}/outside.md",
      "outside\n",
      create_mode=CreateOrTruncate,
    )
    // Clean: quote "beta" occurs in the cited line 2.
    let clean = make_bundle(
      deck_home,
      "clean",
      Some(deck),
      Some(prov_one("verified", "src.md:2-2", "beta")),
      Some("no gaps\n"),
    )
    json_inspect(
      validate_bundle_dir(clean, "project", src_base, deck_home).codes(),
      content=[],
    )
    // Quote absent from the file entirely.
    let badquote = make_bundle(
      deck_home,
      "badquote",
      Some(deck),
      Some(prov_one("verified", "src.md:2-2", "zzz")),
      Some("no gaps\n"),
    )
    json_inspect(
      validate_bundle_dir(badquote, "project", src_base, deck_home).codes(),
      content=["prov.quote"],
    )
    // Quote in the file but off the cited line (line 3, not the cited line 2).
    let offline = make_bundle(
      deck_home,
      "offline",
      Some(deck),
      Some(prov_one("verified", "src.md:2-2", "delta")),
      Some("no gaps\n"),
    )
    json_inspect(
      validate_bundle_dir(offline, "project", src_base, deck_home).codes(),
      content=["prov.quote"],
    )
    // Self-citation: a relative path resolving inside this bundle.
    let selfcite = make_bundle(
      deck_home,
      "selfcite",
      Some(deck),
      Some(prov_one("verified", "decks/selfcite/deck.html:1-1", "x")),
      Some("no gaps\n"),
    )
    json_inspect(
      validate_bundle_dir(selfcite, "project", src_base, deck_home).codes(),
      content=["prov.self_citation"],
    )
    // Normalization closes a `..` re-entry spelling of this bundle.
    let reentry = make_bundle(
      deck_home,
      "reentry",
      Some(deck),
      Some(prov_one("verified", "decks/reentry/../reentry/deck.html:1-1", "x")),
      Some("no gaps\n"),
    )
    json_inspect(
      validate_bundle_dir(reentry, "project", src_base, deck_home).codes(),
      content=["prov.self_citation"],
    )
    // The boundary covers sibling published decks, not only this bundle.
    let sibling = make_bundle(
      deck_home,
      "sibling",
      Some(deck),
      Some(prov_one("verified", "decks/clean/deck.html:1-1", "x")),
      Some("no gaps\n"),
    )
    json_inspect(
      validate_bundle_dir(sibling, "project", src_base, deck_home).codes(),
      content=["prov.self_citation"],
    )
    // An absolute path outside src_base is rejected even when the file exists.
    let absolute_escape = make_bundle(
      deck_home,
      "absolute-escape",
      Some(deck),
      Some(prov_one("verified", "\{root}/outside.md:1-1", "outside")),
      Some("no gaps\n"),
    )
    json_inspect(
      validate_bundle_dir(absolute_escape, "project", src_base, deck_home).codes(),
      content=["prov.src_outside"],
    )
    // A relative `..` escape is rejected after lexical normalization.
    let relative_escape = make_bundle(
      deck_home,
      "relative-escape",
      Some(deck),
      Some(prov_one("verified", "../outside.md:1-1", "outside")),
      Some("no gaps\n"),
    )
    json_inspect(
      validate_bundle_dir(relative_escape, "project", src_base, deck_home).codes(),
      content=["prov.src_outside"],
    )
    // Missing source file.
    let missing = make_bundle(
      deck_home,
      "missing",
      Some(deck),
      Some(prov_one("verified", "nope.md:1-1", "x")),
      Some("no gaps\n"),
    )
    json_inspect(
      validate_bundle_dir(missing, "project", src_base, deck_home).codes(),
      content=["prov.src_missing"],
    )
    // Line range past the end of the file.
    let oor = make_bundle(
      deck_home,
      "oor",
      Some(deck),
      Some(prov_one("verified", "src.md:50-60", "x")),
      Some("no gaps\n"),
    )
    json_inspect(
      validate_bundle_dir(oor, "project", src_base, deck_home).codes(),
      content=["prov.src_range"],
    )
    // A directory exists but is not a regular file that can be quoted.
    let dircite = make_bundle(
      deck_home,
      "dircite",
      Some(deck),
      Some(prov_one("verified", "srcdir:1-1", "x")),
      Some("no gaps\n"),
    )
    json_inspect(
      validate_bundle_dir(dircite, "project", src_base, deck_home).codes(),
      content=["prov.src_missing"],
    )
    // A gap row carries no verifiable source, so the check is skipped.
    let gap = make_bundle(
      deck_home,
      "gap",
      Some(deck),
      Some("[{\"id\":\"c1\",\"slide\":1,\"claim\":\"x\",\"status\":\"gap\"}]"),
      Some("no gaps\n"),
    )
    json_inspect(
      validate_bundle_dir(gap, "project", src_base, deck_home).codes(),
      content=[],
    )
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
    json_inspect(validate_bundle_dir(dangling, "project", root, root).codes(), content=[
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
    json_inspect(validate_bundle_dir(tagged, "project", root, root).codes(), content=[])
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
    json_inspect(
      validate_bundle_dir(commented, "project", root, root).codes(),
      content=[],
    )
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
    json_inspect(validate_bundle_dir(invalid, "project", root, root).codes(), content=[
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
    json_inspect(
      validate_bundle_dir(parsefail, "project", root, root).codes(),
      content=["prov.parse", "prov.dangling_claim"],
    )
  }
}

///|
/// `validate_bundle_dir`'s SHOULD coverage warnings: a numbered `.entry` with no
/// `data-claim` warns `prov.untagged_number` while a tagged sibling stays silent;
/// a committed PNG shown by an `<img>` carrying no `data-claim` warns
/// `prov.asset_uncited`; and a fully-covered bundle (a tagged number plus a cited
/// `<img>`) passes clean. Each warning case also asserts the report still
/// passes (`ok()`), pinning these findings as non-blocking `Should`s. The rows
/// are `gap` status so their source checks are skipped, isolating the coverage
/// warnings.
async test "validate_bundle_dir coverage warnings" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-prov-cov")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    // A numbered .entry with no data-claim warns; a tagged sibling does not.
    let untagged = make_bundle(
      root,
      "untagged",
      Some(
        deck_with_entry(
          entry_of("a", "a", "<span data-claim=\"c1\">25</span>") +
          entry_of("b", "b", "40"),
        ),
      ),
      Some(prov_gap_rows(["c1"])),
      Some("no gaps\n"),
    )
    let untagged_report = validate_bundle_dir(untagged, "project", root, root)
    json_inspect(untagged_report.codes(), content=["prov.untagged_number"])
    // The coverage warning is advisory: a bundle carrying only a Should finding
    // still passes, so a should()->must() regression would fail this `ok()`.
    assert_true(untagged_report.ok())
    // A committed PNG shown by an <img> carrying no data-claim is uncited.
    let uncited = make_bundle(
      root,
      "uncited",
      Some(deck_with_entry(entry() + "<img src=\"assets/f.png\">")),
      Some(prov_gap_rows(["c1"])),
      Some("no gaps\n"),
    )
    @fs.mkdir("\{uncited}/assets")
    @fs.write_file("\{uncited}/assets/f.png", "x", create_mode=CreateOrTruncate)
    let uncited_report = validate_bundle_dir(uncited, "project", root, root)
    json_inspect(uncited_report.codes(), content=["prov.asset_uncited"])
    assert_true(uncited_report.ok())
    // A tagged number and a cited <img> pass clean.
    let clean = make_bundle(
      root,
      "clean",
      Some(
        deck_with_entry(
          entry_of("a", "a", "<span data-claim=\"c1\">25</span>") +
          "<img src=\"assets/f.png\" data-claim=\"c2\">",
        ),
      ),
      Some(prov_gap_rows(["c1", "c2"])),
      Some("no gaps\n"),
    )
    @fs.mkdir("\{clean}/assets")
    @fs.write_file("\{clean}/assets/f.png", "x", create_mode=CreateOrTruncate)
    json_inspect(validate_bundle_dir(clean, "project", root, root).codes(), content=[])
  }
}

///|
/// The shipped template's forward-contract example IDs are real, parseable
/// `data-claim` attributes. Pairing them with schema-valid rows produces a clean
/// whole-bundle report, so prompt authors can safely copy the component shape
/// before replacing both example IDs and placeholder content.
async test "shipped template claim examples satisfy bundle cross-reference" {
  guard find_repo_root() is Some(source_root) else { return }
  let html = @fs.read_file("\{source_root}/templates/deck.html").text()
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-template-claims")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let bundle = make_bundle(
      root,
      "template",
      Some(html),
      Some(prov_gap_rows(["example-verified", "example-gap"])),
      Some("- Template claim IDs are illustrative and require replacement.\n"),
    )
    json_inspect(
      validate_bundle_dir(
        bundle,
        "project",
        source_root,
        "\{source_root}/decks",
      ).codes(),
      content=[],
    )
  }
}

///|
/// M2.4's promoted live bundles remain validator-clean acceptance fixtures when
/// their sibling source projects are available. Standalone clones skip only the
/// source-dependent quote checks; the committed bundles remain versioned and
/// their structure is covered by the ordinary deck tests.
async test "committed live bundles pass when their sources are available" {
  guard find_repo_root() is Some(root) else { return }
  let source_base = split_path(root).0
  for project in ["spine-segmentation", "rehab"] {
    if !@fs.exists("\{source_base}/\{project}") {
      continue
    }
    let bundle = "\{root}/decks/\{project}"
    let report = validate_bundle_dir(
      bundle,
      project,
      source_base,
      "\{root}/decks",
    )
    json_inspect(report.codes(), content=[])
    let figures = @fs.read_file("\{bundle}/figures.py").text()
    assert_true(
      figures.has_prefix(
        "# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception\n",
      ),
    )
  }
}
