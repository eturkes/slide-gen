// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// End-to-end: drive the built binary against a synthetic sibling tree, then
/// assert exit codes, stdout, and the persisted state file. Gated on the
/// `SLIDE_GEN_BIN` env var (absolute path, set by the `test` recipe); without it
/// the test is a no-op, so a bare `moon test` stays green. The repo root is the
/// `slide-gen` dir (its `moon.mod` marker anchors discovery on the parent).
async test "cli end-to-end" {
  guard @env.get_env_var("SLIDE_GEN_BIN") is Some(bin) else { return }
  @async.with_task_group() <| group => {
    let tmp = @fs.tmpdir(prefix="slide-gen-e2e")
    group.add_defer(() => @fs.rmdir(tmp, recursive=true))
    let projects_dir = "\{tmp}/Projects"
    @fs.mkdir(projects_dir)
    let repo = "\{projects_dir}/slide-gen"
    @fs.mkdir(repo)
    @fs.mkdir("\{projects_dir}/projA")
    @fs.mkdir("\{projects_dir}/projB")
    @fs.write_file(
      "\{repo}/moon.mod",
      "name = \"eturkes/slide-gen\"\n",
      create_mode=CreateOrTruncate,
    )
    let state = "\{repo}/enabled.txt"

    // list -> both siblings in order, exit 0.
    let (code, out, _) = @process.collect_output(bin, ["list"], cwd=repo)
    assert_eq(code, 0)
    inspect(
      out.text(),
      content=(
        #|projA
        #|projB
        #|
      ),
    )

    // enable a candidate -> exit 0, persisted.
    let (code, out, _) = @process.collect_output(
      bin,
      ["enable", "projA"],
      cwd=repo,
    )
    assert_eq(code, 0)
    inspect(
      out.text(),
      content=(
        #|enabled projA
        #|
      ),
    )
    assert_eq(@fs.read_file(state).text(), "projA\n")

    // enable an unknown name -> exit 1 (app error) with the message on stderr
    // (this also proves the stderr write flushes before the libc exit), state
    // untouched.
    let (code, _, err) = @process.collect_output(
      bin,
      ["enable", "ghost"],
      cwd=repo,
    )
    assert_eq(code, 1)
    inspect(
      err.text(),
      content=(
        #|slide-gen: unknown project 'ghost' (run `slide-gen list` to see candidates)
        #|
      ),
    )
    assert_eq(@fs.read_file(state).text(), "projA\n")

    // toggle the other on -> canonical sorted persistence.
    let (code, _, _) = @process.collect_output(
      bin,
      ["toggle", "projB"],
      cwd=repo,
    )
    assert_eq(code, 0)
    assert_eq(@fs.read_file(state).text(), "projA\nprojB\n")

    // status -> per-sibling overview, exit 0.
    let (code, out, _) = @process.collect_output(bin, ["status"], cwd=repo)
    assert_eq(code, 0)
    inspect(
      out.text(),
      content=(
        #|[x] projA
        #|[x] projB
        #|
      ),
    )

    // disable -> exit 0, entry removed.
    let (code, _, _) = @process.collect_output(
      bin,
      ["disable", "projA"],
      cwd=repo,
    )
    assert_eq(code, 0)
    assert_eq(@fs.read_file(state).text(), "projB\n")

    // run-from-anywhere: invoked from a nested subdir, discovery still anchors on
    // the repo root and lists the same siblings. A foreign `moon.mod` planted at
    // the intermediate `cmd` level must be walked past (it does not declare this
    // module) rather than mis-anchored on, so the walk reaches the real root.
    @fs.mkdir("\{repo}/cmd")
    @fs.write_file(
      "\{repo}/cmd/moon.mod",
      "name = \"other/nested\"\n",
      create_mode=CreateOrTruncate,
    )
    let deep = "\{repo}/cmd/main"
    @fs.mkdir(deep)
    let (code, out, _) = @process.collect_output(bin, ["list"], cwd=deep)
    assert_eq(code, 0)
    inspect(
      out.text(),
      content=(
        #|projA
        #|projB
        #|
      ),
    )

    // missing required positional -> usage error (exit 2).
    let (code, _, _) = @process.collect_output(bin, ["enable"], cwd=repo)
    assert_eq(code, 2)

    // unknown subcommand -> usage error (exit 2).
    let (code, _, _) = @process.collect_output(bin, ["bogus"], cwd=repo)
    assert_eq(code, 2)
  }
}

