package bifrost_codegen

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_codegen_discovers_ui_actions_struct_enum_and_scoped_handlers :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	defer {
		free_all(context.temp_allocator)
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
		mem.tracking_allocator_destroy(&track)
	}

	file_types :: `
package board_demo

import "../../bifrost"

Board_App :: struct {
	created_count: int,
	moved_left:    int,
	jumped_top:    int,
	quit:          bool,
}

@(ui_actions)
Board_Extra_Actions :: struct {
	Undo: u8 ` + "`bifrost:\"key=[, id=history.undo, group=time, group_desc=Time-Travel, desc=Undo, category=History\"`" + `,
	Redo: u8 ` + "`bifrost:\"key=], id=history.redo, group=time, group_desc=Time-Travel, desc=Redo, category=History\"`" + `,
}
`

	file_handlers :: `
package board_demo

@(ui_action="key=n, id=task.new, desc=New Task, label=Create New Task, category=Board")
on_new_task :: proc(app: ^Board_App) {
	app.created_count += 1
}

@(ui_scope="col_*")
@(ui_action="key=H, id=task.move_left, group=stage, desc=Move Left, category=Board")
on_move_left :: proc(app: ^Board_App) {
	app.moved_left += 1
}

@(ui_action="vim=g g, helix=g g, emacs=<C-x> [, id=nav.top, desc=Jump Top, desc_emacs='beginning-of-buffer', category=Navigation")
on_jump_top :: proc(app: ^Board_App) {
	app.jumped_top += 1
}

@(ui_action="key=q|<C-q>, id=app.quit, desc=Quit, category=System")
on_quit :: proc(app: ^Board_App) {
	app.quit = true
}
`

	diags := make([dynamic]Codegen_Diagnostic)
	defer destroy_diagnostics(&diags)

	generated, ok := generate_from_sources(
		{file_types, file_handlers},
		{"types.odin", "handlers.odin"},
		&diags,
	)
	defer delete(generated)

	testing.expect(t, ok)
	testing.expect_value(t, len(diags), 0)
	testing.expect(t, strings.contains(generated, "package board_demo"))
	testing.expect(t, strings.contains(generated, `import "../../bifrost"`))
	testing.expect(t, strings.contains(generated, "init_board_app_keymap_and_palette :: proc"))
	testing.expect(t, strings.contains(generated, "init_board_extra_actions_keymap_and_palette :: proc"))
	testing.expect(t, strings.contains(generated, "dispatch_board_app_action :: proc(self: ^Board_App, inp: ^bifrost.Input_State) -> bool"))
	testing.expect(t, strings.contains(generated, "on_new_task(self)"))
	testing.expect(t, strings.contains(generated, "on_move_left(self)"))
	testing.expect(t, strings.contains(generated, "on_jump_top(self)"))
	testing.expect(t, strings.contains(generated, "on_quit(self)"))
	testing.expect(t, strings.contains(generated, "dispatch_ui_actions :: proc {"))
	testing.expect(t, strings.contains(generated, `chord_emacs     = "<C-x> ["`))
	testing.expect(t, strings.contains(generated, `desc_emacs      = "beginning-of-buffer"`))
}

@(test)
test_codegen_reports_file_line_diagnostics_on_malformed_chords :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	defer {
		free_all(context.temp_allocator)
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
		mem.tracking_allocator_destroy(&track)
	}

	bad_src :: `package broken_pkg

import "../../bifrost"

App :: struct {
	x: int,
}

@(ui_action="key=<C->, id=bad.chord, desc=Broken")
on_bad_chord :: proc(app: ^App) {
	app.x += 1
}

@(ui_action="key=n, id=bad.arity, desc=ExtraParam")
on_bad_arity :: proc(app: ^App, extra: int) {
	app.x += extra
}
`

	diags := make([dynamic]Codegen_Diagnostic)
	defer destroy_diagnostics(&diags)

	generated, ok := generate_from_source(bad_src, "broken_actions.odin", &diags)
	defer delete(generated)

	testing.expect(t, !ok)
	testing.expect_value(t, len(diags), 2)
	if len(diags) >= 2 {
		testing.expect_value(t, diags[0].file, "broken_actions.odin")
		testing.expect(t, diags[0].line == 9 || diags[0].line == 10)
		testing.expect(t, strings.contains(diags[0].message, "<C->"))
		testing.expect(t, strings.contains(diags[1].message, "on_bad_arity"))
	}
}

