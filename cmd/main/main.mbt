// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// M1.1 scaffold entry: build the command tree and parse argv. `argparse`
/// auto-handles `--help`/`--version` (prints + exits). Subcommand dispatch,
/// error UX (exit codes), and `async fn main` + the first `@fs` await land in
/// M1.2/M1.3.
fn main {
  try @lib.cli().parse() catch {
    err => println(err)
  } noraise {
    _matches => ()
  }
}
