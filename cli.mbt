// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Build the root CLI command. `list` shows discovered sibling projects, `status`
/// their enable/disable state, `enable`/`disable`/`toggle` mutate the persisted
/// set for the named project, and `generate` authors a project's deck via codex
/// (`--dry-run` previews the invocation). A subcommand is required. Mutations
/// take exactly one project name; `generate` accepts zero or one, with omission
/// selecting every enabled project.
pub fn cli() -> @argparse.Command {
  let name_arg = [
    @argparse.PositionArg(
      "name",
      about="Sibling project directory name.",
      num_args=@argparse.ValueRange::single(),
    ),
  ]
  let optional_name_arg = [
    @argparse.PositionArg(
      "name",
      about="Sibling project directory name; omit for all enabled projects.",
      num_args=@argparse.ValueRange(lower=0, upper=1),
    ),
  ]
  @argparse.Command(
    "slide-gen",
    about="Generate and manage slide decks across sibling projects.",
    subcommand_required=true,
    subcommands=[
      @argparse.Command("list", about="List discovered sibling projects."),
      @argparse.Command(
        "status",
        about="Show each sibling project's enabled state.",
      ),
      @argparse.Command(
        "enable",
        about="Enable a sibling project.",
        positionals=name_arg,
      ),
      @argparse.Command(
        "disable",
        about="Disable a sibling project (also clears a stale entry).",
        positionals=name_arg,
      ),
      @argparse.Command(
        "toggle",
        about="Flip a sibling project's enabled state.",
        positionals=name_arg,
      ),
      @argparse.Command(
        "generate",
        about="Generate one sibling deck or every enabled deck via codex.",
        flags=[
          @argparse.FlagArg(
            "dry-run",
            long="dry-run",
            about="Print the exact codex invocation and prompt without running it.",
          ),
        ],
        positionals=optional_name_arg,
      ),
    ],
  )
}