@(test)
test_codegen_generate_directory_compiles_cleanly_with_odin_check :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Locate workspace root (whether `odin test` runs from repo root or `bifrost/codegen`)
	tmp_dir := ".tmp/codegen_test_pkg"
	if !os.exists("bifrost") && os.exists("../../bifrost") {
		tmp_dir = "../../.tmp/codegen_test_pkg"
	}
	bifrost_rel := "../../bifrost"

	_ = os.remove_all(tmp_dir)
	mk_err := os.make_directory_all(tmp_dir)
	testing.expect_value(t, mk_err, nil)
	defer {
		_ = os.remove_all(tmp_dir)
	}

	app_src := strings.concatenate({
		"package codegen_test_pkg\n\n",
		`import "`, bifrost_rel, `"`, "\n\n",
		"Test_App :: struct {\n",
		"\tmoves: int,\n",
		"\ttops:  int,\n",
		"}\n\n",
		"@(ui_scope=\"col_*\")\n",
		"@(ui_action=\"key=H, id=task.left, group=stage, desc=Move Left, category=Board\")\n",
		"handle_left :: proc(self: ^Test_App) {\n",
		"\tself.moves -= 1\n",
		"}\n\n",
		"@(ui_action=\"key=g g, id=nav.top, desc=Jump Top, category=Nav\")\n",
		"handle_top :: proc(self: ^Test_App) {\n",
		"\tself.tops += 1\n",
		"}\n\n",
		"verify_generated_api :: proc() -> bool {\n",
		"\tapp: Test_App\n",
		"\tinp: bifrost.Input_State\n",
		"\tcp: bifrost.Command_Palette\n",
		"\tbifrost.command_palette_init(&cp, &inp)\n",
		"\tinit_test_app_keymap_and_palette(&inp, &cp)\n",
		"\tinp.triggered_action_id = bifrost.hash_id(\"nav.top\")\n",
		"\t_ = dispatch_ui_actions(&app, &inp)\n",
		"\treturn app.tops == 1\n",
		"}\n",
	}, context.temp_allocator)

	app_file, _ := filepath.join({tmp_dir, "app.odin"}, context.temp_allocator)
	w_err := os.write_entire_file_from_string(app_file, app_src)
	testing.expect_value(t, w_err, nil)

	diags := make([dynamic]Codegen_Diagnostic, context.temp_allocator)
	out_path, gen_ok := generate_directory(tmp_dir, "ui_actions_gen.odin", &diags)
	defer delete(out_path)
	testing.expect(t, gen_ok)
	testing.expect_value(t, len(diags), 0)

	state, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{
		command = {
			"odin",
			"check",
			tmp_dir,
			"-no-entry-point",
			"-custom-attribute:ui_actions,ui_action,ui_scope",
			"-vet",
			"-vet-packages:codegen_test_pkg",
			"-strict-style",
		},
	}, context.temp_allocator)
	_ = stdout
	testing.expect_value(t, exec_err, nil)
	testing.expect(t, state.exit_code == 0, string(stderr))
}

@(test)
test_codegen_detects_style_specific_chord_conflicts_and_escaped_quotes :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	defer {
		free_all(context.temp_allocator)
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
		mem.tracking_allocator_destroy(&track)
	}

	// 1. Conflicting `helix=` chords (with case-insensitive `<C-p>` vs `<c-p>`) must be rejected even when `vim=` chords differ
	helix_conflict_src :: `package conflict_pkg

import "../../bifrost"

App :: struct {}

@(ui_action="vim=g p, helix=<C-p>, id=nav.prev_a, desc=Prev A")
on_prev_a :: proc(app: ^App) {}

@(ui_action="vim=g P, helix=<c-p>, id=nav.prev_b, desc=Prev B")
on_prev_b :: proc(app: ^App) {}
`
	diags := make([dynamic]Codegen_Diagnostic)
	defer destroy_diagnostics(&diags)

	bad_gen, ok := generate_from_source(helix_conflict_src, "helix_conflict.odin", &diags)
	defer delete(bad_gen)

	testing.expect(t, !ok)
	testing.expect_value(t, len(diags), 1)
	if len(diags) == 1 {
		testing.expect(t, strings.contains(diags[0].message, "duplicate key chord"))
	}

	// 2. Escaped single quote `\'` inside a single-quoted `desc='...'` with a comma must not split the tag prematurely
	escaped_quote_src :: `package escaped_pkg

import "../../bifrost"

App :: struct {}

@(ui_action="key=m, desc='Don\'t panic, save now', id=app.panic_save, category=System")
on_panic_save :: proc(app: ^App) {}
`
	diags_ok := make([dynamic]Codegen_Diagnostic)
	defer destroy_diagnostics(&diags_ok)

	good_gen, ok2 := generate_from_source(escaped_quote_src, "escaped_quote.odin", &diags_ok)
	defer delete(good_gen)

	testing.expect(t, ok2)
	testing.expect_value(t, len(diags_ok), 0)
	testing.expect(t, strings.contains(good_gen, `action_name     = "app.panic_save"`))
	testing.expect(t, strings.contains(good_gen, `category        = "System"`))
}

