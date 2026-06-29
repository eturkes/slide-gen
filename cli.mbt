// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Build the root CLI command. `list` enumerates discovered sibling projects;
/// the enable/disable/toggle/status subcommands + persisted state land in M1.3.
pub fn cli() -> @argparse.Command {
  @argparse.Command(
    "slide-gen",
    about="Generate and manage slide decks across sibling projects.",
    subcommands=[
      @argparse.Command("list", about="List discovered sibling projects."),
    ],
  )
}
