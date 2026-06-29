// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// `list` on argv parses to the subcommand key that `main` dispatches on,
/// guarding the wiring between argparse registration and dispatch (the help
/// golden in `cli_wbtest.mbt` proves the subcommand is registered; this proves
/// the parsed key). M1.3 grows this file with enable/disable/toggle/status and
/// exit-status assertions.
test "list subcommand parses" {
  let name = match cli().parse(argv=["list"]).subcommand {
    Some((n, _)) => n
    None => "<none>"
  }
  inspect(name, content="list")
}
