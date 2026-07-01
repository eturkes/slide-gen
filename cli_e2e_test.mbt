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
