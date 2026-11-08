package bifrost

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import actor "../deps/heimdall/deps/sleipnir/actor"
import xitdb "../deps/xitdb/xitdb"
import codegen "./codegen"

@(test)
test_filtered_xitdb_slice_view_index_and_utf8_safe_truncation :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	defer {
		for _, entry in track.allocation_map {
			testing.expectf(t, false, "Leaked %d bytes at %v", entry.size, entry.location)
		}
		mem.tracking_allocator_destroy(&track)
	}

	// Fix 4: UTF-8 boundary-safe truncation in copy_string_to_buf
	{
		small_buf: [5]u8
		// "a🚀b" -> 'a' (1B) + '🚀' (4B: f0 9f 9a 80) + 'b' (1B)
		// Truncating into 4 bytes must back up to 1 byte ("a") rather than slicing mid-emoji
		n4, s4 := copy_string_to_buf(small_buf[:4], "a🚀b")
		testing.expect_value(t, n4, 1)
		testing.expect_value(t, s4, "a")

		n5, s5 := copy_string_to_buf(small_buf[:5], "a🚀b")
		testing.expect_value(t, n5, 5)
		testing.expect_value(t, s5, "a🚀")
	}

	// Fix 1: Filtered xitdb_slice_viewport visual row indexing & clamped total_rows
	core := xitdb.core_memory_init(context.allocator)
	defer _ = xitdb.core_destroy(&core)

	db, db_err := xitdb.database_init(&core)
	testing.expect_value(t, db_err, nil)

	tx := xitdb.tx_init(&db, -1, false, context.temp_allocator)
	al_step := xitdb.hm("logs")
	for i in 0 ..< 6 {
		val := fmt.tprintf("item_%d_match", i) if (i == 1 || i == 4) else fmt.tprintf("item_%d_skip", i)
		steps := [1]xitdb.Path_Step{al_step}
		xitdb.tx_append_steps(&tx, steps[:], val)
	}
	_, c_err := xitdb.tx_commit(&tx)
	testing.expect_value(t, c_err, nil)

	shared := Xitdb_Shared_Handle{db = &db}

	coord: UI_Coordinator_State
	testing.expect(t, ui_coordinator_init(&coord, 80, 20, &shared))
	defer ui_coordinator_destroy(&coord)

	ui_set_active_collection(&coord, "logs")
	_ = ui_reduce_single_msg(&coord, UI_Msg_Commit_Notification{moment_idx = 0, tx_id = 1})
	_ = ui_reduce_single_msg(&coord, UI_Msg_Search_Input{query = "match"})

	slice := ui_coordinator_slice_viewport(&coord, "records_pane", 10, context.temp_allocator)
	testing.expect_value(t, slice.total_rows, i64(2))
	testing.expect_value(t, coord.vlist.total_rows, 2)
	testing.expect_value(t, len(slice.rows), 2)
	if len(slice.rows) == 2 {
		// Row 0 in filtered view corresponds to logical DB index 1
		testing.expect_value(t, slice.rows[0].view_index, i64(0))
		testing.expect_value(t, slice.rows[0].logical_index, i64(1))
		// Row 1 in filtered view corresponds to logical DB index 4
		testing.expect_value(t, slice.rows[1].view_index, i64(1))
		testing.expect_value(t, slice.rows[1].logical_index, i64(4))
	}
	free_all(context.temp_allocator)
}

