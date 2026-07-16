// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// A successful item calls generation then rendering exactly once while both
/// observe the same caller-owned lease. The lease is released after the typed
/// result returns.
async test "run project sequences promoted generation and render under one lease" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-run-success")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let calls : Array[String] = []
    async fn generate(actual_root : String, project : String) -> GenOutcome {
      calls.push("generate:\{project}")
      assert_eq(actual_root, root)
      assert_true(
        acquire_project_operation_lock(root, project) is ProjectOperationBusy,
      )
      Promoted(Report::{
        findings: [should("prov.untagged_number", "number needs a citation")],
      })
    }

    async fn render(actual_root : String, project : String) -> RenderOutcome {
      calls.push("render:\{project}")
      assert_eq(actual_root, root)
      assert_true(
        acquire_project_operation_lock(root, project) is ProjectOperationBusy,
      )
      RenderPublished(RenderResult::{
        project,
        page_count: 2,
        render_dir: "\{root}/renders/\{project}",
        pdf_path: "\{root}/renders/\{project}/deck.pdf",
      })
    }

    let outcome = run_project_with(root, "project", generate~, render~)
    guard outcome is RunPublished(report, result) else {
      abort("successful run did not publish")
    }
    json_inspect(calls, content=["generate:project", "render:project"])
    json_inspect(report.codes(), content=["prov.untagged_number"])
    assert_eq(result.page_count, 2)
    let reacquired = match acquire_project_operation_lock(root, "project") {
      ProjectOperationLocked(file) => file
      ProjectOperationBusy => abort("run retained its project lease")
      ProjectOperationLockFailed(error) =>
        abort("project lock failed after run: \{error}")
    }
    defer reacquired.close()
    defer reacquired.unlock()
  }
}

///|
/// A peer-held lease stops the operation before either injected phase. The new
/// command therefore participates in the same non-blocking exclusion contract
/// as direct generation and rendering.
async test "run project reports a busy shared lease before generation" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-run-busy")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let held = match acquire_project_operation_lock(root, "project") {
      ProjectOperationLocked(file) => file
      ProjectOperationBusy => abort("setup project lock was busy")
      ProjectOperationLockFailed(error) =>
        abort("setup project lock failed: \{error}")
    }
    defer held.close()
    defer held.unlock()
    let mut calls = 0
    async fn generate(actual_root : String, _ : String) -> GenOutcome {
      ignore(@fs.exists(actual_root))
      calls = calls + 1
      Promoted(Report::{ findings: [] })
    }

    async fn render(actual_root : String, project : String) -> RenderOutcome {
      ignore(@fs.exists(actual_root))
      calls = calls + 1
      RenderPublished(RenderResult::{
        project,
        page_count: 1,
        render_dir: "/unused",
        pdf_path: "/unused/deck.pdf",
      })
    }

    let outcome = run_project_with(root, "project", generate~, render~)
    guard outcome is RunSetupFailed(message) else {
      abort("busy run did not stop in setup")
    }
    assert_true(message.contains("project operation busy"))
    assert_eq(calls, 0)
  }
}

///|
/// Both blocking validation and producer failure stop before render. The typed
/// outcomes preserve their distinct generation failure forms.
async test "run project skips render after either generation failure" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-run-generation-failure")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let mut render_calls = 0
    async fn generate(actual_root : String, project : String) -> GenOutcome {
      ignore(@fs.exists(actual_root))
      if project == "retained" {
        Retained(Report::{ findings: [must("deck.missing", "deck absent")] })
      } else {
        ExecFailed("codex failed")
      }
    }

    async fn render(actual_root : String, project : String) -> RenderOutcome {
      ignore(@fs.exists(actual_root))
      render_calls = render_calls + 1
      RenderPublished(RenderResult::{
        project,
        page_count: 1,
        render_dir: "/unused",
        pdf_path: "/unused/deck.pdf",
      })
    }

    let retained = run_project_with(root, "retained", generate~, render~)
    let failed = run_project_with(root, "failed", generate~, render~)
    guard retained is RunGenerationRetained(report) else {
      abort("retained generation was not phase-typed")
    }
    json_inspect(report.codes(), content=["deck.missing"])
    guard failed is RunGenerationFailed(message) else {
      abort("producer failure was not phase-typed")
    }
    assert_eq(message, "codex failed")
    assert_eq(render_calls, 0)
  }
}

///|
/// A render failure after promotion is a typed partial result. Its CLI message
/// preserves the successful generation manifest/advisory before the failing
/// render phase and exits nonzero.
async test "run project reports render failure after promoted generation" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-run-render-failure")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    async fn generate(actual_root : String, _ : String) -> GenOutcome {
      ignore(@fs.exists(actual_root))
      Promoted(Report::{
        findings: [should("prov.asset", "asset needs source detail")],
      })
    }

    async fn render(actual_root : String, _ : String) -> RenderOutcome {
      ignore(@fs.exists(actual_root))
      RenderFailed(RenderFailure::{
        code: "render.tool",
        detail: "chromium failed\n",
      })
    }

    let outcome = run_project_with(root, "project", generate~, render~)
    guard outcome is RunRenderFailed(report, failure) else {
      abort("render failure was not retained as a partial run")
    }
    json_inspect(report.codes(), content=["prov.asset"])
    assert_eq(failure.code, "render.tool")
    let (message, code) = run_cli_outcome(outcome)
    assert_eq(code, 1)
    inspect(
      message,
      content=(
        #|generated: deck.html, provenance.json, gaps.md
        #|[SHOULD] prov.asset: asset needs source detail
        #|slide-gen: run failed during render [render.tool]: chromium failed
        #|
      ),
    )
  }
}