@(test)
test_atdd_codegen_emits_scoped_scenario_vtable_and_enforces_layer1_purity :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	defer {
		free_all(context.temp_allocator)
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
		mem.tracking_allocator_destroy(&track)
	}

	dsl_src :: `package sample_tests

import "core:testing"
import "../bifrost"

given_focused_widget :: proc(s: ^Suite_Ctx, id: string) {}
upon_pressing_key :: proc(s: ^Suite_Ctx, code: bifrost.Key_Code, mods: bifrost.Mod_Flags = {}, ch: rune = 0) {}
upon_pressing_key_rune :: proc(s: ^Suite_Ctx, ch: rune, mods: bifrost.Mod_Flags = {}) {}
upon_input_events :: proc(s: ^Suite_Ctx, events: ..bifrost.Input_Event, loc := #caller_location) {}
upon_query_rect :: proc(s: ^Suite_Ctx, id: string) -> (bifrost.Rect, bool) { return {}, false }
then_focused_widget_is_ctx :: proc(s: ^Suite_Ctx, id: string, loc := #caller_location) {}
`

	clean_spec_src :: `package sample_tests

import "core:testing"

@(test)
@(scenario)
spec_clean_layer1_scenario :: proc(t: ^testing.T) {
	_ = scenario(t, w = 80, h = 24)
	given.focused_widget("save_btn")
	upon.pressing_key(.Enter)
	then.focused_widget_is("save_btn")
}
`

	diags := make([dynamic]Codegen_Diagnostic)
	defer destroy_diagnostics(&diags)

	gen_code, ok := generate_atdd_from_sources(
		{dsl_src},
		{"dsl_sample.odin"},
		{clean_spec_src},
		{"spec_clean.odin"},
		&diags,
	)
	defer delete(gen_code)

	testing.expect(t, ok)
	testing.expect_value(t, len(diags), 0)
	testing.expect(t, strings.contains(gen_code, "@(deferred_out = scenario_scope_end)"))
	testing.expect(t, strings.contains(gen_code, `assert(_scenario_depth < MAX_SCENARIO_DEPTH`))
	testing.expect(t, strings.contains(gen_code, `assert(_active_scenario_ctx != nil`))
	testing.expect(t, strings.contains(gen_code, "@(rodata)"))
	testing.expect(t, strings.contains(gen_code, "Suite_Ctx_VTable :: struct"))
	testing.expect(t, strings.contains(gen_code, "Given_DSL :: struct"))
	testing.expect(t, strings.contains(gen_code, "Upon_DSL :: struct"))
	testing.expect(t, strings.contains(gen_code, "Then_DSL :: struct"))
	testing.expect(t, strings.contains(gen_code, "events: ..bifrost.Input_Event"))
	testing.expect(t, strings.contains(gen_code, "..events, loc = loc"))
	testing.expect(t, strings.contains(gen_code, "-> (bifrost.Rect, bool)"))
	testing.expect(t, strings.contains(gen_code, "then_focused_widget_is :: proc {"))
	testing.expect(t, strings.contains(gen_code, "loc := #caller_location"))

	// Now verify Layer 1 AST purity linter rejects:
	// - raw `testing.expect*` (including inside `:=` Value_Decl and inside callback `proc(...) { ... }`)
	// - direct `driver_*` (including inside `defer` and `s->driver_*`)
	// - 0-arg `then.*()`, `s->then_*()`, and `then_*()`
	impure_spec_src :: `package sample_tests

import "core:testing"

@(test)
@(scenario)
spec_impure_layer1_scenario :: proc(t: ^testing.T) {
	s := driver_init(nil, t, 80, 24)
	defer driver_destroy(&s)
	ok := testing.expect_value(t, 1, 1)
	then.everything_works()
	s->then_all_good()
	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context) {
		testing.expect(t, ctx != nil)
	})
}
`
	bad_diags := make([dynamic]Codegen_Diagnostic)
	defer destroy_diagnostics(&bad_diags)

	bad_code, bad_ok := generate_atdd_from_sources(
		{dsl_src},
		{"dsl_sample.odin"},
		{impure_spec_src},
		{"spec_impure.odin"},
		&bad_diags,
	)
	defer delete(bad_code)

	testing.expect(t, !bad_ok)
	testing.expect_value(t, len(bad_diags), 6)
	if len(bad_diags) == 6 {
		testing.expect(t, strings.contains(bad_diags[0].message, "driver_init"))
		testing.expect(t, strings.contains(bad_diags[1].message, "driver_destroy"))
		testing.expect(t, strings.contains(bad_diags[2].message, "testing.expect_value"))
		testing.expect(t, strings.contains(bad_diags[3].message, "then.everything_works()"))
		testing.expect(t, strings.contains(bad_diags[4].message, "s->then_all_good()"))
		testing.expect(t, strings.contains(bad_diags[5].message, "testing.expect"))
	}
}