@(test)
test_flush_frame_hover_transitions_and_button_action_enum_dispatch :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	defer {
		for _, entry in track.allocation_map {
			testing.expectf(t, false, "Leaked %d bytes at %v", entry.size, entry.location)
		}
		mem.tracking_allocator_destroy(&track)
	}

	Test_Btn_Action :: enum u8 {
		None = 0,
		Run_Deploy,
	}

	render_btn_ui :: proc(coord: ^UI_Coordinator_State) {
		coord.use_widget_pipeline = true
		begin_frame(&coord.screen)
		begin_layout(&coord.layout_ctx, i32(coord.cols), i32(coord.rows))
		if ui_scope(&coord.layout_ctx, &coord.screen, "root", Scope_Config{
			dir    = .Column,
			width  = fixed(i32(coord.cols)),
			height = fixed(i32(coord.rows)),
		}) {
			_ = ui_button(&coord.layout_ctx, &coord.screen, "deploy_btn", Button_Spec{
				label  = "Deploy",
				width  = fixed(12),
				height = fixed(3),
				border = .Rounded,
			})
		}
		end_layout(&coord.layout_ctx)
	}

	coord: UI_Coordinator_State
	testing.expect(t, ui_coordinator_init(&coord, 40, 12, nil, render_btn_ui))
	defer ui_coordinator_destroy(&coord)

	_ = register_action_spec(&coord.input, &coord.palette, Action_Spec{
		action_name  = "app.deploy",
		chord_spec   = "d",
		has_enum_val = true,
		enum_val     = i64(Test_Btn_Action.Run_Deploy),
	})
	testing.expect(t, bind_button_action(&coord, "deploy_btn", "app.deploy"))

	// Frame 0: initial mount
	ui_coordinator_flush_frame(&coord)

	// Frame 1: Move mouse onto deploy_btn -> did_mouse_enter must be true AFTER ui_coordinator_flush_frame (Fix 2)
	_ = ui_reduce_single_msg(&coord, UI_Msg_Mouse{x = 2, y = 1, action = .Move})
	ui_coordinator_flush_frame(&coord)
	testing.expect(t, is_hovered(&coord.input, "deploy_btn"))
	testing.expect(t, did_mouse_enter(&coord.input, "deploy_btn"))

	// Frame 2: Press Enter on focused deploy_btn -> triggered_action(&coord.input, Test_Btn_Action) must return Run_Deploy (Fix 5)
	_ = ui_reduce_single_msg(&coord, UI_Msg_Key{code = .Enter})
	ui_coordinator_flush_frame(&coord)
	act, fired := triggered_action(&coord.input, Test_Btn_Action)
	testing.expect(t, fired)
	testing.expect_value(t, act, Test_Btn_Action.Run_Deploy)
	free_all(context.temp_allocator)
}