///|
/// End-to-end dry run: `generate --dry-run <candidate>` prints the resolved
/// invocation and exits 0 with no codex spend; `generate <unknown>` is rejected
/// (exit 1) like `enable`. Live generation has its own explicit spend gate.
/// Gated on SLIDE_GEN_BIN, so a bare `moon test` is a no-op.
async test "generate dry-run end-to-end" {
  guard @env.get_env_var("SLIDE_GEN_BIN") is Some(bin) else { return }
  @async.with_task_group() <| group => {
    let tmp = @fs.tmpdir(prefix="slide-gen-gen")
    group.add_defer(() => @fs.rmdir(tmp, recursive=true))
    let projects_dir = "\{tmp}/Projects"
    @fs.mkdir(projects_dir)
    let repo = "\{projects_dir}/slide-gen"
    @fs.mkdir(repo)
    @fs.mkdir("\{projects_dir}/projA")
    @fs.write_file(
      "\{repo}/moon.mod",
      "name = \"eturkes/slide-gen\"\n",
      create_mode=CreateOrTruncate,
    )

    // dry run over a candidate -> exit 0, prints the invocation markers.
    let (code, out, _) = @process.collect_output(
      bin,
      ["generate", "--dry-run", "projA"],
      cwd=repo,
    )
    assert_eq(code, 0)
    let text = out.text()
    assert_true(text.contains("codex exec"))
    assert_true(text.contains("--dangerously-bypass-approvals-and-sandbox"))
    assert_true(text.contains("decks/.partial/projA"))
    assert_true(text.contains("--- prompt (stdin) ---"))
    // `print` (not `println`) the renderer -> exactly one trailing newline, with
    // no blank final line doubling the renderer's own.
    assert_false(text.has_suffix("\n\n"))

    // unknown project -> exit 1 like enable, message on stderr.
    let (code, _, err) = @process.collect_output(
      bin,
      ["generate", "ghost"],
      cwd=repo,
    )
    assert_eq(code, 1)
    assert_true(err.text().contains("unknown project"))
  }
}

///|
/// Explicit-spend smoke for the production Codex path. SLIDE_GEN_LIVE and the
/// built-binary gate must both be present; ordinary moon test and just test runs
/// return before setup. A tiny synthetic sibling project plus the shipped style
/// contract keeps this about plumbing: Codex must exit through the harness and
/// leave a non-empty deck.html in either the promoted or retained bundle.
async test "generate live codex smoke" {
  guard @env.get_env_var("SLIDE_GEN_LIVE") is Some(_) else { return }
  guard @env.get_env_var("SLIDE_GEN_BIN") is Some(bin) else { return }
  guard find_repo_root() is Some(source_root) else {
    abort("live smoke could not find the source slide-gen root")
  }
  let template = @fs.read_file("\{source_root}/templates/deck.html").text()
  @async.with_task_group() <| group => {
    let tmp = @fs.tmpdir(prefix="slide-gen-live")
    group.add_defer(() => @fs.rmdir(tmp, recursive=true))
    let projects_dir = "\{tmp}/Projects"
    let repo = "\{projects_dir}/slide-gen"
    let source = "\{projects_dir}/projA"
    @fs.mkdir("\{repo}/templates", recursive=true)
    @fs.mkdir(source)
    @fs.write_file(
      "\{repo}/moon.mod",
      "name = \"eturkes/slide-gen\"\n",
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{repo}/templates/deck.html",
      template,
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{source}/README.md",
      "# projA\n\nPurpose: a tiny fixture project for the slide generation smoke.\n",
      create_mode=CreateOrTruncate,
    )
    let (init_code, _, init_err) = @process.collect_output(
      "git",
      ["init", "-q"],
      cwd=repo,
    )
    assert_eq(init_code, 0, msg=init_err.text())
    let (add_code, _, add_err) = @process.collect_output(
      "git",
      ["add", "moon.mod", "templates/deck.html"],
      cwd=repo,
    )
    assert_eq(add_code, 0, msg=add_err.text())
    let (commit_code, _, commit_err) = @process.collect_output(
      "git",
      [
        "-c", "user.name=slide-gen smoke", "-c", "user.email=slide-gen@example.invalid",
        "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit",
        "-qm", "fixture",
      ],
      cwd=repo,
    )
    assert_eq(commit_code, 0, msg=commit_err.text())

    let (code, stdout, stderr) = @process.collect_output(
      bin,
      ["generate", "projA"],
      cwd=repo,
    )
    assert_true(code == 0 || code == 1)
    let published = "\{repo}/decks/projA"
    let retained = "\{repo}/decks/.partial/projA"
    let bundle = if @fs.exists(published) { published } else { retained }
    let deck_path = "\{bundle}/deck.html"
    assert_true(
      @fs.exists(deck_path),
      msg="live codex left no deck.html\nstdout:\{stdout.text()}\nstderr:\{stderr.text()}",
    )
    assert_true(@fs.read_file(deck_path).binary().length() > 0)
  }
}
