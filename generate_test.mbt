// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// The codex argv is exactly the bypass invocation wrapped in `timeout`, with
/// the working root set to the given cwd and no prompt (the prompt goes on
/// stdin, so it never appears in argv).
test "build_codex_argv is the bypass invocation under timeout" {
  json_inspect(build_codex_argv("/w/Projects", timeout_secs=900), content=[
    "timeout", "900", "codex", "exec", "--dangerously-bypass-approvals-and-sandbox",
    "--skip-git-repo-check", "-C", "/w/Projects",
  ])
}

///|
/// The dry run prints the resolved plan paths (source, template, stage, deck,
/// cwd), the exact argv, and the full stdin prompt — everything a live run would
/// use, with zero codex spend. The stage is the deck home plus a `.partial`
/// suffix; sources and cwd resolve against the repo parent.
test "render_dry_run shows paths, argv, and prompt" {
  inspect(
    render_dry_run("/w/Projects/slide-gen", "projA", timeout_secs=900),
    content=(
      #|generate (dry run) — no codex spend
      #|
      #|project:   projA
      #|source:    /w/Projects/projA
      #|template:  /w/Projects/slide-gen/templates/deck.html
      #|stage:     /w/Projects/slide-gen/decks/projA.partial
      #|deck:      /w/Projects/slide-gen/decks/projA
      #|cwd:       /w/Projects
      #|argv:      timeout 900 codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -C /w/Projects
      #|
      #|--- prompt (stdin) ---
      #|Generate a Japanese slide deck documenting the 'projA' project at /w/Projects/projA.
      #|
      #|Write a deck bundle into /w/Projects/slide-gen/decks/projA.partial/ (create it):
      #|  - deck.html: match the structure and CSS of /w/Projects/slide-gen/templates/deck.html exactly — a
      #|    Japanese three-tier layout (.jp original / .jpf furigana / .en gloss per
      #|    .entry), one <section class="slide"> per slide, each with an .eyebrow, a
      #|    .pageno, and its .entry blocks. Tag every data-bearing claim with
      #|    data-claim="<id>".
      #|  - provenance.json: a JSON array of rows {id, slide, claim, status, src,
      #|    quote}. status is verified | inferred | gap. For a non-gap row, src is
      #|    "<path>:<startLine>-<endLine>" (path relative to /w/Projects, or absolute)
      #|    and quote is text copied verbatim from that exact line range. Every deck
      #|    data-claim id must match a row id.
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
