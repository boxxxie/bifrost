package bifrost

import "core:mem"
import "core:strings"
import "core:testing"

@(test)
test_parse_key_chord_single_modifiers_alternates_sequences_and_errors :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	defer {
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
		mem.tracking_allocator_destroy(&track)
	}

	// 1. Single runes & case sensitivity
	c_n, ok_n := parse_key_chord("n")
	testing.expect(t, ok_n)
	testing.expect_value(t, c_n.alt_count, u8(1))
	testing.expect_value(t, c_n.alts[0].len, u8(1))
	testing.expect_value(t, c_n.alts[0].steps[0].code, Key_Code.Rune)
	testing.expect_value(t, c_n.alts[0].steps[0].ch, 'n')
	testing.expect_value(t, c_n.alts[0].steps[0].mods, Mod_Flags{})

	c_H, ok_H := parse_key_chord("H")
	testing.expect(t, ok_H)
	testing.expect_value(t, c_H.alts[0].steps[0].code, Key_Code.Rune)
	testing.expect_value(t, c_H.alts[0].steps[0].ch, 'H')
	testing.expect(t, .Shift in c_H.alts[0].steps[0].mods)

	// 2. Named special keys & modifiers
	c_ent, ok_ent := parse_key_chord("<Enter>")
	testing.expect(t, ok_ent)
	testing.expect_value(t, c_ent.alts[0].steps[0].code, Key_Code.Enter)

	c_esc, ok_esc := parse_key_chord("<Esc>")
	testing.expect(t, ok_esc)
	testing.expect_value(t, c_esc.alts[0].steps[0].code, Key_Code.Escape)

	c_sf6, ok_sf6 := parse_key_chord("<S-F6>")
	testing.expect(t, ok_sf6)
	testing.expect_value(t, c_sf6.alts[0].steps[0].code, Key_Code.F6)
	testing.expect_value(t, c_sf6.alts[0].steps[0].mods, Mod_Flags{.Shift})

	c_cp, ok_cp := parse_key_chord("<C-p>")
	testing.expect(t, ok_cp)
	testing.expect_value(t, c_cp.alts[0].steps[0].code, Key_Code.Rune)
	testing.expect_value(t, c_cp.alts[0].steps[0].ch, 'p')
	testing.expect_value(t, c_cp.alts[0].steps[0].mods, Mod_Flags{.Ctrl})

	c_mx, ok_mx := parse_key_chord("<M-x>")
	testing.expect(t, ok_mx)
	testing.expect_value(t, c_mx.alts[0].steps[0].code, Key_Code.Rune)
	testing.expect_value(t, c_mx.alts[0].steps[0].ch, 'x')
	testing.expect_value(t, c_mx.alts[0].steps[0].mods, Mod_Flags{.Alt})

	// 3. Alternation (`|`) & 2-step Vim/TUI sequences
	c_quit, ok_quit := parse_key_chord("q|<C-q>|<C-c>")
	testing.expect(t, ok_quit)
	testing.expect_value(t, c_quit.alt_count, u8(3))
	testing.expect_value(t, c_quit.alts[0].steps[0].ch, 'q')
	testing.expect_value(t, c_quit.alts[1].steps[0].mods, Mod_Flags{.Ctrl})
	testing.expect_value(t, c_quit.alts[2].steps[0].ch, 'c')

	c_gg, ok_gg := parse_key_chord("g g")
	testing.expect(t, ok_gg)
	testing.expect_value(t, c_gg.alt_count, u8(1))
	testing.expect_value(t, c_gg.alts[0].len, u8(2))
	testing.expect_value(t, c_gg.alts[0].steps[0].ch, 'g')
	testing.expect_value(t, c_gg.alts[0].steps[1].ch, 'g')

	c_cwl, ok_cwl := parse_key_chord("<C-w> l|<Space> f")
	testing.expect(t, ok_cwl)
	testing.expect_value(t, c_cwl.alt_count, u8(2))
	testing.expect_value(t, c_cwl.alts[0].len, u8(2))
	testing.expect_value(t, c_cwl.alts[0].steps[0].mods, Mod_Flags{.Ctrl})
	testing.expect_value(t, c_cwl.alts[0].steps[0].ch, 'w')
	testing.expect_value(t, c_cwl.alts[0].steps[1].ch, 'l')
	testing.expect_value(t, c_cwl.alts[1].steps[0].code, Key_Code.Space)
	testing.expect_value(t, c_cwl.alts[1].steps[1].ch, 'f')

	// 4. Malformed chord specs are deterministically rejected
	bad_specs := [?]string{"", "   ", "<>", "<C->", "<BadKey>", "g g g", "q|", "|q", "Ctrl+P", "<C-p"}
	for bad in bad_specs {
		_, ok_bad := parse_key_chord(bad)
		testing.expect(t, !ok_bad, bad)
	}
}

