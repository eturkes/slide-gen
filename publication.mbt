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
/// EEXIST for the exact leaf on this toolchain). A non-directory entry fails
/// closed through `mkdir`; it is never removed or followed here.
async fn ensure_real_dir(path : String) -> Unit {
  let kind = try @fs.kind(path, follow_symlink=false) catch {
    _ => None
  } noraise {
    kind => Some(kind)
  }
  match kind {
    Some(@fs.Directory) => ()
    _ => @fs.mkdir(path, recursive=true)
  }
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
