// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

///|
/// M4 installed-live proof revalidator. The shell harness creates and runs an
/// isolated checkout, then points this independently invoked test at the final
/// artifacts. Ordinary suites return before filesystem access.
async test "independently validates installed live-run bundle and render" {
  guard @env.get_env_var("SLIDE_GEN_LIVE_RUN_ROOT") is Some(root) else {
    return
  }
  guard @env.get_env_var("SLIDE_GEN_LIVE_RUN_PROJECT") is Some(project) else {
    return
  }
  let (projects_dir, checkout_name) = split_path(root)
  assert_eq(checkout_name, "slide-gen")
  let deck_home = "\{root}/decks"
  let bundle = "\{deck_home}/\{project}"
  let bundle_report = validate_bundle_dir(
    bundle, project, projects_dir, deck_home,
  )
  assert_true(bundle_report.ok(), msg=bundle_report.render())

  let render_dir = "\{root}/renders/\{project}"
  let render_is_real_dir = try
    @fs.kind(render_dir, follow_symlink=false)
  catch {
    _ => false
  } noraise {
    @fs.Directory => true
    _ => false
  }
  assert_true(
    render_is_real_dir,
    msg="published render root is not a real directory",
  )
  let names = @fs.readdir(
    render_dir,
    include_hidden=true,
    include_special=false,
  )
  let entries : Array[RenderEntry] = []
  let mut page_count = 0
  for name in names {
    let regular = try
      @fs.kind("\{render_dir}/\{name}", follow_symlink=false)
    catch {
      _ => false
    } noraise {
      @fs.Regular => true
      _ => false
    }
    entries.push(RenderEntry::{ name, regular })
    if name.has_prefix("page_") && name.has_suffix(".png") {
      page_count = page_count + 1
    }
  }
  assert_true(page_count > 0, msg="published render contains no page PNGs")
  let layout = validate_render_layout(entries, page_count)
  assert_true(layout.ok(), msg=layout.render())
  for page in 1..<=page_count {
    guard render_page_name(page) is Some(name) else {
      abort("live-run page count exceeds the renderer contract")
    }
    let path = "\{render_dir}/\{name}"
    let regular = try @fs.kind(path, follow_symlink=false) catch {
      _ => false
    } noraise {
      @fs.Regular => true
      _ => false
    }
    assert_true(regular, msg="render page is not a real regular file: \{name}")
    match validate_page_png(@fs.read_file(path).binary()) {
      Some(code) => abort("render page failed PNG validation: \{name}: \{code}")
      None => ()
    }
  }
  let pdf = "\{render_dir}/deck.pdf"
  let pdf_is_regular = try @fs.kind(pdf, follow_symlink=false) catch {
    _ => false
  } noraise {
    @fs.Regular => true
    _ => false
  }
  assert_true(pdf_is_regular, msg="published PDF is not a real regular file")
  match validate_pdf_artifact(@fs.read_file(pdf).binary()) {
    Some(code) => abort("published PDF failed artifact validation: \{code}")
    None => ()
  }
}
