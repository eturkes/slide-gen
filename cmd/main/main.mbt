// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// M1.1 scaffold entry: build the command tree and parse argv. `argparse`
/// auto-handles `--help` (prints + exits); `--version` would need a `version=`
/// on the command, unset here. Subcommand dispatch, error UX (parse errors →
/// stderr + nonzero exit), and `async fn main` + the first `@fs` await land in
/// M1.2/M1.3.
fn main {
  try @lib.cli().parse() catch {
    err => println(err)
  } noraise {
    _matches => ()
  }
}
