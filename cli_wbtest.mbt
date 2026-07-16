// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
test "cli help" {
  inspect(
    cli().render_help(),
    content=(
      #|Usage: slide-gen <command>
      #|
      #|Generate and manage slide decks across sibling projects.
      #|
      #|Commands:
      #|  list      List discovered sibling projects.
      #|  status    Show each sibling project's enabled state.
      #|  enable    Enable a sibling project.
      #|  disable   Disable a sibling project (also clears a stale entry).
      #|  toggle    Flip a sibling project's enabled state.
      #|  generate  Generate one sibling deck or every enabled deck via codex.
      #|  render    Render one committed deck to page PNGs and PDF.
      #|  run       Generate then render one sibling or every enabled sibling.
      #|  help      Print help for the subcommand(s).
      #|
      #|Options:
      #|  -h, --help     Show help information.
      #|  -V, --version  Show version information.
      #|
    ),
  )
}
