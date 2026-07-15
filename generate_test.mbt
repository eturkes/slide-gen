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
/// The dry run prints the resolved plan paths (source, template, stage, deck,
/// cwd), the exact argv, and the full stdin prompt — everything a live run would
/// use, with zero codex spend. The stage lives under the reserved
/// `decks/.partial/` dir; sources and cwd resolve against the repo parent.
test "render_dry_run shows paths, argv, and prompt" {
  inspect(
    render_dry_run("/w/Projects/slide-gen", "projA", timeout_secs=900),
    content=(
      #|generate (dry run) — no codex spend
      #|
      #|project:   projA
      #|source:    /w/Projects/projA
      #|template:  /w/Projects/slide-gen/templates/deck.html
      #|stage:     /w/Projects/slide-gen/decks/.partial/projA
      #|deck:      /w/Projects/slide-gen/decks/projA
      #|cwd:       /w/Projects
      #|argv:      timeout --kill-after=30 900 codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -C /w/Projects
      #|
      #|--- prompt (stdin) ---
      #|Generate a Japanese slide deck documenting the 'projA' project at /w/Projects/projA.
      #|
      #|Write a deck bundle into /w/Projects/slide-gen/decks/.partial/projA/ (create it):
      #|  - deck.html: match the structure and CSS of /w/Projects/slide-gen/templates/deck.html exactly — a
      #|    Japanese three-tier layout (.jp original / .jpf furigana / .en gloss per
      #|    .entry), one <section class="slide"> per slide, each with an .eyebrow, a
      #|    .pageno, and its .entry blocks. Tag every data-bearing claim with
      #|    data-claim="<id>".
      #|  - provenance.json: a JSON array of rows {id, slide, claim, status, src,
      #|    quote}. status is verified | inferred | gap. For a non-gap row, src is
      #|    "<path>:<startLine>-<endLine>" with <path> relative to /w/Projects (never
      #|    absolute) and quote copied verbatim from that exact line range. Cite only
      #|    real source files you read, never a file you write into the bundle. Every
      #|    deck data-claim id must match a row id.
      #|  - gaps.md: a Markdown bullet list of whatever you could not verify from the
      #|    sources, or the single line "no gaps". Route uncertain furigana readings
      #|    here rather than guessing.
      #|  - figures.py + assets/*.png: author figures only from committed, cited
      #|    numbers and run them; cite each PNG with a provenance row.
      #|
      #|Read only real files under /w/Projects; never invent quotes, line numbers, or
      #|readings. Keep secrets and personal or health data out of every committed
      #|file. Reply with a manifest listing the files you wrote.
      #|
    ),
  )
}

///|
/// Path joins stay canonical no matter how `root` is spelled: a filesystem-root
/// parent does not double the leading slash, and trailing slashes on `root` are
/// stripped before the deck/stage/template joins.
test "plan paths stay canonical at fs-root and past a trailing root slash" {
  let at_root = render_dry_run("/slide-gen", "projA", timeout_secs=900)
  assert_true(at_root.contains("source:    /projA\n"))
  assert_true(at_root.contains("cwd:       /\n"))
  assert_true(at_root.contains("stage:     /slide-gen/decks/.partial/projA\n"))
  let trailing = render_dry_run(
    "/w/Projects/slide-gen/",
    "projA",
    timeout_secs=900,
  )
  assert_true(
    trailing.contains("template:  /w/Projects/slide-gen/templates/deck.html\n"),
  )
  assert_true(
    trailing.contains("stage:     /w/Projects/slide-gen/decks/.partial/projA\n"),
  )
}

///|
/// The dry-run argv line shell-quotes an element containing a space so it
/// copy-pastes as one argument, while the plain label lines show the raw path.
test "dry-run argv shell-quotes a cwd containing spaces" {
  let out = render_dry_run(
    "/w/My Projects/slide-gen",
    "projA",
    timeout_secs=900,
  )
  assert_true(out.contains("-C '/w/My Projects'\n"))
  assert_true(out.contains("cwd:       /w/My Projects\n"))
}