///|
/// The remaining typed outcomes map to stable phase-aware diagnostics. Success
/// combines both established phase messages, while setup and either generation
/// failure form exit one with exactly one trailing newline.
test "run CLI outcome maps success setup and generation failures" {
  let (published, published_code) = run_cli_outcome(
    RunPublished(Report::{ findings: [] }, RenderResult::{
      project: "project",
      page_count: 1,
      render_dir: "/repo/renders/project",
      pdf_path: "/repo/renders/project/deck.pdf",
    }),
  )
  assert_eq(published_code, 0)
  inspect(
    published,
    content=(
      #|generated: deck.html, provenance.json, gaps.md
      #|rendered project: 1 page -> /repo/renders/project/deck.pdf
      #|
    ),
  )
  let (setup, setup_code) = run_cli_outcome(
    RunSetupFailed("project operation busy"),
  )
  assert_eq(setup_code, 1)
  assert_eq(setup, "slide-gen: run setup failed: project operation busy\n")
  let (retained, retained_code) = run_cli_outcome(
    RunGenerationRetained(Report::{
      findings: [must("deck.missing", "deck absent")],
    }),
  )
  assert_eq(retained_code, 1)
  assert_eq(
    retained, "slide-gen: run failed during generation:\n[MUST] deck.missing: deck absent\n",
  )
  let (failed, failed_code) = run_cli_outcome(
    RunGenerationFailed("codex failed\n"),
  )
  assert_eq(failed_code, 1)
  assert_eq(failed, "slide-gen: run failed during generation: codex failed\n")
}

///|
/// Enabled orchestration keeps discovery order, phase-types raised producer and
/// renderer errors, continues through ordinary generation/render failures,
/// skips disabled and stale names, appends stale names sorted, and aggregates
/// every failed item.
async test "run enabled batch isolates mixed phase failures and stale state" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="slide-gen-run-batch")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let calls : Array[String] = []
    async fn generate(actual_root : String, project : String) -> GenOutcome {
      calls.push("generate:\{project}")
      if project == "explode" {
        ignore(@fs.read_file("\{actual_root}/missing"))
      }
      if project == "gen-fail" {
        ExecFailed("codex failed")
      } else {
        Promoted(Report::{ findings: [] })
      }
    }

    async fn render(actual_root : String, project : String) -> RenderOutcome {
      calls.push("render:\{project}")
      if project == "render-explode" {
        ignore(@fs.read_file("\{actual_root}/missing-render"))
      }
      if project == "render-fail" {
        RenderFailed(RenderFailure::{ code: "render.tool", detail: "failed" })
      } else {
        RenderPublished(RenderResult::{
          project,
          page_count: 1,
          render_dir: "\{root}/renders/\{project}",
          pdf_path: "\{root}/renders/\{project}/deck.pdf",
        })
      }
    }

    let enabled : @set.Set[String] = @set.Set([
      "render-fail", "stale-z", "ok", "explode", "render-explode", "gen-fail", "stale-a",
    ])
    let (message, code) = run_enabled_with(
      root,
      ["ok", "explode", "render-explode", "gen-fail", "render-fail", "disabled"],
      enabled,
      generate~,
      render~,
    )
    assert_eq(code, 1)
    json_inspect(calls, content=[
      "generate:ok", "render:ok", "generate:explode", "generate:render-explode",
      "render:render-explode", "generate:gen-fail", "generate:render-fail", "render:render-fail",
    ])
    assert_true(message.contains("[OK] ok\n"))
    assert_true(
      message.contains(
        "[FAILED] explode\nslide-gen: run failed during generation: unexpected exception:",
      ),
    )
    assert_true(
      message.contains(
        "[FAILED] render-explode\ngenerated: deck.html, provenance.json, gaps.md\nslide-gen: run failed during render [run.render.exception]: unexpected exception:",
      ),
    )
    assert_true(
      message.contains(
        "[FAILED] gen-fail\nslide-gen: run failed during generation: codex failed\n",
      ),
    )
    assert_true(
      message.contains(
        "[FAILED] render-fail\ngenerated: deck.html, provenance.json, gaps.md\nslide-gen: run failed during render [render.tool]: failed\n",
      ),
    )
    guard message.find("[FAILED] stale-a") is Some(stale_a) else {
      abort("missing first stale failure")
    }
    guard message.find("[FAILED] stale-z") is Some(stale_z) else {
      abort("missing second stale failure")
    }
    assert_true(stale_a < stale_z)
    assert_true(message.has_suffix("summary: 1 succeeded, 6 failed, 7 total\n"))
  }
}

///|
/// An empty enabled set dispatches neither injected phase and returns the
/// established successful zero-item summary.
async test "run enabled batch accepts an empty enabled set" {
  let mut calls = 0
  async fn generate(root : String, _ : String) -> GenOutcome {
    ignore(@fs.exists(root))
    calls = calls + 1
    Promoted(Report::{ findings: [] })
  }

  async fn render(root : String, project : String) -> RenderOutcome {
    ignore(@fs.exists(root))
    calls = calls + 1
    RenderPublished(RenderResult::{
      project,
      page_count: 1,
      render_dir: "/unused",
      pdf_path: "/unused/deck.pdf",
    })
  }

  let (message, code) = run_enabled_with(
    "/unused",
    ["project"],
    @set.Set([]),
    generate~,
    render~,
  )
  assert_eq(code, 0)
  assert_eq(calls, 0)
  assert_eq(message, "summary: 0 succeeded, 0 failed, 0 total\n")
}
