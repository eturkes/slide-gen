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
