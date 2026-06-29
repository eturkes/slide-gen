// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
test "cli help" {
  inspect(
    cli().render_help(),
    content=(
      #|Usage: slide-gen
      #|
      #|Generate and manage slide decks across sibling projects.
      #|
      #|Options:
      #|  -h, --help  Show help information.
      #|
    ),
  )
}
