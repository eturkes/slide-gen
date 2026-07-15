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
