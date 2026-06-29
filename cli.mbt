// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Build the root CLI command. Subcommands + dispatch land in M1.3.
pub fn cli() -> @argparse.Command {
  @argparse.Command(
    "slide-gen",
    about="Generate and manage slide decks across sibling projects.",
  )
}
