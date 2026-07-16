// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// `list` on argv parses to the subcommand key that `main` dispatches on,
/// guarding the wiring between argparse registration and dispatch (the help
/// golden in `cli_wbtest.mbt` proves the subcommand is registered; this proves
/// the parsed key).
test "list subcommand parses" {
  let name = match cli().parse(argv=["list"]).subcommand {
    Some((n, _)) => n
    None => "<none>"
  }
  inspect(name, content="list")
}

///|
/// Each mutating subcommand parses to its key with the `name` positional bound;
/// `status` parses with no positional. Exit statuses are checked end-to-end in
/// `cli_e2e_test.mbt`.
test "subcommands parse with positionals" {
  guard cli().parse(argv=["enable", "projA"]).subcommand is Some((key, sub))
  inspect(key, content="enable")
  guard sub.values.get("name") is Some(names)
  inspect(names.length(), content="1")
  inspect(names[0], content="projA")
  guard cli().parse(argv=["status"]).subcommand is Some((status_key, _))
  inspect(status_key, content="status")
}

///|
/// `generate` accepts either one named project or no positional (the enabled-set
/// batch), and `--dry-run` surfaces as a true flag in both forms. Without the
/// flag it remains absent, so `main` can distinguish a preview from a live run.
test "generate subcommand parses with dry-run flag" {
  guard cli().parse(argv=["generate", "--dry-run", "projA"]).subcommand
    is Some((key, sub))
  inspect(key, content="generate")
  guard sub.values.get("name") is Some(names)
  inspect(names[0], content="projA")
  assert_true(sub.flags.get("dry-run") is Some(true))
  guard cli().parse(argv=["generate", "projB"]).subcommand is Some((_, plain))
  assert_false(plain.flags.get("dry-run") is Some(true))
  guard cli().parse(argv=["generate", "--dry-run"]).subcommand
    is Some((_, batch))
  assert_true(batch.flags.get("dry-run") is Some(true))
  assert_true(
    batch.values.get("name") is None || batch.values.get("name") is Some([]),
  )
}

///|
/// `render` requires exactly one committed-deck name and exposes the key that
/// main dispatches independently of sibling discovery and enabled state.
test "render subcommand parses one required deck name" {
  guard cli().parse(argv=["render", "archived.deck"]).subcommand
    is Some((key, sub))
  inspect(key, content="render")
  guard sub.values.get("name") is Some(names)
  inspect(names.length(), content="1")
  inspect(names[0], content="archived.deck")
}

///|
/// `run` accepts one current sibling or no positional for enabled-set batch
/// mode. It intentionally exposes no dry-run flag: generation's dry run remains
/// the exact spend preview, while an end-to-end render cannot be previewed.
test "run subcommand parses one optional sibling name" {
  guard cli().parse(argv=["run", "projA"]).subcommand is Some((key, named))
  inspect(key, content="run")
  guard named.values.get("name") is Some(names)
  inspect(names[0], content="projA")
  guard cli().parse(argv=["run"]).subcommand is Some((_, batch))
  assert_true(
    batch.values.get("name") is None || batch.values.get("name") is Some([]),
  )
}

///|
/// Final render outcomes map to one stable CLI line and status. Success names
/// the exact PDF plus page count; failures retain their machine code and detail
/// with exactly one trailing newline.
test "render CLI outcome maps publication and failure" {
  let (published_message, published_code) = render_cli_outcome(
    RenderPublished(RenderResult::{
      project: "rehab",
      page_count: 6,
      render_dir: "/repo/renders/rehab",
      pdf_path: "/repo/renders/rehab/deck.pdf",
    }),
  )
  inspect(
    "\{published_code}|\{published_message}",
    content=(
      #|0|rendered rehab: 6 pages -> /repo/renders/rehab/deck.pdf
      #|
    ),
  )
  let (single_message, single_code) = render_cli_outcome(
    RenderPublished(RenderResult::{
      project: "one",
      page_count: 1,
      render_dir: "/repo/renders/one",
      pdf_path: "/repo/renders/one/deck.pdf",
    }),
  )
  assert_eq(
    "\{single_code}|\{single_message}",
    "0|rendered one: 1 page -> /repo/renders/one/deck.pdf\n",
  )
  let (failed_message, failed_code) = render_cli_outcome(
    RenderFailed(RenderFailure::{
      code: "render.deck.directory",
      detail: "deck bundle is missing\n",
    }),
  )
  inspect(
    "\{failed_code}|\{failed_message}",
    content=(
      #|1|slide-gen: render failed [render.deck.directory]: deck bundle is missing
      #|
    ),
  )
}