@(test)
test_two_step_pending_chord_matching_shift_immunity_and_escape_cancel :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ctx: Layout_Context
	inp: Input_State

	testing.expect(t, bind_chord(&inp, "g g", "nav.top"))
	testing.expect(t, bind_chord(&inp, "<C-w> l", "win.right"))
	testing.expect(t, bind_chord(&inp, "<C-w> L", "win.move_right"))
	testing.expect(t, bind_chord(&inp, "q|<C-q>", "app.quit"))

	build_tree :: proc(ctx: ^Layout_Context) {
		begin_layout(ctx, 80, 20, context.temp_allocator)
		if container(ctx, "root", {dir = .Column, width = fixed(80), height = fixed(20), focus_flags = {.Focus_Scope}}) {
			if container(ctx, "col_todo", {dir = .Column, width = fixed(40), height = fixed(18), focus_flags = {.Focus_Scope, .Focusable}}) {
				leaf(ctx, "card_1", 20, 3, {width = fixed(20), height = fixed(3), focus_flags = {.Focusable, .Default_Focus}})
			}
		}
		end_layout(ctx)
	}

	build_tree(&ctx)
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "card_1"))

	// 1. Step 1 of "g g" latches pending_chord; Escape cancels cleanly WITHOUT drilling focus up to col_todo!
	build_tree(&ctx)
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'g'})
	testing.expect(t, inp.pending_chord.active)
	testing.expect_value(t, pending_chord_prefix(&inp), "g")
	testing.expect(t, !was_action_triggered(&inp, "nav.top"))

	build_tree(&ctx)
	resolve_input(&inp, &ctx, Key_Event{code = .Escape})
	testing.expect(t, !inp.pending_chord.active)
	testing.expect(t, is_focused(&inp, "card_1"))

	// 2. Unmatched second key ('x') cancels pending_chord cleanly without firing
	build_tree(&ctx)
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'g'})
	testing.expect(t, inp.pending_chord.active)

	build_tree(&ctx)
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'x'})
	testing.expect(t, !inp.pending_chord.active)
	testing.expect_value(t, inp.triggered_action_id, u64(0))

	// 3. Valid "g g" across two frames triggers "nav.top"
	build_tree(&ctx)
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'g'})
	build_tree(&ctx)
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'g'})
	testing.expect(t, !inp.pending_chord.active)
	testing.expect(t, was_action_triggered(&inp, "nav.top"))

	// 4. "<C-w> L" with an intermediate Left_Shift bare modifier press does NOT cancel pending_chord!
	build_tree(&ctx)
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'w', mods = {.Ctrl}})
	testing.expect(t, inp.pending_chord.active)

	build_tree(&ctx)
	resolve_input(&inp, &ctx, Key_Event{code = .Left_Shift, mods = {.Shift}})
	testing.expect(t, inp.pending_chord.active)

	build_tree(&ctx)
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'L', mods = {.Shift}})
	testing.expect(t, !inp.pending_chord.active)
	testing.expect(t, was_action_triggered(&inp, "win.move_right"))
}

