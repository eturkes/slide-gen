// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Bind libc `exit(3)` for explicit non-zero exit codes. MoonBit exposes no
/// public process-exit; argparse uses this same primitive internally.
extern "c" fn c_exit(code : Int) = "exit"

///|
/// Write `msg` to stderr and terminate with `code`. Typed to return any `T` (it
/// never actually returns) so it composes in any position, including a branch
/// that must yield the surrounding match's value type.
async fn[T] die(msg : String, code : Int) -> T {
  @stdio.stderr.write(msg)
  c_exit(code)
  abort("unreachable: exit returned")
}

///|
/// Pull the single required `name` positional from a subcommand's matches.
fn get_name(sub : @argparse.Matches) -> String {
  match sub.values.get("name") {
    Some(values) if values.length() > 0 => values[0]
    _ => abort("internal: required positional 'name' missing after parse")
  }
}

///|
/// Pull `generate`/`run`'s optional `name` positional. Argparse may represent an
/// omitted ranged positional as no map entry or an empty value array; both mean
/// enabled-set batch mode.
fn get_optional_name(sub : @argparse.Matches) -> String? {
  match sub.values.get("name") {
    Some(values) if values.length() > 0 => Some(values[0])
    _ => None
  }
}

///|
/// Report a mutation's outcome: print the new state on success, or exit non-zero
/// with a stderr message when the action was rejected (an unknown project for
/// enable/toggle, or a name that is neither enabled nor a current sibling).
async fn report(decision : @lib.Decision, name : String) -> Unit {
  match decision {
    @lib.SetEnabled(want) =>
      println(if want { "enabled \{name}" } else { "disabled \{name}" })
    @lib.Reject =>
      die(
        "slide-gen: unknown project '\{name}' (run `slide-gen list` to see candidates)\n",
        1,
      )
  }
}

///|
/// Entry point: parse argv, anchor on the repository root (the nearest ancestor
/// whose `moon.mod` declares this module) so every subcommand works
/// run-from-anywhere, then dispatch. Named render dispatches directly against
/// the committed deck home; every other command discovers siblings only when it
/// needs them. Parse failures exit 2; runtime failures exit 1 on stderr; success
/// exits 0.
async fn main {
  let matches = try @lib.cli().parse() catch {
    err => die("slide-gen: \{err}\n", 2)
  } noraise {
    matches => matches
  }
  try {
    let root = match @lib.find_repo_root() {
      Some(root) => root
      None =>
        die(
          "slide-gen: not inside a slide-gen project (no slide-gen moon.mod found from the current directory upward)\n",
          1,
        )
    }
    match matches.subcommand {
      Some(("render", sub)) => {
        let target = get_name(sub)
        let (message, code) = @lib.render_cli_outcome(
          @lib.render_project(root, target),
        )
        if code == 0 {
          @stdio.stdout.write(message)
        } else {
          die(message, code)
        }
      }
      _ => {
        let (parent, name) = @lib.split_path(root)
        let projects = @lib.discover(parent, exclude=name)
        let state_path = "\{root}/enabled.txt"
        match matches.subcommand {
          Some(("list", _)) =>
            for project in projects {
              println(project)
            }
          Some(("status", _)) => {
            let text = @lib.format_status(projects, @lib.read_state(state_path))
            if !text.is_empty() {
              println(text)
            }
          }
          Some(("enable", sub)) => {
            let target = get_name(sub)
            report(
              @lib.apply_action(state_path, projects, target, @lib.Enable),
              target,
            )
          }
          Some(("disable", sub)) => {
            let target = get_name(sub)
            report(
              @lib.apply_action(state_path, projects, target, @lib.Disable),
              target,
            )
          }
          Some(("toggle", sub)) => {
            let target = get_name(sub)
            report(
              @lib.apply_action(state_path, projects, target, @lib.Toggle),
              target,
            )
          }
          Some(("generate", sub)) => {
            let dry_run = sub.flags.get("dry-run") is Some(true)
            match get_optional_name(sub) {
              Some(target) => {
                if !projects.contains(target) {
                  die(
                    "slide-gen: unknown project '\{target}' (run `slide-gen list` to see candidates)\n",
                    1,
                  )
                }
                if dry_run {
                  @stdio.stdout.write(@lib.render_dry_run(root, target))
                } else {
                  let outcome = @lib.generate_project(root, target)
                  let (message, code) = @lib.render_outcome(outcome)
                  if code == 0 {
                    @stdio.stdout.write(message)
                  } else {
                    die(message, code)
                  }
                }
              }
              None => {
                let (message, code) = @lib.generate_enabled(
                  root,
                  projects,
                  state_path,
                  dry_run~,
                )
                @stdio.stdout.write(message)
                if code != 0 {
                  c_exit(code)
                  abort("unreachable: exit returned")
                }
              }
            }
          }
          Some(("run", sub)) =>
            match get_optional_name(sub) {
              Some(target) => {
                if !projects.contains(target) {
                  die(
                    "slide-gen: unknown project '\{target}' (run `slide-gen list` to see candidates)\n",
                    1,
                  )
                }
                let (message, code) = @lib.run_cli_outcome(
                  @lib.run_project(root, target),
                )
                if code == 0 {
                  @stdio.stdout.write(message)
                } else {
                  die(message, code)
                }
              }
              None => {
                let (message, code) = @lib.run_enabled(
                  root, projects, state_path,
                )
                @stdio.stdout.write(message)
                if code != 0 {
                  c_exit(code)
                  abort("unreachable: exit returned")
                }
              }
            }
          _ => ()
        }
      }
    }
  } catch {
    err => die("slide-gen: \{err}\n", 1)
  }
}
