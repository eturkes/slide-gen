// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Draw a representable name from a seeded RNG: length 1..=8 over a pool of
/// safe ASCII plus a couple of multibyte codepoints, spaces only in interior
/// positions (never at an edge) and never a leading `-`. Feeds the randomized
/// round-trip.
fn gen_name(rng : @splitmix.RandomState) -> String {
  let pool = [
    'a', 'b', 'c', 'X', 'Y', 'Z', '0', '1', '.', '_', '-', 'é', '道',
  ]
  // The first position excludes '-' (a leading dash is unrepresentable). No pool
  // char is whitespace and interior spaces never land at an edge, so every
  // generated name satisfies `representable`.
  let start_pool = [
    'a', 'b', 'c', 'X', 'Y', 'Z', '0', '1', '.', '_', 'é', '道',
  ]
  let len = 1 + rng.next_positive_int() % 8
  let mut s = ""
  for i in 0..<len {
    let c = if i == 0 {
      start_pool[rng.next_positive_int() % start_pool.length()]
    } else if i < len - 1 && rng.next_positive_int() % 4 == 0 {
      ' '
    } else {
      pool[rng.next_positive_int() % pool.length()]
    }
    s = s + "\{c}"
  }
  s
}

///|
/// The discovery name policy: reject empty, a leading `-`, any edge whitespace
/// (Unicode, not just ASCII space), `/`, and C0/DEL/C1 control characters;
/// accept everything else, including interior spaces, interior/trailing `-`, and
/// multibyte codepoints.
test "representable name policy" {
  assert_true(representable("simple"))
  assert_true(representable("a"))
  assert_true(representable("with space"))
  assert_true(representable("dot.in.middle"))
  assert_true(representable("é道"))
  assert_true(representable("mid-dash"))
  assert_true(representable("trailing-dash-"))
  assert_false(representable(""))
  assert_false(representable("-dash-bad"))
  assert_false(representable(" leading"))
  assert_false(representable("trailing "))
  assert_false(representable("\u{a0}nbsp"))
  assert_false(representable("ideographic\u{3000}"))
  assert_false(representable("with/slash"))
  assert_false(representable("tab\there"))
  assert_false(representable("nl\nhere"))
  assert_false(representable("\u{7f}del"))
  assert_false(representable("\u{85}c1nel"))
  assert_false(representable("a\u{9f}c1"))
}

///|
/// Every `(action, in_set, is_candidate)` triple (all 12) maps to the documented
/// `Decision`: enable/toggle of a non-candidate rejects — including a stale name
/// that is still enabled (`Enable, in_set, !candidate`), since enable requires a
/// current sibling; disable tolerates a stale entry (in set, no longer a sibling)
/// so it stays removable; disabling an entirely unknown name rejects; idempotent
/// no-ops resolve to their state.
test "resolve_action decision table" {
  let cases : Array[(Action, Bool, Bool, Decision)] = [
    (Enable, false, true, SetEnabled(true)),
    (Enable, true, true, SetEnabled(true)),
    (Enable, false, false, Reject),
    (Enable, true, false, Reject),
    (Disable, true, true, SetEnabled(false)),
    (Disable, true, false, SetEnabled(false)),
    (Disable, false, true, SetEnabled(false)),
    (Disable, false, false, Reject),
    (Toggle, false, true, SetEnabled(true)),
    (Toggle, true, true, SetEnabled(false)),
    (Toggle, true, false, SetEnabled(false)),
    (Toggle, false, false, Reject),
  ]
  for i, c in cases {
    let (action, in_set, is_cand, want) = c
    if resolve_action(action, in_set, is_cand) != want {
      fail("case \{i}: unexpected decision")
    }
  }
}

///|
/// Serialized form is one name per line in codepoint order (uppercase before
/// lowercase), each newline-terminated; a prefix sorts before its extension.
test "serialize_state golden" {
  let set = @set.Set(["zebra", "alpha", "Beta", "alpha two"][:])
  inspect(
    serialize_state(set),
    content=(
      #|Beta
      #|alpha
      #|alpha two
      #|zebra
      #|
    ),
  )
}

///|
/// Overview marks each current sibling `[x]`/`[ ]` in order, then flags stale
/// enabled-but-missing entries; no trailing newline.
test "format_status golden" {
  let enabled = @set.Set(["beta", "ghost"][:])
  let projects = ["alpha", "beta", "gamma"]
  inspect(
    format_status(projects, enabled),
    content=(
      #|[ ] alpha
      #|[x] beta
      #|[ ] gamma
      #|[!] ghost (missing)
    ),
  )
}

///|
/// Round-trip property: `serialize_state` is canonical, so re-serializing a
/// parsed dump reproduces it exactly across many randomized representable sets
/// (seeded → deterministic). Proves parse loses, adds, and mangles nothing.
test "serialize/parse round-trips representable name sets" {
  let rng = @splitmix.new(seed=0x5deece66d)
  for _r in 0..<200 {
    let names : Array[String] = []
    let n = rng.next_positive_int() % 6
    for _k in 0..<n {
      let name = gen_name(rng)
      assert_true(representable(name))
      names.push(name)
    }
    let s = serialize_state(@set.Set(names[:]))
    assert_eq(serialize_state(parse_state(s)), s)
  }
}

///|
/// A missing state file reads as empty; a written set reads back identically
/// (canonical sorted on disk). Exercises the atomic temp+rename write path.
async test "state file round-trips through disk" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="slide-gen-state")
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    let path = "\{dir}/enabled.txt"
    assert_eq(serialize_state(read_state(path)), "")
    let s = @set.Set(["one", "two name"][:])
    write_state(path, s)
    assert_eq(serialize_state(read_state(path)), serialize_state(s))
    inspect(
      @fs.read_file(path).text(),
      content=(
        #|one
        #|two name
        #|
      ),
    )
  }
}

///|
/// `apply_action` resolves, mutates, and persists end to end: accepted actions
/// write the canonical set; a rejection leaves the file untouched; a stale name
/// stays disable-able after it drops out of the candidate list.
async test "apply_action mutates and persists" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="slide-gen-apply")
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    let path = "\{dir}/enabled.txt"
    let projects = ["projA", "projB"]
    assert_true(
      apply_action(path, projects, "projA", Enable) == SetEnabled(true),
    )
    assert_eq(@fs.read_file(path).text(), "projA\n")
    assert_true(apply_action(path, projects, "ghost", Enable) == Reject)
    assert_eq(@fs.read_file(path).text(), "projA\n")
    assert_true(
      apply_action(path, projects, "projB", Toggle) == SetEnabled(true),
    )
    assert_eq(@fs.read_file(path).text(), "projA\nprojB\n")
    // projB is now stale (still enabled, no longer a candidate) -> removable.
    assert_true(
      apply_action(path, ["projA"], "projB", Disable) == SetEnabled(false),
    )
    assert_eq(@fs.read_file(path).text(), "projA\n")
  }
}