@(test)
test_splitter_resize_transient_submode_and_ui_scope_wrapper :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	alloc := mem.tracking_allocator(&track)
	defer {
		free_all(context.temp_allocator)
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
		mem.tracking_allocator_destroy(&track)
	}

	scr: Screen
	testing.expect_value(t, screen_init(&scr, 80, 20, alloc), nil)
	defer screen_destroy(&scr)

	ctx: Layout_Context
	inp: Input_State

	step_split_ui :: proc(ctx: ^Layout_Context, scr: ^Screen, inp: ^Input_State, evs: ..Input_Event) {
		free_all(context.temp_allocator)
		begin_frame(scr, {}, context.temp_allocator)
		begin_layout(ctx, 80, 20, context.temp_allocator)
		left_w := get_split_size(inp, "main_split", default_size = 24, min_size = 10, max_size = 50)
		if ui_scope(ctx, scr, "root", {dir = .Row, width = fixed(80), height = fixed(20)}) {
			if ui_scope(ctx, scr, "left_pane", {dir = .Column, width = fixed(left_w), height = grow(1)}) {
				ui_button(ctx, scr, "btn_left", {label = "Left"})
			}
			ui_splitter(ctx, scr, inp, "main_split", {
				dir          = .Row,
				default_size = 24,
				min_size     = 10,
				max_size     = 50,
				step         = 3,
			})
			if ui_scope(ctx, scr, "right_pane", {dir = .Column, width = grow(1), height = grow(1)}) {
				ui_button(ctx, scr, "btn_right", {label = "Right"})
			}
		}
		end_layout(ctx)
		resolve_input(inp, ctx, ..evs)
		apply_input_highlights(scr, ctx, inp)
		render_layout(scr, ctx, context.temp_allocator)
	}

	// 1. Focus splitter in default .Navigate (0) submode -> 'l' spatially navigates East to btn_right instead of trapping!
	inp.wants_focus_id = hash_id("main_split")
	step_split_ui(&ctx, &scr, &inp)
	testing.expect(t, is_focused(&inp, "main_split"))
	testing.expect_value(t, get_scope_submode_typed(&inp, "main_split", Splitter_Submode), Splitter_Submode.Navigate)

	step_split_ui(&ctx, &scr, &inp, Key_Event{code = .Rune, ch = 'l'})
	testing.expect(t, is_focused(&inp, "btn_right"))
	testing.expect_value(t, get_split_size(&inp, "main_split"), i32(24))

	// 2. Focus splitter and press Enter -> enters .Resize (1) submode!
	inp.wants_focus_id = hash_id("main_split")
	step_split_ui(&ctx, &scr, &inp)
	step_split_ui(&ctx, &scr, &inp, Key_Event{code = .Enter})
	testing.expect_value(t, get_scope_submode_typed(&inp, "main_split", Splitter_Submode), Splitter_Submode.Resize)

	// 3. In .Resize submode, 'l' and Right grow width (+3 each), 'h' shrinks (-3), '=' resets to 24
	step_split_ui(&ctx, &scr, &inp, Key_Event{code = .Rune, ch = 'l'})
	testing.expect_value(t, get_split_size(&inp, "main_split"), i32(27))
	step_split_ui(&ctx, &scr, &inp, Key_Event{code = .Right})
	testing.expect_value(t, get_split_size(&inp, "main_split"), i32(30))
	step_split_ui(&ctx, &scr, &inp, Key_Event{code = .Rune, ch = 'h'})
	testing.expect_value(t, get_split_size(&inp, "main_split"), i32(27))
	step_split_ui(&ctx, &scr, &inp, Key_Event{code = .Rune, ch = '='})
	testing.expect_value(t, get_split_size(&inp, "main_split"), i32(24))

	// 4. Escape exits .Resize back to .Navigate while keeping focus on main_split; 'h' now navigates West to btn_left
	step_split_ui(&ctx, &scr, &inp, Key_Event{code = .Escape})
	testing.expect_value(t, get_scope_submode_typed(&inp, "main_split", Splitter_Submode), Splitter_Submode.Navigate)
	testing.expect(t, is_focused(&inp, "main_split"))

	step_split_ui(&ctx, &scr, &inp, Key_Event{code = .Rune, ch = 'h'})
	testing.expect(t, is_focused(&inp, "btn_left"))
}

