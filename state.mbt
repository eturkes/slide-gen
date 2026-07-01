// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// A subcommand that mutates the enabled set.
pub(all) enum Action {
  Enable
  Disable
  Toggle
} derive(Eq)

///|
/// Outcome of resolving an `Action` against the current state: either proceed to
/// the given end-state (`true` = enabled, `false` = disabled) or reject the name.
pub(all) enum Decision {
  SetEnabled(Bool)
  Reject
} derive(Eq)

///|
/// Decide an action's effect purely from whether the name is currently `in_set`
/// and whether it is a current discovery candidate (`is_candidate`).
///
/// Ending up enabled requires the name to be a current sibling — `enable`/`toggle`
/// of an unknown name is rejected. Disabling tolerates stale names (enabled but
/// no longer a sibling, e.g. the project was deleted or renamed) so they remain
/// removable; only a name that is neither enabled nor a sibling is rejected as a
/// likely typo. Idempotent no-ops (enabling an already-enabled candidate,
/// disabling an off candidate) resolve to their end-state, not a rejection.
pub fn resolve_action(
  action : Action,
  in_set : Bool,
  is_candidate : Bool,
) -> Decision {
  let want = match action {
    Enable => true
    Disable => false
    Toggle => !in_set
  }
  if want && !is_candidate {
    Reject
  } else if !want && !in_set && !is_candidate {
    Reject
  } else {
    SetEnabled(want)
  }
}

///|
/// Serialize the enabled set to the on-disk format: one name per line in
/// dictionary order, each terminated by a newline (empty set -> empty string).
/// Sorting uses the codepoint comparator, not `String`'s shortlex default.
pub fn serialize_state(enabled : @set.Set[String]) -> String {
  let names = enabled.to_array()
  names.sort_by(lex_compare)
  let sb = StringBuilder::new()
  for name in names {
    sb.write_stringview(name)
    sb.write_stringview("\n")
  }
  sb.to_string()
}

///|
/// Parse the on-disk format back into a set. Splits on the newline terminator
/// and drops empty lines; line content is never trimmed, so legal POSIX names
/// carrying internal spaces round-trip exactly. Duplicate lines collapse via the
/// set.
pub fn parse_state(content : String) -> @set.Set[String] {
  let names : Array[String] = []
  for line in content.split("\n") {
    if line.length() > 0 {
      names.push(line.to_owned())
    }
  }
  @set.Set(names[:])
}

///|
/// Render the enable/disable overview: every current sibling (in the given
/// order — the CLI passes them dictionary-sorted from `discover`) marked `[x]`
/// (enabled) or `[ ]` (disabled), then any stale entries (enabled but no longer
/// a sibling), sorted by codepoint, flagged `[!] <name> (missing)`. Lines are
/// joined by newlines with no trailing newline; an empty overview is "".
pub fn format_status(
  projects : Array[String],
  enabled : @set.Set[String],
) -> String {
  let lines : Array[String] = []
  for project in projects {
    let mark = if enabled.contains(project) { "[x]" } else { "[ ]" }
    lines.push("\{mark} \{project}")
  }
  let project_set = @set.Set(projects[:])
  let stale = enabled
    .to_array()
    .filter(fn(name) { !project_set.contains(name) })
  stale.sort_by(lex_compare)
  for name in stale {
    lines.push("[!] \{name} (missing)")
  }
  let sb = StringBuilder::new()
  for i, line in lines {
    if i > 0 {
      sb.write_stringview("\n")
    }
    sb.write_stringview(line)
  }
  sb.to_string()
}

///|
/// Read the enabled set from `path`; a missing file reads as the empty set.
pub async fn read_state(path : String) -> @set.Set[String] {
  if @fs.exists(path) {
    parse_state(@fs.read_file(path).text())
  } else {
    parse_state("")
  }
}

///|
/// Write the enabled set to `path`: serialize to a sibling temp file (fsynced
/// for content integrity), then rename over the target. Rename within a
/// directory is atomic on POSIX, so a reader sees either the old or the new file
/// whole, never a partial one — atomic visibility. Crash-durability of the
/// rename itself is not guaranteed (the parent directory is not fsynced), which
/// is acceptable for a regenerable single-user state file.
///
/// Single-user tool: one writer at a time, so no lock and the fixed temp name is
/// safe — it keeps a crash from leaving more than one stale temp (the next write
/// overwrites it). It is deliberately not a concurrency guarantee: simultaneous
/// writers would share the temp and could interleave, which is out of scope.
pub async fn write_state(path : String, enabled : @set.Set[String]) -> Unit {
  let tmp = path + ".tmp"
  @fs.write_file(
    tmp,
    serialize_state(enabled),
    create_mode=@fs.CreateOrTruncate,
    sync=@fs.Full,
  )
  @fs.rename(tmp, path, replace=true)
}

///|
/// Read state, resolve `action` for `name`, and on acceptance apply it to the
/// set and persist (writing only when the set actually changes). Returns the
/// `Decision` so the caller can report success or reject with a non-zero exit.
pub async fn apply_action(
  state_path : String,
  projects : Array[String],
  name : String,
  action : Action,
) -> Decision {
  let enabled = read_state(state_path)
  let decision = resolve_action(
    action,
    enabled.contains(name),
    projects.contains(name),
  )
  match decision {
    SetEnabled(want) => {
      let changed = if want {
        enabled.add_and_check(name)
      } else {
        enabled.remove_and_check(name)
      }
      if changed {
        write_state(state_path, enabled)
      }
    }
    Reject => ()
  }
  decision
}

///|
/// Anchor on the repository root so every subcommand works run-from-anywhere:
/// the nearest ancestor of the current directory whose `moon.mod` declares this
/// module (`is_repo_marker`). `None` when the cwd is unavailable or no such
/// marker exists up to the filesystem root.
pub async fn find_repo_root() -> String? {
  match @env.current_dir() {
    None => None
    Some(dir) => ascend(dir)
  }
}

///|
/// Whether a `moon.mod`'s content marks the slide-gen repo — it declares this
/// module name. Matched position-independently (a substring test), so field
/// order is irrelevant; a dependency reference (`"eturkes/slide-gen@..."` in an
/// import block) carries no `name = ` prefix and so never counts. Bound to the
/// canonical `moon fmt` spacing: a formatter that changed it would fail safe —
/// the tool reports "not inside a slide-gen project" rather than silently
/// anchoring on an unrelated MoonBit project up the tree.
fn is_repo_marker(moon_mod : String) -> Bool {
  moon_mod.contains("name = \"eturkes/slide-gen\"")
}

///|
/// Walk upward from `dir` for the slide-gen repo root — the nearest ancestor
/// whose `moon.mod` is `is_repo_marker` — stopping at the filesystem root (where
/// `split_path` no longer shortens the path). A `moon.mod` that is absent or
/// unreadable reads as empty, hence not the marker, so the walk continues past
/// it rather than aborting the scan or anchoring on a foreign module.
async fn ascend(dir : String) -> String? {
  let content = try @fs.read_file("\{dir}/moon.mod").text() catch {
    _ => ""
  } noraise {
    text => text
  }
  if is_repo_marker(content) {
    Some(dir)
  } else {
    let (parent, _) = split_path(dir)
    if parent == dir {
      None
    } else {
      ascend(parent)
    }
  }
}