@(test)
test_chord_timeout_which_key_repeat_count_and_nav_overrides :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	defer {
		for _, entry in track.allocation_map {
			testing.expectf(t, false, "Leaked %d bytes at %v", entry.size, entry.location)
		}
		mem.tracking_allocator_destroy(&track)
	}

	scr: Screen
	testing.expect_value(t, screen_init(&scr, 80, 24), nil)
	defer screen_destroy(&scr)

	ctx: Layout_Context
	inp: Input_State
	inp.chord_timeout_ns = 500_000_000 // 500ms

	// Register both single-key "g" and two-step "g g" in the same scope (Feature 1 prefix disambiguation)
	_ = register_action_spec(&inp, nil, Action_Spec{
		action_name = "single.g",
		chord_spec  = "g",
		desc        = "Single G",
	})
	_ = register_action_spec(&inp, nil, Action_Spec{
		action_name = "double.gg",
		chord_spec  = "g g",
		desc        = "Jump Top",
	})

	build_frame :: proc(ctx: ^Layout_Context, scr: ^Screen, inp: ^Input_State) {
		begin_frame(scr)
		begin_layout(ctx, 80, 24)
		if ui_scope(ctx, scr, "root", Scope_Config{
			dir    = .Column,
			width  = fixed(80),
			height = fixed(24),
		}) {
			vslice: Virtual_Slice
			if ui_virtual_list(ctx, scr, inp, "vtable", 100, Virtual_List_Config{
				width         = fixed(60),
				height        = fixed(10),
				fallback_rows = 10,
				total_cols    = 3,
				focus_flags   = {.Focusable, .Default_Focus},
			}, &vslice) {
			}
			// Explicit directional override on btn_a: pressing Right jumps to btn_c (skipping btn_b)
			_ = leaf(ctx, "btn_a", 10, 1, Box_Config{
				width         = fixed(10),
				height        = fixed(1),
				focus_flags   = {.Focusable},
				focusable     = true,
				nav_overrides = nav_target(.Right, "btn_c"),
			})
			_ = leaf(ctx, "btn_b", 10, 1, Box_Config{
				width       = fixed(10),
				height      = fixed(1),
				focus_flags = {.Focusable},
				focusable   = true,
			})
			_ = leaf(ctx, "btn_c", 10, 1, Box_Config{
				width       = fixed(10),
				height      = fixed(1),
				focus_flags = {.Focusable},
				focusable   = true,
			})
			ui_key_hint_bar(ctx, scr, inp, "hint_bar")
		}
		_ = ui_which_key_overlay(ctx, scr, inp)
		end_layout(ctx)
	}

	inp.clock_ns = 1_000_000_000
	build_frame(&ctx, &scr, &inp)
	resolve_input(&inp, &ctx)

	// 1. Press 'g' at t=1.0s: must latch pending_chord (not fire single.g immediately) and mount Which-Key overlay
	resolve_input(&inp, &ctx, Input_Event(Key_Event{code = .Rune, ch = 'g'}))
	testing.expect(t, inp.pending_chord.active)
	testing.expect(t, inp.pending_chord.has_fallback)
	testing.expect_value(t, inp.triggered_action_id, u64(0))

	build_frame(&ctx, &scr, &inp)
	_, which_key_mounted := ctx.id_map[hash_id("__which_key_overlay__")]
	testing.expect(t, which_key_mounted)

	// 2. Advance clock past 500ms timeout (t=1.6s) with no keys -> single.g fallback fires automatically!
	inp.clock_ns = 1_600_000_000
	resolve_input(&inp, &ctx)
	testing.expect(t, !inp.pending_chord.active)
	testing.expect_value(t, inp.triggered_action_name, "single.g")

	// 3. Numeric repeat prefix `15j` on virtual list steps from row 0 -> row 15
	resolve_input(&inp, &ctx,
		Input_Event(Key_Event{code = .Rune, ch = '1'}),
		Input_Event(Key_Event{code = .Rune, ch = '5'}),
	)
	testing.expect_value(t, inp.repeat_count, i32(15))
	resolve_input(&inp, &ctx, Input_Event(Key_Event{code = .Rune, ch = 'j'}))
	testing.expect_value(t, inp.repeat_count, i32(0))
	testing.expect_value(t, get_selected_row(&inp, "vtable"), i32(15))

	// 3b. Helix suffix count (`j5` and `k10`) & Emacs universal argument (`C-u C-p` = 4 rows up)
	set_keymap_style(&inp, .Helix)
	resolve_input(&inp, &ctx, Input_Event(Key_Event{code = .Rune, ch = 'j'}))
	testing.expect_value(t, get_selected_row(&inp, "vtable"), i32(16))
	resolve_input(&inp, &ctx, Input_Event(Key_Event{code = .Rune, ch = '5'}))
	testing.expect_value(t, inp.suffix_count, i32(5))
	testing.expect_value(t, get_selected_row(&inp, "vtable"), i32(20)) // 15 + 5 = 20

	set_keymap_style(&inp, .Emacs)
	resolve_input(&inp, &ctx, Input_Event(Key_Event{code = .Rune, ch = 'u', mods = {.Ctrl}}))
	testing.expect(t, inp.emacs_universal_arg)
	testing.expect_value(t, inp.repeat_count, i32(4))
	resolve_input(&inp, &ctx, Input_Event(Key_Event{code = .Rune, ch = 'p', mods = {.Ctrl}}))
	testing.expect_value(t, get_selected_row(&inp, "vtable"), i32(16)) // 20 - 4 = 16
	set_keymap_style(&inp, .Vim)

	// 4. Mouse click column hit-testing on 2D virtual table (Feature 2)
	register_virtual_table_col_spans(&inp, "vtable", []Table_Cell_Span{
		{x = 0, w = 10},
		{x = 11, w = 20},
		{x = 32, w = 28},
	})
	v_idx := ctx.id_map[hash_id("vtable")]
	v_rect := ctx.nodes[v_idx].inner_rect
	resolve_input(&inp, &ctx, Input_Event(Mouse_Event{
		x      = v_rect.x + 35,
		y      = v_rect.y + 2,
		action = .Press,
		button = .Left,
	}))
	testing.expect_value(t, get_selected_col(&inp, "vtable"), i32(2))

	// 5. Explicit directional nav_overrides on btn_a -> Right jumps directly to btn_c (Feature 5)
	request_focus(&inp, "btn_a")
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "btn_a"))
	resolve_input(&inp, &ctx, Input_Event(Key_Event{code = .Right}))
	testing.expect(t, is_focused(&inp, "btn_c"))

	free_all(context.temp_allocator)
}