Demo_Action :: enum u8 {
	None = 0,
	New_Task,
	Move_Left,
	Move_Right,
	Jump_Top,
	Quit,
}

Demo_Actions :: struct {
	New_Task:   Demo_Action `bifrost:"key=n, id=task.new, desc=New, label=Create New Task, category=Board"`,
	Move_Left:  Demo_Action `bifrost:"key=H, id=task.move_left, scope=col_*, group=stage, group_desc=Move Stage, desc=Move Left, category=Board"`,
	Move_Right: Demo_Action `bifrost:"key=L, id=task.move_right, scope=col_*, group=stage, group_desc=Move Stage, desc=Move Right, category=Board"`,
	Jump_Top:   Demo_Action `bifrost:"key=g g, id=nav.top, desc=Top, label=Jump to Top Card, category=Navigation"`,
	Quit:       Demo_Action `bifrost:"key=q|<C-q>, id=app.quit, desc=Quit, label=Quit Application, category=System"`,
}

@(test)
test_reflect_struct_tags_guards_availability_and_command_palette :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	defer {
		free_all(context.temp_allocator)
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
		mem.tracking_allocator_destroy(&track)
	}

	inp: Input_State
	cp: Command_Palette
	command_palette_init(&cp, &inp)

	// Zero-allocation core:reflect registration into Input_State + Command_Palette
	ok := register_actions_struct(&inp, &cp, Demo_Actions{})
	testing.expect(t, ok)
	testing.expect_value(t, cp.command_cnt, 5)
	testing.expect_value(t, lookup_action_shortcut(&inp, "nav.top"), "g g")

	// Outer fallback binding on 'H' to verify Disabled_Swallow vs Disabled_Bubble
	bind_chord(&inp, "H", "outer.fallback_H")

	Guard_Ctx :: struct {
		mode: Guard_Result,
	}
	gctx := Guard_Ctx{mode = .Disabled_Swallow}
	set_action_guard(&inp, "task.move_left", proc(action_id: u64, userdata: rawptr) -> (Guard_Result, string) {
		_ = action_id
		gc := (^Guard_Ctx)(userdata)
		return gc.mode, "Already at leftmost stage"
	}, &gctx)

	ctx: Layout_Context
	build_cols :: proc(ctx: ^Layout_Context) {
		begin_layout(ctx, 80, 20, context.temp_allocator)
		if container(ctx, "root", {dir = .Row, width = fixed(80), height = fixed(20), focus_flags = {.Focus_Scope}}) {
			if container(ctx, "col_backlog", {dir = .Column, width = fixed(30), height = fixed(20), focus_flags = {.Focus_Scope, .Focusable}}) {
				leaf(ctx, "card_1", 20, 3, {width = fixed(20), height = fixed(3), focus_flags = {.Focusable, .Default_Focus}})
			}
		}
		end_layout(ctx)
	}

	// 1. Disabled_Swallow consumes 'H' at col_* and records disabled reason without bubbling to outer.fallback_H
	build_cols(&ctx)
	resolve_input(&inp, &ctx)
	build_cols(&ctx)
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'H', mods = {.Shift}})
	testing.expect_value(t, inp.triggered_action_id, u64(0))
	testing.expect_value(t, inp.last_disabled_reason, "Already at leftmost stage")

	// 2. Disabled_Bubble skips col_* 'H' and lets outer.fallback_H fire
	gctx.mode = .Disabled_Bubble
	build_cols(&ctx)
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'H', mods = {.Shift}})
	testing.expect(t, was_action_triggered(&inp, "outer.fallback_H"))

	// 3. Enabled fires typed Demo_Action.Move_Left via wildcard scope=col_*!
	gctx.mode = .Enabled
	build_cols(&ctx)
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'H', mods = {.Shift}})
	testing.expect(t, was_action_triggered(&inp, Demo_Action.Move_Left))
	act, act_ok := triggered_action(&inp, Demo_Action)
	testing.expect(t, act_ok)
	testing.expect_value(t, act, Demo_Action.Move_Left)
}

