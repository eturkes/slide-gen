// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// The codex argv is exactly the bypass invocation wrapped in `timeout`, with
/// the working root set to the given cwd and no prompt (the prompt goes on
/// stdin, so it never appears in argv).
test "build_codex_argv is the bypass invocation under timeout" {
  json_inspect(build_codex_argv("/w/Projects", timeout_secs=900), content=[
    "timeout", "--kill-after=30", "900", "codex", "exec", "--dangerously-bypass-approvals-and-sandbox",
    "--skip-git-repo-check", "-C", "/w/Projects",
  ])
}

///|
/// With no `timeout_secs` override the argv carries the generous default ceiling,
/// pinning `default_timeout_secs` against silent drift (the exact tests here
/// otherwise always override it).
test "build_codex_argv defaults to the generous ceiling" {
  json_inspect(build_codex_argv("/w/Projects"), content=[
    "timeout", "--kill-after=30", "1800", "codex", "exec", "--dangerously-bypass-approvals-and-sandbox",
    "--skip-git-repo-check", "-C", "/w/Projects",
  ])
}

///|
/// GNU `timeout 0` disables its ceiling, so zero and negative overrides both
/// fall back to the positive default rather than creating an unbounded run.
test "build_codex_argv clamps non-positive timeout ceilings" {
  let zero = build_codex_argv("/w/Projects", timeout_secs=0)
  let negative = build_codex_argv("/w/Projects", timeout_secs=-10)
  assert_eq(zero[2], default_timeout_secs.to_string())
  assert_eq(negative[2], default_timeout_secs.to_string())
}

///|
/// The shipped runtime prompt is loaded rather than compiled into the binary,
/// receives every authoritative path, and embeds the complete HTML style
/// contract. Its required short sections and evidence/stop vocabulary pin the
/// GPT-5.6 prompt-guidance acceptance bar without snapshotting a large prompt.
async test "render_dry_run loads the versioned prompt and embeds the template" {
  guard find_repo_root() is Some(root) else { return }
  let contract = @fs.read_file("\{root}/templates/deck-prompt.md").text()
  let template = @fs.read_file("\{root}/templates/deck.html").text()
  let out = render_dry_run(root, "projA", timeout_secs=900)
  for
    heading in [
      "## Role", "## Goal", "## Success criteria", "## Constraints", "## Tools",
      "## Output", "## Stop rules",
    ] {
    assert_true(
      contract.contains(heading),
      msg="missing prompt section \{heading}",
    )
  }
  for
    required in [
      "verified", "inferred", "gap", "exact set parity", "fewest useful search/tool loops",
      "quote-in-line-slice", "full-deck browser render", "SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception",
      "three or more directly comparable aggregate",
    ] {
    assert_true(
      contract.contains(required),
      msg="missing prompt rule \{required}",
    )
  }
  assert_true(out.contains(contract))
  assert_true(out.contains(template))
  assert_true(out.contains("source:    \{split_path(root).0}/projA\n"))
  assert_true(out.contains("prompt:    \{root}/templates/deck-prompt.md\n"))
  assert_true(out.contains("decks/.partial/projA"))
  assert_true(
    out.contains(
      "post:      uv run --locked --no-dev python \{root}/tools/furigana_check.py \{root}/decks/.partial/projA\n",
    ),
  )
  assert_true(out.contains("--- prompt (stdin) ---"))
  assert_false(out.has_suffix("\n\n"))
}
