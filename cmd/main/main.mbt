// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Entry point. Parses argv (argparse auto-exits on `--help`; a bad-arg parse
/// error raises a display-ready message that currently surfaces through the
/// runtime boundary — stderr routing + nonzero exit codes land in M1.3), then
/// dispatches subcommands. `list` discovers sibling projects under the current
/// directory's parent and prints them one per line; treating cwd as the repo is
/// the M1.2 contract, and run-from-anywhere repo-root anchoring is an M1.3 item.
/// `async` because discovery awaits `@fs`; the full subcommand set lands in M1.3.
async fn main {
  let matches = @lib.cli().parse()
  match matches.subcommand {
    Some(("list", _)) =>
      match @env.current_dir() {
        Some(cwd) => {
          let (parent, name) = @lib.split_path(cwd)
          for project in @lib.discover(parent, exclude=name) {
            println(project)
          }
        }
        None => println("slide-gen: cannot determine current directory")
      }
    _ => ()
  }
}