@(test)
test_text_input_selection_clipboard_and_codegen_conflicts :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	defer {
		for _, entry in track.allocation_map {
			testing.expectf(t, false, "Leaked %d bytes at %v", entry.size, entry.location)
		}
		mem.tracking_allocator_destroy(&track)
	}

	// Feature 6: Text input Shift-selection, Ctrl+A, Ctrl+C / Ctrl+X / Ctrl+V & OSC 52 flag
	{
		scr: Screen
		testing.expect_value(t, screen_init(&scr, 60, 10), nil)
		defer screen_destroy(&scr)

		ctx: Layout_Context
		inp: Input_State

		begin_frame(&scr)
		begin_layout(&ctx, 60, 10)
		_ = ui_text_input(&ctx, &scr, &inp, "editor", Text_Input_Config{
			initial_text = "hello world",
			width        = fixed(40),
			height       = fixed(1),
		})
		end_layout(&ctx)
		resolve_input(&inp, &ctx)

		// Shift+Left 5 times selects "world"
		for _ in 0 ..< 5 {
			resolve_input(&inp, &ctx, Input_Event(Key_Event{code = .Left, mods = {.Shift}}))
		}
		testing.expect_value(t, get_selected_text(&inp, "editor"), "world")

		// Ctrl+X cuts "world" into internal clipboard and marks osc52_pending
		resolve_input(&inp, &ctx, Input_Event(Key_Event{code = .Rune, ch = 'x', mods = {.Ctrl}}))
		testing.expect_value(t, get_text(&inp, "editor"), "hello ")
		testing.expect(t, inp.osc52_pending)

		// Home then Ctrl+V pastes "world" at the start -> "worldhello "
		resolve_input(&inp, &ctx,
			Input_Event(Key_Event{code = .Home}),
			Input_Event(Key_Event{code = .Rune, ch = 'v', mods = {.Ctrl}}),
		)
		testing.expect_value(t, get_text(&inp, "editor"), "worldhello ")

		// Ctrl+A selects all, typing '!' replaces entire selection
		resolve_input(&inp, &ctx,
			Input_Event(Key_Event{code = .Rune, ch = 'a', mods = {.Ctrl}}),
			Input_Event(Key_Event{code = .Rune, ch = '!'}),
		)
		testing.expect_value(t, get_text(&inp, "editor"), "!")
	}

	// Fix 6, Fix 7 & Feature 4: Quote-aware commas, compile-time FNV-1a switch emission, and duplicate chord diagnostics
	{
		valid_src := `package sample
import "../../bifrost"

App :: struct {}

@(ui_action="id=app.save,key=<comma>,desc='Save, close, and exit'")
on_save :: proc(self: ^App) {}
`
		diags := make([dynamic]codegen.Codegen_Diagnostic)
		defer codegen.destroy_diagnostics(&diags)

		gen_code, ok := codegen.generate_from_source(valid_src, "valid.odin", &diags)
		defer delete(gen_code)
		testing.expect(t, ok)
		testing.expect_value(t, len(diags), 0)
		testing.expect(t, strings.contains(gen_code, `desc            = "Save, close, and exit"`))
		testing.expect(t, strings.contains(gen_code, "switch inp.triggered_action_id {"))

		conflict_src := `package sample
import "../../bifrost"

@(ui_actions)
Dup_Actions :: struct {
	first:  int ` + "`" + `bifrost:"action=act.one,chord=g g,scope=board"` + "`" + `,
	second: int ` + "`" + `bifrost:"action=act.two,chord=g g,scope=board"` + "`" + `,
}
`
		dup_diags := make([dynamic]codegen.Codegen_Diagnostic)
		defer codegen.destroy_diagnostics(&dup_diags)
		bad_code, bad_ok := codegen.generate_from_source(conflict_src, "conflict.odin", &dup_diags)
		defer delete(bad_code)
		testing.expect(t, !bad_ok)
		testing.expect(t, len(dup_diags) > 0)
	}

	free_all(context.temp_allocator)
}

