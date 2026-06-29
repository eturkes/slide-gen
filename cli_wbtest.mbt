// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
test "cli help" {
  inspect(
    cli().render_help(),
    content=(
      #|Usage: slide-gen [command]
      #|
      #|Generate and manage slide decks across sibling projects.
      #|
      #|Commands:
      #|  list  List discovered sibling projects.
      #|  help  Print help for the subcommand(s).
      #|
      #|Options:
      #|  -h, --help  Show help information.
      #|
    ),
  )
}
