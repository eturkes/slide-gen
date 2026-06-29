// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Entry point. Parses argv (argparse auto-handles `--help` and bad args), then
/// dispatches subcommands. `list` discovers sibling projects under the repo's
/// parent directory and prints them one per line. `async` because discovery
/// awaits `@fs`; the full subcommand set and stderr/exit-code error routing
/// land in M1.3.
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