@(test)
test_rebind_persists_across_style_switch_bubbled_repeat_and_coord_chord_timeout :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	defer {
		for _, entry in track.allocation_map {
			testing.expectf(t, false, "Leaked %d bytes at %v", entry.size, entry.location)
		}
		mem.tracking_allocator_destroy(&track)
	}

	scr: Screen
	testing.expect_value(t, screen_init(&scr, 90, 20), nil)
	defer screen_destroy(&scr)

	ctx: Layout_Context
	inp: Input_State

	// 1. Register an action with vim/helix/emacs chords, rebind it at runtime, and verify set_keymap_style preserves the user override
	_ = register_action_spec(&inp, nil, Action_Spec{
		action_name = "bench.bookmark",
		chord_vim   = "m",
		chord_helix = "<Space> b",
		chord_emacs = "<C-x> b",
		desc_vim    = "Bookmark (m)",
		desc_helix  = "Bookmark (SPC b)",
	})
	testing.expect(t, rebind_action_chord(&inp, "bench.bookmark", "<C-b>"))
	set_keymap_style(&inp, .Helix)
	testing.expect_value(t, inp.action_specs[0].chord_spec, "<C-b>")
	testing.expect_value(t, inp.action_specs[0].desc, "Bookmark (SPC b)")
	set_keymap_style(&inp, .Vim)

	// 2. Register a raw scoped binding (without Action_Spec), rebind it, and verify scope_id is preserved
	_ = bind_chord(&inp, "x", "col.raw_action", .Scope_Only, "col_0")
	testing.expect(t, rebind_action_chord(&inp, "col.raw_action", "z"))

	// 3. Build a 3-column board and verify `2l` on `card_0` inside `col_0` bubbles with repeat_count=2 to land in `col_2`!
	build_three_cols :: proc(ctx: ^Layout_Context, scr: ^Screen, inp: ^Input_State) {
		begin_frame(scr)
		begin_layout(ctx, 90, 20)
		if ui_scope(ctx, scr, "board", {dir = .Row, width = fixed(90), height = fixed(20), gap = 1}) {
			if ui_scope(ctx, scr, "col_0", {dir = .Column, width = fixed(28), height = fixed(18)}) {
				ui_button(ctx, scr, "card_0", {label = "C0", focus_flags = {.Default_Focus}})
			}
			if ui_scope(ctx, scr, "col_1", {dir = .Column, width = fixed(28), height = fixed(18)}) {
				ui_button(ctx, scr, "card_1", {label = "C1", focus_flags = {.Default_Focus}})
			}
			if ui_scope(ctx, scr, "col_2", {dir = .Column, width = fixed(28), height = fixed(18)}) {
				ui_button(ctx, scr, "card_2", {label = "C2", focus_flags = {.Default_Focus}})
			}
			ui_text_input(ctx, scr, inp, "sel_box", {initial_text = "abcd", width = fixed(12), height = fixed(1)})
		}
		end_layout(ctx)
	}

	build_three_cols(&ctx, &scr, &inp)
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "card_0"))

	// Rebound raw `.Scope_Only` binding on `z` fires inside `col_0`
	resolve_input(&inp, &ctx, Input_Event(Key_Event{code = .Rune, ch = 'z'}))
	testing.expect(t, was_action_triggered(&inp, "col.raw_action"))

	// `2l` on `card_0` bubbles up to `col_0` with repeat_count=2 and jumps directly to `card_2` in `col_2`
	resolve_input(
		&inp,
		&ctx,
		Input_Event(Key_Event{code = .Rune, ch = '2'}),
		Input_Event(Key_Event{code = .Rune, ch = 'l'}),
	)
	testing.expect(t, is_focused(&inp, "card_2"))

	// `request_focus` targeting non-Focusable `.Focus_Scope` `"col_1"` resolves to `"card_1"`
	request_focus(&inp, "col_1")
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "card_1"))

	// 4. Visual selection on `sel_box` populates `paint.spans` with `.Reverse` highlight in `apply_input_highlights`
	request_focus(&inp, "sel_box")
	resolve_input(&inp, &ctx)
	resolve_input(&inp, &ctx, Input_Event(Key_Event{code = .Left, mods = {.Shift}}))
	apply_input_highlights(&scr, &ctx, &inp)
	sel_paint := scr.paints[hash_id("sel_box")]
	testing.expect(t, len(sel_paint.spans) >= 2)

	// 5. UI_Coordinator_State pending-chord timeout on UI_Msg_Frame_Tick fires fallback action & flushes frame
	coord: UI_Coordinator_State
	testing.expect(t, ui_coordinator_init(&coord, 80, 20, nil))
	defer ui_coordinator_destroy(&coord)
	coord.input.chord_timeout_ns = 500_000_000
	_ = register_action_spec(&coord.input, nil, Action_Spec{action_name = "single.g", chord_spec = "g"})
	_ = register_action_spec(&coord.input, nil, Action_Spec{action_name = "double.gg", chord_spec = "g g"})

	fired_fallback := false
	_ = on_ui_action(&coord, "single.g", proc(_: ^UI_Coordinator_State, _: string, ud: rawptr) {
		(^bool)(ud)^ = true
	}, &fired_fallback)

	_ = ui_reduce_single_msg(&coord, UI_Msg_Frame_Tick{tick_ns = 1_000_000_000})
	ui_coordinator_flush_frame(&coord)
	_ = ui_reduce_single_msg(&coord, UI_Msg_Key{code = .Rune, ch = 'g'})
	ui_coordinator_flush_frame(&coord)
	testing.expect(t, coord.input.pending_chord.active)

	_ = ui_reduce_single_msg(&coord, UI_Msg_Frame_Tick{tick_ns = 1_600_000_000})
	testing.expect(t, coord.dirty)
	ui_coordinator_flush_frame(&coord)
	testing.expect(t, !coord.input.pending_chord.active)
	testing.expect(t, fired_fallback)

	// 6. Deterministic single-thread invariant: reader operations on Xitdb_Shared_Handle must use a
	// stack-local Core view and NEVER mutate `shared_db.db.core`'s seek position (`pos`).
	core_mem := xitdb.core_memory_init(context.allocator)
	defer _ = xitdb.core_destroy(&core_mem)
	db_inst, db_err := xitdb.database_init(&core_mem)
	testing.expect_value(t, db_err, nil)
	shared_db := Xitdb_Shared_Handle{db = &db_inst}

	w_actor: actor.Actor(Xitdb_Worker_State, Xitdb_Worker_Msg)
	w_actor.state = Xitdb_Worker_State{shared = &shared_db}
	msg_b0 := Xitdb_Worker_Msg(Worker_Msg_Commit_Batch{map_name = "$orders", key_prefix = "ord", start_id = 1, count = 4, sorted = true})
	msg_b1 := Xitdb_Worker_Msg(Worker_Msg_Commit_Batch{map_name = "$orders", key_prefix = "ord", start_id = 5, count = 4, sorted = true})
	xitdb_worker_receive(nil, &w_actor, &msg_b0)
	xitdb_worker_receive(nil, &w_actor, &msg_b1)
	coord.shared_db = &shared_db
	coord.active_moment_idx = -1
	ui_set_active_collection(&coord, "$orders")
	testing.expect(t, save_ui_workspace_to_xitdb(&shared_db, &coord, "ws_test"))

	// Pin sentinel seek position on the shared Core_Memory and verify no reader call mutates it
	sentinel_pos :: i64(777)
	_ = xitdb.core_seek_to(&core_mem, sentinel_pos)

	slice := ui_coordinator_slice_viewport(&coord, "records_pane", 10)
	testing.expect_value(t, len(slice.rows), 8)
	pos_after_slice, _ := xitdb.core_position(&core_mem)
	testing.expect_value(t, pos_after_slice, sentinel_pos)

	testing.expect(t, load_ui_workspace_from_xitdb(&shared_db, &coord, "ws_test"))
	pos_after_load, _ := xitdb.core_position(&core_mem)
	testing.expect_value(t, pos_after_load, sentinel_pos)

	msg_diff := Xitdb_Worker_Msg(Worker_Msg_Diff_Moments{moment_a = 0, moment_b = 1})
	xitdb_worker_receive(nil, &w_actor, &msg_diff)
	testing.expect_value(t, w_actor.state.diffs_done, 1)
	pos_after_diff, _ := xitdb.core_position(&core_mem)
	testing.expect_value(t, pos_after_diff, sentinel_pos)

	msg_dlog := Xitdb_Worker_Msg(Worker_Msg_Run_Datalog{query_source = "find ?k, ?v where $orders[?k] = ?v"})
	xitdb_worker_receive(nil, &w_actor, &msg_dlog)
	testing.expect_value(t, w_actor.state.queries_done, 1)
	pos_after_dlog, _ := xitdb.core_position(&core_mem)
	testing.expect_value(t, pos_after_dlog, sentinel_pos)

	free_all(context.temp_allocator)
}