@(test)
test_focus_breadcrumb_and_key_hint_bar_dedup_grouping_and_truncation :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	alloc := mem.tracking_allocator(&track)
	defer {
		free_all(context.temp_allocator)
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
		mem.tracking_allocator_destroy(&track)
	}

	scr: Screen
	testing.expect_value(t, screen_init(&scr, 100, 10, alloc), nil)
	defer screen_destroy(&scr)

	ctx: Layout_Context
	inp: Input_State

	// Register compact group ("hjkl: Navigate"), slash group ("[/]: Time-Travel"), shadowed key ('m'),
	// dimmed action ('!'), hidden action ('x'), and 2-step chord ("g g")
	register_action_spec(&inp, nil, Action_Spec{action_name = "nav.h", chord_spec = "h", group = "nav", group_desc = "Navigate", compact = true, has_compact = true, desc = "Left", show_in_bar = true})
	register_action_spec(&inp, nil, Action_Spec{action_name = "nav.j", chord_spec = "j", group = "nav", group_desc = "Navigate", compact = true, has_compact = true, desc = "Down", show_in_bar = true})
	register_action_spec(&inp, nil, Action_Spec{action_name = "nav.k", chord_spec = "k", group = "nav", group_desc = "Navigate", compact = true, has_compact = true, desc = "Up", show_in_bar = true})
	register_action_spec(&inp, nil, Action_Spec{action_name = "nav.l", chord_spec = "l", group = "nav", group_desc = "Navigate", compact = true, has_compact = true, desc = "Right", show_in_bar = true})

	register_action_spec(&inp, nil, Action_Spec{action_name = "hist.undo", chord_spec = "[", group = "time", group_desc = "Time-Travel", desc = "Undo", show_in_bar = true})
	register_action_spec(&inp, nil, Action_Spec{action_name = "hist.redo", chord_spec = "]", group = "time", group_desc = "Time-Travel", desc = "Redo", show_in_bar = true})

	register_action_spec(&inp, nil, Action_Spec{action_name = "doing.block", chord_spec = "m", scope = "col_doing", desc = "Mark Blocked", show_in_bar = true})
	register_action_spec(&inp, nil, Action_Spec{action_name = "root.menu", chord_spec = "m", desc = "Global Menu", show_in_bar = true})

	register_action_spec(&inp, nil, Action_Spec{action_name = "task.prio", chord_spec = "!", desc = "Priority", availability = .Disabled_Dimmed, show_in_bar = true})
	register_action_spec(&inp, nil, Action_Spec{action_name = "admin.secret", chord_spec = "x", desc = "Secret", availability = .Hidden, show_in_bar = true})
	register_action_spec(&inp, nil, Action_Spec{action_name = "nav.top", chord_spec = "g g", desc = "Jump Top", show_in_bar = true})

	render_bars :: proc(ctx: ^Layout_Context, scr: ^Screen, inp: ^Input_State, bar_w: i32, evs: ..Input_Event) {
		free_all(context.temp_allocator)
		begin_frame(scr, {}, context.temp_allocator)
		begin_layout(ctx, 100, 10, context.temp_allocator)
		if ui_scope(ctx, scr, "root", {dir = .Column, width = fixed(bar_w), height = fixed(10)}) {
			ui_focus_breadcrumb_bar(ctx, scr, inp, "crumb_bar")
			if ui_scope(ctx, scr, "board", {dir = .Row, width = grow(1), height = fixed(6)}) {
				if ui_scope(ctx, scr, "col_doing", {dir = .Column, width = grow(1), height = grow(1), focus_flags = {.Focusable}}) {
					leaf(ctx, "card_3", 20, 3, {width = fixed(20), height = fixed(3), focus_flags = {.Focusable, .Default_Focus}})
				}
			}
			ui_key_hint_bar(ctx, scr, inp, "hint_bar")
		}
		end_layout(ctx)
		resolve_input(inp, ctx, ..evs)
		apply_input_highlights(scr, ctx, inp)
		render_layout(scr, ctx, context.temp_allocator)
	}

	// 1. Wide bar (100 cols): verifies breadcrumb path, compact group merging, shadowed 'm' dedup, and Hidden exclusion
	render_bars(&ctx, &scr, &inp, 100)
	crumb_paint := scr.paints[hash_id("crumb_bar")]
	hint_paint  := scr.paints[hash_id("hint_bar")]

	testing.expect(t, strings.contains(crumb_paint.text, "root -> board -> col_doing -> card_3"))
	testing.expect(t, strings.contains(hint_paint.text, "m: Mark Blocked"))
	testing.expect(t, !strings.contains(hint_paint.text, "Global Menu"))
	testing.expect(t, strings.contains(hint_paint.text, "hjkl: Navigate"))
	testing.expect(t, strings.contains(hint_paint.text, "[/]: Time-Travel"))
	testing.expect(t, strings.contains(hint_paint.text, "!: Priority"))
	testing.expect(t, !strings.contains(hint_paint.text, "Secret"))

	// Verify Disabled_Dimmed item ('!: Priority') carries .Dim style in its Styled_Span
	found_dim := false
	for sp in hint_paint.spans {
		if strings.contains(sp.text, "Priority") && (.Dim in sp.style) {
			found_dim = true
			break
		}
	}
	testing.expect(t, found_dim)

	// 2. Same-frame pending chord ('g') immediately updates hint_bar with [CHORD: g…] and continuation 'g: Jump Top'!
	render_bars(&ctx, &scr, &inp, 100, Key_Event{code = .Rune, ch = 'g'})
	chord_hint := scr.paints[hash_id("hint_bar")]
	testing.expect(t, strings.contains(chord_hint.text, "[CHORD:"))
	testing.expect(t, strings.contains(chord_hint.text, "Jump Top"))

	// Cancel pending chord with Escape
	render_bars(&ctx, &scr, &inp, 100, Key_Event{code = .Escape})

	// 3. Narrow bar (38 cols): verifies display-width truncation with " | …" and left-truncated "…" breadcrumb
	render_bars(&ctx, &scr, &inp, 38)
	narrow_hint  := scr.paints[hash_id("hint_bar")]
	narrow_crumb := scr.paints[hash_id("crumb_bar")]
	testing.expect(t, string_display_width(narrow_hint.text) <= 38)
	testing.expect(t, strings.has_suffix(narrow_hint.text, " | …"))
	testing.expect(t, string_display_width(narrow_crumb.text) <= 38)
	testing.expect(t, strings.contains(narrow_crumb.text, "card_3"))
}

