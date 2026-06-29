// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Fixture tree under a fresh temp dir → `discover` → assert the exact
/// candidate set. Covers (candidate) real dir + symlink→dir; (skipped)
/// symlink→file, broken symlink, plain file, dotfile dir + file, and the
/// `exclude`-named entry; (no recursion) a nested subdir under a candidate;
/// (cwd ≠ scanned parent) the temp dir is never the process cwd. The task group
/// guarantees the fixture tree is removed even if an assertion fails.
async test "discover candidate set" {
  let root = @fs.tmpdir(prefix="slide-gen-discover")
  @async.with_task_group() <| group => {
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    @fs.mkdir("\{root}/realdir")
    @fs.mkdir("\{root}/realdir/nested")
    @fs.symlink("\{root}/link_to_dir", target="\{root}/realdir")
    @fs.write_file("\{root}/plainfile", "", create_mode=CreateOrTruncate)
    @fs.symlink("\{root}/link_to_file", target="\{root}/plainfile")
    @fs.symlink("\{root}/link_broken", target="\{root}/does_not_exist")
    @fs.mkdir("\{root}/.dotdir")
    @fs.write_file("\{root}/.dotfile", "", create_mode=CreateOrTruncate)
    @fs.mkdir("\{root}/myself")
    json_inspect(discover(root, exclude="myself"), content=[
      "link_to_dir", "realdir",
    ])
  }
}

///|
test "split_path" {
  let (p1, n1) = split_path("/home/u/Projects/slide-gen")
  inspect("\{p1}|\{n1}", content="/home/u/Projects|slide-gen")
  let (p2, n2) = split_path("/foo")
  inspect("\{p2}|\{n2}", content="/|foo")
  let (p3, n3) = split_path("bare")
  inspect("\{p3}|\{n3}", content=".|bare")
  let (p4, n4) = split_path("/a/b/")
  inspect("\{p4}|\{n4}", content="/a|b")
}