@(test)
test_scroll_retention_across_unmounted_gens_kill_ring_paste_and_cross_scope_nav_override :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	defer {
		for _, entry in track.allocation_map {
			testing.expectf(t, false, "Leaked %d bytes at %v", entry.size, entry.location)
		}
		mem.tracking_allocator_destroy(&track)
	}
	defer free_all(context.temp_allocator)

	scr: Screen
	testing.expect_value(t, screen_init(&scr, 80, 20), nil)
	defer screen_destroy(&scr)

	ctx: Layout_Context
	inp: Input_State

	// 1. Materialized scrollable container retains `slot.offset` across > 2 unmounted layout generations
	build_tab :: proc(ctx: ^Layout_Context, scr: ^Screen, mount_scroll_pane: bool) {
		begin_frame(scr)
		begin_layout(ctx, 80, 20)
		if ui_scope(ctx, scr, "root", {dir = .Column, width = fixed(80), height = fixed(20)}) {
			if mount_scroll_pane {
				if container(ctx, "mat_scroll", {dir = .Column, width = fixed(40), height = fixed(4), scrollable = true}) {
					for i := 0; i < 12; i += 1 {
						leaf(ctx, fmt.tprintf("item_%d", i), 20, 1, {width = fixed(20), height = fixed(1)})
					}
				}
			} else {
				leaf(ctx, "other_tab", 20, 4, {width = fixed(20), height = fixed(4), focus_flags = {.Focusable}})
			}
		}
		end_layout(ctx)
	}

	build_tab(&ctx, &scr, true)
	resolve_input(&inp, &ctx)
	scroll_slot := get_scroll_slot(&inp, hash_id("mat_scroll"))
	scroll_slot.offset = 5

	build_tab(&ctx, &scr, true)
	resolve_input(&inp, &ctx)
	testing.expect_value(t, get_scroll_offset(&inp, "mat_scroll"), i32(5))

	// Unmount `mat_scroll` for 5 consecutive layout generations (exceeding the old `<= 2` threshold)
	for _ in 0 ..< 5 {
		build_tab(&ctx, &scr, false)
		resolve_input(&inp, &ctx)
	}

	// Remount `mat_scroll` and verify `slot.offset == 5` is preserved
	build_tab(&ctx, &scr, true)
	resolve_input(&inp, &ctx)
	testing.expect_value(t, get_scroll_offset(&inp, "mat_scroll"), i32(5))

	// 2. Readline `Ctrl+W` and `Ctrl+U` populate `inp.clipboard_buf` so `Ctrl+Y` yanks the killed span;
	// and `Paste_Event` with >256B multi-byte UTF-8 truncates cleanly on a rune boundary.
	begin_frame(&scr)
	begin_layout(&ctx, 80, 20)
	_ = ui_text_input(&ctx, &scr, &inp, "rl_input", {
		initial_text = "alpha beta gamma",
		width        = fixed(50),
		height       = fixed(1),
	})
	end_layout(&ctx)
	request_focus(&inp, "rl_input")
	resolve_input(&inp, &ctx)

	// Ctrl+W kills "gamma" into clipboard_buf; Ctrl+Y yanks "gamma" back
	inp.osc52_pending = false
	resolve_input(&inp, &ctx, Input_Event(Key_Event{code = .Rune, ch = 'w', mods = {.Ctrl}}))
	testing.expect_value(t, get_text(&inp, "rl_input"), "alpha beta ")
	testing.expect_value(t, string(inp.clipboard_buf[:inp.clipboard_len]), "gamma")
	testing.expect(t, inp.osc52_pending)

	resolve_input(&inp, &ctx, Input_Event(Key_Event{code = .Rune, ch = 'y', mods = {.Ctrl}}))
	testing.expect_value(t, get_text(&inp, "rl_input"), "alpha beta gamma")

	// Ctrl+U kills entire prefix "alpha beta gamma" into clipboard_buf; Ctrl+Y yanks it back
	inp.osc52_pending = false
	resolve_input(&inp, &ctx, Input_Event(Key_Event{code = .Rune, ch = 'u', mods = {.Ctrl}}))
	testing.expect_value(t, get_text(&inp, "rl_input"), "")
	testing.expect_value(t, string(inp.clipboard_buf[:inp.clipboard_len]), "alpha beta gamma")
	testing.expect(t, inp.osc52_pending)

	resolve_input(&inp, &ctx, Input_Event(Key_Event{code = .Rune, ch = 'y', mods = {.Ctrl}}))
	testing.expect_value(t, get_text(&inp, "rl_input"), "alpha beta gamma")

	// Paste_Event with 254 ASCII bytes + 4-byte emoji ('🚀') must truncate to 254 bytes (valid UTF-8) in 256-byte clipboard_buf
	long_paste_b := strings.builder_make(0, 270, context.temp_allocator)
	for _ in 0 ..< 254 {
		strings.write_byte(&long_paste_b, 'x')
	}
	strings.write_string(&long_paste_b, "🚀tail")
	resolve_input(&inp, &ctx, Input_Event(Paste_Event{text = strings.to_string(long_paste_b)}))
	testing.expect_value(t, inp.clipboard_len, 254)
	testing.expect(t, utf8.valid_string(string(inp.clipboard_buf[:inp.clipboard_len])))

	// 3. Cross-scope `nav_overrides` jump from a tip widget resets sticky `preferred_nav_pos`,
	// and `spec_matches_node_scope` matches root-seeded `local_id` scopes.
	_ = register_action_spec(&inp, nil, Action_Spec{
		action_name = "local_scope.act",
		chord_spec  = "x",
		scope       = "scope_b",
		policy      = .Scope_Only,
	})

	begin_frame(&scr)
	begin_layout(&ctx, 80, 20)
	if container(&ctx, "scope_a", {dir = .Column, width = fixed(30), height = fixed(10), focus_flags = {.Focus_Scope}}) {
		leaf(&ctx, "btn_in_a", 10, 1, {
			width         = fixed(10),
			height        = fixed(1),
			focus_flags   = {.Focusable, .Default_Focus},
			nav_overrides = nav_target(.Right, "btn_in_b"),
		})
	}
	if container(&ctx, "scope_b", {dir = .Column, width = fixed(30), height = fixed(10), focus_flags = {.Focus_Scope}, local_id = true}) {
		leaf(&ctx, "btn_in_b", 10, 1, {
			width       = fixed(10),
			height      = fixed(1),
			focus_flags = {.Focusable, .Default_Focus},
		})
	}
	ui_key_hint_bar(&ctx, &scr, &inp, "scope_hint_bar")
	end_layout(&ctx)

	request_focus(&inp, "btn_in_a")
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "btn_in_a"))

	// Seed sticky orthogonal bias, then press Right to trigger cross-scope `nav_overrides` -> `btn_in_b`
	inp.has_preferred_x   = true
	inp.has_preferred_y   = true
	inp.preferred_nav_pos = {42, 99}
	resolve_input(&inp, &ctx, Input_Event(Key_Event{code = .Right}))
	testing.expect(t, is_focused(&inp, "btn_in_b"))
	testing.expect_value(t, inp.has_preferred_x, false)
	testing.expect_value(t, inp.has_preferred_y, false)

	// Verify `spec_matches_node_scope` matches `scope_b` even when `node.id` is cleared (relying on `hash_local_id(0, "scope_b")`)
	scope_b_idx := ctx.id_map[hash_id("scope_b")]
	anon_node := ctx.nodes[scope_b_idx]
	anon_node.id = ""
	testing.expect(t, spec_matches_node_scope(&inp, anon_node, inp.action_specs[inp.action_spec_cnt - 1]))
}