@(test)
test_single_guard_eval_splitter_priority_ctrl_root_chord_palette_avail_and_chord_reset :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	scr: Screen
	testing.expect_value(t, screen_init(&scr, 80, 20), nil)
	defer screen_destroy(&scr)

	ctx: Layout_Context
	inp: Input_State
	cp: Command_Palette
	command_palette_init(&cp, &inp)

	register_action_spec(&inp, &cp, Action_Spec{
		action_name     = "col.guarded_h",
		chord_spec      = "H",
		scope           = "work_scope",
		policy          = .Scope_Only,
		show_in_palette = true,
	})
	register_action_spec(&inp, &cp, Action_Spec{
		action_name     = "work.enter_override",
		chord_spec      = "<Enter>",
		scope           = "work_scope",
		policy          = .Scope_Only,
		show_in_palette = true,
	})
	register_action_spec(&inp, &cp, Action_Spec{
		action_name     = "root.ctrl_n_new",
		chord_spec      = "<C-n>",
		policy          = .Root_And_Scopes,
		show_in_palette = true,
	})
	register_action_spec(&inp, &cp, Action_Spec{
		action_name     = "app.dimmed_act",
		chord_spec      = "!",
		policy          = .Root_And_Scopes,
		availability    = .Disabled_Dimmed,
		show_in_palette = true,
	})
	register_action_spec(&inp, &cp, Action_Spec{
		action_name     = "nav.top_chord",
		chord_spec      = "g g",
		policy          = .Root_And_Scopes,
		show_in_palette = true,
	})

	guard_calls := 0
	set_action_guard(&inp, "col.guarded_h", proc(_: u64, ud: rawptr) -> (Guard_Result, string) {
		cnt := (^int)(ud)
		cnt^ += 1
		return .Disabled_Bubble, "bubble"
	}, &guard_calls)

	build_test_tree :: proc(ctx: ^Layout_Context, scr: ^Screen, inp: ^Input_State) {
		begin_layout(ctx, 80, 20)
		begin_frame(scr)
		if ui_scope(ctx, scr, "root", {dir = .Column, width = fixed(80), height = fixed(20)}) {
			if ui_scope(ctx, scr, "work_scope", {dir = .Row, width = fixed(80), height = fixed(16)}) {
				if ui_scope(ctx, scr, "list_col", {dir = .Column, width = fixed(30), height = fixed(16)}) {
					ui_button(ctx, scr, "item_0", {label = "Item 0", focus_flags = {.Default_Focus}})
					ui_button(ctx, scr, "item_1", {label = "Item 1"})
					ui_text_input(ctx, scr, inp, "search_input", {two_stage = true})
				}
				ui_splitter(ctx, scr, inp, "work_split", {
					dir          = .Row,
					default_size = 30,
					min_size     = 10,
					max_size     = 60,
					step         = 2,
				})
			}
		}
		end_layout(ctx)
	}

	build_test_tree(&ctx, &scr, &inp)
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "item_0"))

	// 1. Guard on .Scope_Only binding must be evaluated EXACTLY ONCE per key press (not twice)
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'H', mods = {.Shift}})
	testing.expect_value(t, guard_calls, 1)

	// 2. .Root_And_Scopes <C-n> binding must fire instead of being shadowed by Ctrl+N spatial nav Down onto item_1
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'n', mods = {.Ctrl}})
	testing.expect(t, was_action_triggered(&inp, "root.ctrl_n_new"))
	testing.expect(t, is_focused(&inp, "item_0"))

	// 3. Focusing work_split and pressing <Enter> must enter Splitter_Submode.Resize even though enclosing work_scope bound <Enter>
	inp.wants_focus_id = hash_id("work_split")
	build_test_tree(&ctx, &scr, &inp)
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "work_split"))

	resolve_input(&inp, &ctx, Key_Event{code = .Enter})
	testing.expect(t, !was_action_triggered(&inp, "work.enter_override"))
	testing.expect_value(t, get_scope_submode_typed(&inp, "work_split", Splitter_Submode), Splitter_Submode.Resize)
	resolve_input(&inp, &ctx, Key_Event{code = .Escape})

	// 4. Latching 'g' (step 1 of "g g") and then clicking two-stage search_input must clear pending_chord so typing 'g' inserts text
	inp.wants_focus_id = hash_id("item_0")
	build_test_tree(&ctx, &scr, &inp)
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'g'})
	testing.expect(t, inp.pending_chord.active)

	s_rect, _ := get_inner_rect(&ctx, "search_input")
	resolve_input(
		&inp,
		&ctx,
		Mouse_Event{x = s_rect.x + 1, y = s_rect.y, action = .Press, button = .Left},
		Mouse_Event{x = s_rect.x + 1, y = s_rect.y, action = .Release, button = .Left},
		Key_Event{code = .Rune, ch = 'g'},
	)
	testing.expect(t, !inp.pending_chord.active)
	testing.expect(t, !was_action_triggered(&inp, "nav.top_chord"))
	testing.expect_value(t, get_text(&inp, "search_input"), "g")

	// 5. Command Palette must respect .Disabled_Dimmed availability and not fire "app.dimmed_act"
	update_palette_matches(&cp, &inp, "app.dimmed_act")
	testing.expect(t, cp.match_count >= 1)
	inp.triggered_action_id = 0
	_ = dispatch_palette_row(&inp, &cp, 0)
	testing.expect_value(t, inp.triggered_action_id, u64(0))
}
