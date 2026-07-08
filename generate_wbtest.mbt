// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Pin `shell_quote`'s branches directly — it is package-private, so the dry-run
/// render goldens reach only the spaced-path case. It returns an unquoted-safe
/// element untouched and single-quotes everything else: the empty string (else
/// it vanishes from a reconstructed argv), an embedded single quote (the POSIX
/// `'\''` break-out), and any shell metacharacter. The quoting is display-only —
/// the live harness (M2.3b) execs the argv vector directly, so this string never
/// reaches a shell.
test "shell_quote leaves safe elements bare and single-quotes the rest" {
  // All-safe (letters/digits + the path/flag punctuation the argv carries): bare.
  inspect(
    shell_quote("/w/Projects/slide-gen"),
    content=(
      #|/w/Projects/slide-gen
    ),
  )
  inspect(
    shell_quote("--kill-after=30"),
    content=(
      #|--kill-after=30
    ),
  )
  inspect(
    shell_quote("a.b_c-d:e+f@g,h"),
    content=(
      #|a.b_c-d:e+f@g,h
    ),
  )
  // Empty -> '' so it survives as one (empty) argument.
  inspect(
    shell_quote(""),
    content=(
      #|''
    ),
  )
  // A space -> quoted, so the element stays a single argument.
  inspect(
    shell_quote("/w/My Projects"),
    content=(
      #|'/w/My Projects'
    ),
  )
  // An embedded single quote -> the standard '\'' break-out.
  inspect(
    shell_quote("a'b"),
    content=(
      #|'a'\''b'
    ),
  )
  // Shell metacharacters -> quoted (parameter expansion, command separator).
  inspect(
    shell_quote("a$b"),
    content=(
      #|'a$b'
    ),
  )
  inspect(
    shell_quote("a;b"),
    content=(
      #|'a;b'
    ),
  )
}
