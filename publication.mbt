// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Three paths participating in one atomic-ish directory publication. `stage`
/// holds the newly built tree, `live` is the public tree, and `backup` is the
/// reserved rollback/restart slot. Callers own path construction and ensure the
/// three parent directories are reserved for this protocol.
priv struct PublicationPaths {
  stage : String
  backup : String
  live : String
}

///|
/// Result of acquiring the shared per-project generation/render lease. The
/// open file owns the advisory lock until callers unlock and close it; a busy
/// key is distinct from filesystem/setup failure so CLI render diagnostics stay
/// stable and actionable.
priv enum ProjectOperationLock {
  ProjectOperationLocked(@fs.File)
  ProjectOperationBusy
  ProjectOperationLockFailed(String)
}

///|
/// Remove one filesystem entry without recursively traversing a symlink at its
/// root. A real directory is removed recursively; files, symlinks, and other
/// non-directory entries are unlinked. A missing entry is already clean.
async fn remove_entry_no_follow(path : String) -> Unit {
  let entry_kind = try @fs.kind(path, follow_symlink=false) catch {
    _ => None
  } noraise {
    kind => Some(kind)
  }
  match entry_kind {
    None => ()
    Some(@fs.Directory) => @fs.rmdir(path, recursive=true)
    Some(_) => @fs.remove(path)
  }
}

///|
/// Ensure `path` is an existing real directory without treating an already
/// present directory as an error (async fs `mkdir(recursive=true)` still reports
/// EEXIST for the exact leaf on this toolchain). If another operation wins a
/// missing-directory creation race, a no-follow recheck accepts only its real
/// directory. A non-directory entry fails closed; it is never removed/followed.
async fn ensure_real_dir(path : String) -> Unit {
  if !is_real_directory_no_follow(path) {
    try @fs.mkdir(path, recursive=true) catch {
      error => if !is_real_directory_no_follow(path) { raise error }
    } noraise {
      _ => ()
    }
  }
}

///|
/// Acquire one non-blocking exclusive lease shared by generation and rendering
/// for `project`. Lock files persist under ignored `renders/.locks`; the open
/// descriptor, not file presence, owns the lease, so crashes release it. Every
/// generation/render entry participates, preventing an older render from
/// publishing after a newer deck invalidated it. No-follow path checks reject
/// forged lock leaves; the opened descriptor must independently identify as a
/// regular file.
async fn acquire_project_operation_lock(
  root : String,
  project : String,
) -> ProjectOperationLock {
  guard root.has_prefix("/") && valid_render_project(project) else {
    return ProjectOperationLockFailed(
      "project lock requires an absolute root and a representable non-dot direct-child name",
    )
  }
  let render_root = join_path(root, "renders")
  let locks_dir = join_path(render_root, ".locks")
  let lock_path = join_path(locks_dir, "\{project}.lock")
  let setup_error : String? = try {
    ensure_real_dir(render_root)
    ensure_real_dir(locks_dir)
    None
  } catch {
    error => Some("could not establish lock directory: \{error}")
  } noraise {
    result => result
  }
  match setup_error {
    Some(error) => return ProjectOperationLockFailed(error)
    None => ()
  }
  let leaf_kind = try Some(@fs.kind(lock_path, follow_symlink=false)) catch {
    _ => None
  } noraise {
    result => result
  }
  match leaf_kind {
    None | Some(@fs.Regular) => ()
    Some(_) =>
      return ProjectOperationLockFailed("lock leaf is not a regular file")
  }
  let file = try
    @fs.open(
      lock_path,
      mode=ReadWrite,
      create_mode=OpenOrCreate,
      permission=0o600,
    )
  catch {
    error => return ProjectOperationLockFailed("could not open lock: \{error}")
  } noraise {
    file => file
  }
  if file.kind() != @fs.Regular {
    file.close()
    return ProjectOperationLockFailed("opened lock is not a regular file")
  }
  let acquired = try file.try_lock(Exclusive) catch {
    error => {
      file.close()
      return ProjectOperationLockFailed("could not acquire lock: \{error}")
    }
  } noraise {
    result => result
  }
  if !acquired {
    file.close()
    return ProjectOperationBusy
  }
  ProjectOperationLocked(file)
}

