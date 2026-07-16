// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// Typed result of one end-to-end generation-to-render operation. A published
/// run retains generation's validator report so advisory findings survive into
/// the combined CLI result. A render failure is explicitly partial: generation
/// already promoted the new deck, while no stale render is reported as current.
pub(all) enum RunOutcome {
  RunPublished(Report, RenderResult)
  RunSetupFailed(String)
  RunGenerationRetained(Report)
  RunGenerationFailed(String)
  RunRenderFailed(Report, RenderFailure)
}

///|
/// Compose injected generation and render phases beneath exactly one shared
/// project-operation lease. Generation must promote before render is called;
/// either generation failure form returns immediately. Unexpected errors are
/// absorbed at their phase boundary into typed failures while `defer` releases
/// the lease; the enabled-batch catch remains a final item-isolation boundary.
async fn run_project_with(
  root : String,
  project : String,
  generate~ : async (String, String) -> GenOutcome,
  render~ : async (String, String) -> RenderOutcome,
) -> RunOutcome {
  let lock_file = match acquire_project_operation_lock(root, project) {
    ProjectOperationLocked(file) => file
    ProjectOperationBusy =>
      return RunSetupFailed(
        "project operation busy: another generate/render/run owns \{project}",
      )
    ProjectOperationLockFailed(error) =>
      return RunSetupFailed("project operation lock failed: \{error}")
  }
  defer lock_file.close()
  defer lock_file.unlock()
  let generated = try generate(root, project) catch {
    error => return RunGenerationFailed("unexpected exception: \{error}")
  } noraise {
    result => result
  }
  match generated {
    Promoted(report) =>
      match
        (try render(root, project) catch {
          error =>
            RenderFailed(RenderFailure::{
              code: "run.render.exception",
              detail: "unexpected exception: \{error}",
            })
        } noraise {
          result => result
        }) {
        RenderPublished(result) => RunPublished(report, result)
        RenderFailed(failure) => RunRenderFailed(report, failure)
      }
    Retained(report) => RunGenerationRetained(report)
    ExecFailed(message) => RunGenerationFailed(message)
  }
}

///|
/// Production phase adapter: the caller already owns the project lease, so use
/// generation's package-owned core rather than its lock-owning public entry.
async fn run_generate_locked(root : String, project : String) -> GenOutcome {
  generate_project_locked(root, project)
}

///|
/// Production phase adapter: render the newly promoted deck beneath the same
/// lease held throughout generation.
async fn run_render_locked(root : String, project : String) -> RenderOutcome {
  render_project_locked(root, project)
}

///|
/// Run one named sibling through generation and final rendering while holding
/// one shared lease across both phases.
pub async fn run_project(root : String, project : String) -> RunOutcome {
  run_project_with(
    root,
    project,
    generate=run_generate_locked,
    render=run_render_locked,
  )
}

///|
/// Render one typed run outcome for CLI use. Full success concatenates the
/// established generation and render success lines. Failures identify the
/// failed phase; a render-phase failure first reports the already-promoted deck
/// and its advisory findings, making the valuable partial result explicit.
pub fn run_cli_outcome(outcome : RunOutcome) -> (String, Int) {
  match outcome {
    RunPublished(report, result) => {
      let (generated, _) = render_outcome(Promoted(report))
      let (rendered, _) = render_cli_outcome(RenderPublished(result))
      (generated + rendered, 0)
    }
    RunSetupFailed(message) =>
      (final_newline("slide-gen: run setup failed: \{message}"), 1)
    RunGenerationRetained(report) =>
      (
        final_newline(
          "slide-gen: run failed during generation:\n\{report.render()}",
        ),
        1,
      )
    RunGenerationFailed(message) =>
      (final_newline("slide-gen: run failed during generation: \{message}"), 1)
    RunRenderFailed(report, failure) => {
      let (generated, _) = render_outcome(Promoted(report))
      (
        generated +
        final_newline(
          "slide-gen: run failed during render [\{failure.code}]: \{failure.detail}",
        ),
        1,
      )
    }
  }
}

///|
/// Injected enabled-set orchestration. Candidate projects run sequentially in
/// discovery order through the same one-lease item core; the established batch
/// boundary catches one item's exception, continues, and appends sorted stale
/// state failures without dispatching them.
async fn run_enabled_with(
  root : String,
  projects : Array[String],
  enabled : @set.Set[String],
  generate~ : async (String, String) -> GenOutcome,
  render~ : async (String, String) -> RenderOutcome,
) -> (String, Int) {
  async fn run(project : String) -> (String, Int) {
    run_cli_outcome(run_project_with(root, project, generate~, render~))
  }

  run_enabled_batch(projects, enabled, run~)
}

///|
/// Run every currently discovered enabled project sequentially. Missing state
/// entries become failures, an empty enabled set is a successful zero-item
/// summary, and the aggregate code is nonzero iff any item failed.
pub async fn run_enabled(
  root : String,
  projects : Array[String],
  state_path : String,
) -> (String, Int) {
  run_enabled_with(
    root,
    projects,
    read_state(state_path),
    generate=run_generate_locked,
    render=run_render_locked,
  )
}