///|
/// Establish the three protocol-owned directory roots without following a
/// symlink at any root. Checking the live parent first makes later reserved
/// stage/backup-parent checks safe when all three share a common home.
async fn ensure_publication_roots(paths : PublicationPaths) -> Unit {
  ensure_real_dir(split_path(paths.live).0)
  ensure_real_dir(split_path(paths.stage).0)
  ensure_real_dir(split_path(paths.backup).0)
}

///|
/// Recreate the reserved stage as an empty real directory. No-follow removal
/// prevents a stale or swapped stage-root symlink from turning recursive cleanup
/// into deletion of its target.
async fn recreate_stage(paths : PublicationPaths) -> Unit {
  ensure_publication_roots(paths)
  remove_entry_no_follow(paths.stage)
  @fs.mkdir(paths.stage)
}

///|
/// Recover an interrupted prior replacement. A real backup is restored when
/// live is absent; when both exist, live won and the stale backup is discarded.
/// A forged non-directory backup is removed without following it.
async fn recover_publication(paths : PublicationPaths) -> Unit {
  ensure_publication_roots(paths)
  let live_kind = try @fs.kind(paths.live, follow_symlink=false) catch {
    _ => None
  } noraise {
    kind => Some(kind)
  }
  let backup_kind = try @fs.kind(paths.backup, follow_symlink=false) catch {
    _ => None
  } noraise {
    kind => Some(kind)
  }
  match (live_kind, backup_kind) {
    (None, Some(@fs.Directory)) => {
      ensure_real_dir(split_path(paths.live).0)
      @fs.rename(paths.backup, paths.live)
    }
    (Some(_), Some(_)) | (None, Some(_)) => remove_entry_no_follow(paths.backup)
    _ => ()
  }
}

///|
/// Permanently invalidate every restorable public artifact for one publication
/// key. Recovery first collapses an interrupted prior swap to one live entry;
/// backup is then cleared before live, so any failure before the final removal
/// leaves the currently valid public entry in place. Every removal classifies
/// its leaf without following a symlink.
async fn invalidate_publication(paths : PublicationPaths) -> Unit {
  recover_publication(paths)
  remove_entry_no_follow(paths.backup)
  remove_entry_no_follow(paths.live)
}

///|
/// Replace live while preserving its old entry until stage lands. Live first
/// moves to the collision-free backup; a failed stage rename restores it before
/// propagating the error. Successful backup cleanup is best-effort and the next
/// recovery pass removes a leftover. The protocol is rollback-safe and
/// restart-recoverable, with a small two-rename crash interval where live is
/// absent.
async fn promote_stage(paths : PublicationPaths) -> Unit {
  ensure_publication_roots(paths)
  remove_entry_no_follow(paths.backup)
  let had_live = try @fs.kind(paths.live, follow_symlink=false) catch {
    _ => false
  } noraise {
    _ => true
  }
  if had_live {
    ensure_real_dir(split_path(paths.backup).0)
    @fs.rename(paths.live, paths.backup)
  }
  try @fs.rename(paths.stage, paths.live) catch {
    error => {
      if had_live {
        try @fs.rename(paths.backup, paths.live) catch {
          _ => ()
        } noraise {
          _ => ()
        }
      }
      raise error
    }
  } noraise {
    _ => ()
  }
  try remove_entry_no_follow(paths.backup) catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
/// Whether `path` is a real directory entry rather than a symlink or another
/// filesystem kind. Publication users bracket writers and renames with this
/// no-follow assertion when an external producer can swap the stage root.
async fn is_real_directory_no_follow(path : String) -> Bool {
  try @fs.kind(path, follow_symlink=false) catch {
    _ => false
  } noraise {
    @fs.Directory => true
    _ => false
  }
}
