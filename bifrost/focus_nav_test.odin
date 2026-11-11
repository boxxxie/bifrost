package bifrost

import "core:fmt"
import "core:mem"
import "core:testing"

@(test)
test_scope_tree_bounds_flags_synthesis_and_local_ids :: proc(t: ^testing.T) {
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
	testing.expect_value(t, screen_init(&scr, 80, 24, alloc), nil)
	defer screen_destroy(&scr)

	ctx: Layout_Context
	inp: Input_State

	begin_layout(&ctx, 80, 24, context.temp_allocator)
	begin_frame(&scr, {}, context.temp_allocator)
	if container(&ctx, "root", {dir = .Row, width = grow(1), height = grow(1)}) {
		if container(&ctx, "plain_wrapper", {dir = .Column, width = fixed(30), height = grow(1)}) {
			if container(&ctx, "col_a", {dir = .Column, width = grow(1), height = grow(1), focus_scope = true}) {
				ui_text_input(&ctx, &scr, &inp, "col_a_sink", {
					focus_flags = {.Captures_Text, .Auto_Edit, .Scope_Text_Sink},
				})
				leaf(&ctx, "card", 10, 1, {local_id = true, focus_flags = {.Focusable, .Default_Focus}})
			}
		}
		if container(&ctx, "col_b", {dir = .Column, width = grow(1), height = grow(1), focus_flags = {.Focus_Scope}}) {
			leaf(&ctx, "card", 10, 1, {local_id = true, focus_flags = {.Focusable}})
		}
		if ui_modal(&ctx, &scr, "dlg", {title = "Dialog", z_layer = 20, width = fixed(24), height = fixed(6)}) {
			ui_button(&ctx, &scr, "dlg_ok", {label = "OK"})
		}
	}
	end_layout(&ctx)

	testing.expect_value(t, ctx.scope_stack_len, 0)
	testing.expect(t, .Focus_Scope in ctx.nodes[0].focus_flags, "Root 0 must automatically be a Focus_Scope")
	testing.expect_value(t, ctx.nodes[0].parent_scope_idx, i32(-1))
	testing.expect_value(t, ctx.nodes[0].subtree_end_idx, i32(len(ctx.nodes)))

	// plain_wrapper (idx 1) is NOT a Focus_Scope, so col_a's parent_scope_idx must skip plain_wrapper and point to root (0)
	col_a_idx := ctx.id_map[hash_id("col_a")]
	sink_idx := ctx.id_map[hash_id("col_a_sink")]
	dlg_idx := ctx.id_map[hash_id("dlg")]
	dlg_ok_idx := ctx.id_map[hash_id("dlg_ok")]

	testing.expect_value(t, ctx.nodes[col_a_idx].parent_scope_idx, i32(0))
	testing.expect_value(t, ctx.nodes[col_a_idx].text_sink_idx, sink_idx)
	testing.expect_value(t, ctx.nodes[col_a_idx].subtree_end_idx, col_a_idx + 3)

	testing.expect(t, .Focus_Scope in ctx.nodes[dlg_idx].focus_flags)
	testing.expect(t, .Trap_Focus in ctx.nodes[dlg_idx].focus_flags)
	testing.expect_value(t, ctx.nodes[dlg_ok_idx].parent_scope_idx, dlg_idx)
	testing.expect_value(t, ctx.nodes[dlg_idx].subtree_end_idx, dlg_ok_idx + 1)

	// Clay-inspired local ID hashing: zero-allocation, parent-seeded, collision-free
	testing.expect_value(t, hash_local_id(0, "card"), hash_id("card"))
	testing.expect(t, hash_local_id(hash_id("col_1"), "2") != hash_id("col_12"))
	h_a := hash_local_id(hash_id("col_a"), "card")
	h_b := hash_local_id(hash_id("col_b"), "card")
	testing.expect(t, h_a != h_b, "Same local label under different scopes must produce distinct hashes")
	testing.expect(t, h_a in ctx.id_map)
	testing.expect(t, h_b in ctx.id_map)
	testing.expect(t, ctx.id_map[h_a] != ctx.id_map[h_b])

	idi_a0 := hash_local_idi(hash_id("col_a"), "item", 0)
	idi_a1 := hash_local_idi(hash_id("col_a"), "item", 1)
	idi_b0 := hash_local_idi(hash_id("col_b"), "item", 0)
	testing.expect(t, idi_a0 != idi_a1)
	testing.expect(t, idi_a0 != idi_b0)
}

@(test)
test_z_order_out_of_tree_order_trap_focus_and_stacked_modals :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	scr: Screen
	testing.expect_value(t, screen_init(&scr, 80, 24), nil)
	defer screen_destroy(&scr)

	ctx: Layout_Context
	inp: Input_State

	build_ui :: proc(
		ctx: ^Layout_Context,
		scr: ^Screen,
		open_low_modal: bool,
		open_high_modal: bool,
	) {
		begin_layout(ctx, 80, 24)
		begin_frame(scr)
		if container(ctx, "root", {dir = .Row, width = grow(1), height = grow(1)}) {
			// Declare higher-Z modal (z = 30) inside the FIRST sibling container (earlier node index!)
			if container(ctx, "left_sidebar", {dir = .Column, width = fixed(24), height = grow(1), focus_scope = true}) {
				ui_button(ctx, scr, "ws_btn_1", {label = "WS 1"})
				ui_button(ctx, scr, "ws_btn_2", {label = "WS 2"})

				if open_high_modal {
					if ui_modal(ctx, scr, "modal_high", {title = "High Z=30", z_layer = 30, width = fixed(28), height = fixed(6)}) {
						ui_button(ctx, scr, "high_btn_1", {label = "High 1"})
						ui_button(ctx, scr, "high_btn_2", {label = "High 2"})
					}
				}
			}

			// Declare lower-Z modal (z = 20) inside a LATER sibling container
			if container(ctx, "main_area", {dir = .Column, width = grow(1), height = grow(1), focus_scope = true}) {
				ui_button(ctx, scr, "main_btn", {label = "Main"})

				if open_low_modal {
					if ui_modal(ctx, scr, "modal_low", {title = "Low Z=20", z_layer = 20, width = fixed(32), height = fixed(8)}) {
						ui_button(ctx, scr, "low_btn_1", {label = "Low 1"})
						ui_button(ctx, scr, "low_btn_2", {label = "Low 2"})
					}
				}
			}
		}
		end_layout(ctx)
	}

	// 1. Base workspace: move to ws_btn_2 inside left_sidebar
	build_ui(&ctx, &scr, false, false)
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "ws_btn_1"))

	resolve_input(&inp, &ctx, Key_Event{code = .Tab})
	testing.expect(t, is_focused(&inp, "ws_btn_2"))

	// 2. Open modal_low (z = 20): traps focus, Tab moves to low_btn_2 without overwriting workspace memory
	build_ui(&ctx, &scr, true, false)
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "low_btn_1"))

	resolve_input(&inp, &ctx, Key_Event{code = .Tab})
	testing.expect(t, is_focused(&inp, "low_btn_2"))

	// 3. Open modal_high (z = 30) declared EARLIER in ctx.nodes than modal_low (z = 20):
	// z_order precedence must make modal_high the active focus trap!
	build_ui(&ctx, &scr, true, true)
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "high_btn_1"), "Higher effective_z modal must win regardless of tree order")

	resolve_input(&inp, &ctx, Key_Event{code = .Tab})
	testing.expect(t, is_focused(&inp, "high_btn_2"))

	// 4. Close modal_high (z = 30) -> restores modal_low's remembered leaf low_btn_2
	build_ui(&ctx, &scr, true, false)
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "low_btn_2"), "Closing top modal must restore lower modal's remembered leaf")

	// 5. Close modal_low (z = 20) -> restores workspace's remembered leaf ws_btn_2
	build_ui(&ctx, &scr, false, false)
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "ws_btn_2"), "Closing lower modal must restore workspace leaf without clobbering")
}

@(test)
test_kanban_shallow_and_deep_history_empty_scope_and_inactive_highlights :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	scr: Screen
	testing.expect_value(t, screen_init(&scr, 100, 24), nil)
	defer screen_destroy(&scr)

	ctx: Layout_Context
	inp: Input_State

	build_kanban :: proc(
		ctx: ^Layout_Context,
		scr: ^Screen,
		has_doing_2: bool,
		modal_open: bool,
	) {
		begin_layout(ctx, 100, 24)
		begin_frame(scr)
		if container(ctx, "root", {dir = .Column, width = grow(1), height = grow(1)}) {
			if container(ctx, "board", {dir = .Row, width = grow(1), height = grow(1), focus_flags = {.Focus_Scope}}) {
				if container(ctx, "col_backlog", {
					dir         = .Column,
					width       = fixed(30),
					height      = grow(1),
					border      = .Plain,
					focus_flags = {.Focus_Scope, .Focusable},
				}) {
					set_paint(scr, "col_backlog", {title = "Backlog"})
					ui_button(ctx, scr, "card_1", {label = "Card 1", focus_flags = {.Default_Focus}})
					ui_button(ctx, scr, "card_2", {label = "Card 2"})
				}

				if container(ctx, "col_doing", {
					dir         = .Column,
					width       = fixed(30),
					height      = grow(1),
					border      = .Plain,
					focus_flags = {.Focus_Scope, .Focusable},
				}) {
					set_paint(scr, "col_doing", {title = "Doing"})
					ui_button(ctx, scr, "doing_1", {label = "Doing 1"})
					if has_doing_2 {
						ui_button(ctx, scr, "doing_2", {label = "Doing 2", focus_flags = {.Default_Focus}})
					}
				}

				// Empty focusable column (0 cards)
				if container(ctx, "col_empty", {
					dir         = .Column,
					width       = fixed(30),
					height      = grow(1),
					border      = .Plain,
					focus_flags = {.Focus_Scope, .Focusable},
				}) {
					set_paint(scr, "col_empty", {title = "Done (Empty)"})
				}
			}

			if modal_open {
				if ui_modal(ctx, scr, "confirm_del", {title = "Delete Card?", z_layer = 20, width = fixed(30), height = fixed(6)}) {
					ui_button(ctx, scr, "confirm_yes", {label = "Delete"})
				}
			}
		}
		end_layout(ctx)
	}

	// 1. Initial mount: lands on card_1 (.Default_Focus), Tab moves to card_2
	build_kanban(&ctx, &scr, true, false)
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "card_1"))

	resolve_input(&inp, &ctx, Key_Event{code = .Tab})
	testing.expect(t, is_focused(&inp, "card_2"))

	// 2. Press F6 -> switches to col_doing and lands on doing_2 (.Default_Focus)
	resolve_input(&inp, &ctx, Key_Event{code = .F6})
	testing.expect(t, is_focused(&inp, "doing_2"))
	testing.expect(t, is_scope_selected(&inp, "card_2"), "Inactive col_backlog must remember card_2")

	// Verify 3-state visual highlight: active doing_2 gets {.Bold, .Reverse}, inactive remembered card_2 gets {.Dim, .Reverse}
	apply_input_highlights(&scr, &ctx, &inp)
	doing_2_paint := scr.paints[hash_id("doing_2")]
	card_2_paint := scr.paints[hash_id("card_2")]
	card_1_paint := scr.paints[hash_id("card_1")]
	testing.expect(t, .Bold in doing_2_paint.style && .Reverse in doing_2_paint.style)
	testing.expect(t, .Dim in card_2_paint.style && .Reverse in card_2_paint.style)
	testing.expect(t, .Reverse not_in card_1_paint.style)

	// 3. Press F6 -> focuses empty col_empty container itself instead of skipping it!
	resolve_input(&inp, &ctx, Key_Event{code = .F6})
	testing.expect(t, is_focused(&inp, "col_empty"))

	// 4. Press F6 -> wraps back to col_backlog and Deep History (H*) restores card_2!
	resolve_input(&inp, &ctx, Key_Event{code = .F6})
	testing.expect(t, is_focused(&inp, "card_2"))

	// 5. Escape drills up from card_2 to focusable parent scope col_backlog; Enter drills back into card_2
	resolve_input(&inp, &ctx, Key_Event{code = .Escape})
	testing.expect(t, is_focused(&inp, "col_backlog"))
	resolve_input(&inp, &ctx, Key_Event{code = .Enter})
	testing.expect(t, is_focused(&inp, "card_2"))

	// 6. Switch to col_doing (restoring doing_2), open confirm_del modal, delete doing_2, and close modal:
	// Shallow History (H) on board (last_child_hash = col_doing) must keep focus inside col_doing on surviving doing_1!
	resolve_input(&inp, &ctx, Key_Event{code = .F6})
	testing.expect(t, is_focused(&inp, "doing_2"))

	build_kanban(&ctx, &scr, true, true)
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "confirm_yes"))

	build_kanban(&ctx, &scr, false, false)
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "doing_1"), "Shallow History (H) must fall back to surviving sibling in col_doing, not reset to col_backlog")
}

@(test)
test_disabled_node_and_subtree_auto_advance_and_floating_bring_to_front :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	scr: Screen
	testing.expect_value(t, screen_init(&scr, 80, 24), nil)
	defer screen_destroy(&scr)

	ctx: Layout_Context
	inp: Input_State

	build_disabled_and_floating_ui :: proc(
		ctx: ^Layout_Context,
		scr: ^Screen,
		disable_btn_2: bool,
		disable_group: bool,
	) {
		begin_layout(ctx, 80, 24)
		begin_frame(scr)
		if container(ctx, "root", {dir = .Column, width = grow(1), height = grow(1)}) {
			ui_button(ctx, scr, "btn_1", {label = "One"})
			b2_flags := Focus_Flags{.Disabled} if disable_btn_2 else Focus_Flags{}
			ui_button(ctx, scr, "btn_2", {label = "Two", focus_flags = b2_flags})

			grp_flags := Focus_Flags{.Disabled} if disable_group else Focus_Flags{}
			if container(ctx, "sub_grp", {dir = .Row, width = fit(), height = fit(), focus_flags = grp_flags}) {
				ui_button(ctx, scr, "btn_3", {label = "Three"})
			}

			// Two overlapping non-modal floating tool windows at z_layer = 10
			if container(ctx, "float_a", {
				dir         = .Column,
				width       = fixed(20),
				height      = fixed(6),
				z_layer     = 10,
				floating    = true,
				offset      = {10, 5},
				focus_flags = {.Focus_Scope},
			}) {
				ui_button(ctx, scr, "float_a_btn", {label = "Float A", width = fixed(18), height = fixed(2)})
			}
			if container(ctx, "float_b", {
				dir         = .Column,
				width       = fixed(20),
				height      = fixed(6),
				z_layer     = 10,
				floating    = true,
				offset      = {10, 5}, // Exact same rect overlapping float_a!
				focus_flags = {.Focus_Scope},
			}) {
				ui_button(ctx, scr, "float_b_btn", {label = "Float B", width = fixed(18), height = fixed(2)})
			}
		}
		end_layout(ctx)
	}

	// 1. Focus btn_2, then mark btn_2 .Disabled on next frame -> auto-advances off disabled btn_2!
	build_disabled_and_floating_ui(&ctx, &scr, false, false)
	resolve_input(&inp, &ctx)
	resolve_input(&inp, &ctx, Key_Event{code = .Tab})
	testing.expect(t, is_focused(&inp, "btn_2"))

	build_disabled_and_floating_ui(&ctx, &scr, true, false)
	resolve_input(&inp, &ctx)
	testing.expect(t, !is_focused(&inp, "btn_2"), "Focus must never remain stranded on a .Disabled widget")
	testing.expect(t, is_focused(&inp, "btn_1"))

	// Clicking disabled btn_2 must not focus or activate it
	b2_rect, _ := get_rect(&ctx, "btn_2")
	resolve_input(
		&inp,
		&ctx,
		Mouse_Event{x = b2_rect.x + 1, y = b2_rect.y, action = .Press, button = .Left},
		Mouse_Event{x = b2_rect.x + 1, y = b2_rect.y, action = .Release, button = .Left},
	)
	testing.expect(t, !was_activated(&inp, "btn_2"))
	testing.expect(t, is_focused(&inp, "btn_1"))

	// Focus btn_3 inside sub_grp, then disable sub_grp -> inherited .Disabled advances focus off btn_3
	inp.wants_focus_id = hash_id("btn_3")
	build_disabled_and_floating_ui(&ctx, &scr, true, false)
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "btn_3"))

	build_disabled_and_floating_ui(&ctx, &scr, true, true)
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "btn_1"), "Disabling ancestor container must prune entire subtree")

	// 2. Floating window bring-to-front: initially float_b was declared after float_a so (12, 5) hits float_b_btn;
	// focusing float_a_btn promotes float_a to front of z_layer=10 so clicking (12, 5) on next frame hits float_a_btn!
	inp.wants_focus_id = hash_id("float_a_btn")
	build_disabled_and_floating_ui(&ctx, &scr, false, false)
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "float_a_btn"))

	build_disabled_and_floating_ui(&ctx, &scr, false, false)
	resolve_input(
		&inp,
		&ctx,
		Mouse_Event{x = 12, y = 5, action = .Press, button = .Left},
		Mouse_Event{x = 12, y = 5, action = .Release, button = .Left},
	)
	testing.expect(t, was_activated(&inp, "float_a_btn"), "Promoted non-modal floating scope must hit-test in front of sibling at same z_layer")
}

@(test)
test_two_stage_edit_sticky_tab_carry_and_mouse_click_to_edit :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	scr: Screen
	testing.expect_value(t, screen_init(&scr, 80, 24), nil)
	defer screen_destroy(&scr)

	ctx: Layout_Context
	inp: Input_State

	build_form :: proc(ctx: ^Layout_Context, scr: ^Screen, inp: ^Input_State) {
		begin_layout(ctx, 80, 24)
		begin_frame(scr)
		if container(ctx, "root", {dir = .Column, width = grow(1), height = grow(1)}) {
			if ui_modal(ctx, scr, "task_modal", {title = "New Task", z_layer = 20, width = fixed(40), height = fixed(12), gap = 1}) {
				ui_text_input(ctx, scr, inp, "title_input", {
					placeholder = "Title...",
					two_stage   = true,
					focus_flags = {.Default_Focus},
				})
				ui_text_input(ctx, scr, inp, "owner_input", {
					placeholder = "Owner...",
					two_stage   = true,
				})
				ui_button(ctx, scr, "save_btn", {label = "Save"})
			}
		}
		end_layout(ctx)
	}

	// 1. Fresh modal mount: title_input is focused in navigation stage (editing_id == 0)
	build_form(&ctx, &scr, &inp)
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "title_input"))
	testing.expect(t, !is_editing(&inp, "title_input"))

	// Pressing 'j' and 'k' navigates fields instead of inserting text!
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'j'})
	testing.expect(t, is_focused(&inp, "owner_input"))
	testing.expect_value(t, get_text(&inp, "title_input"), "")

	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'k'})
	testing.expect(t, is_focused(&inp, "title_input"))

	// 2. Press Enter on title_input -> enters edit mode without firing activated_id
	resolve_input(&inp, &ctx, Key_Event{code = .Enter})
	testing.expect(t, is_editing(&inp, "title_input"))
	testing.expect(t, !was_activated(&inp, "title_input"))

	resolve_input(
		&inp,
		&ctx,
		Key_Event{code = .Rune, ch = 'f'},
		Key_Event{code = .Rune, ch = 'i'},
		Key_Event{code = .Rune, ch = 'x'},
	)
	testing.expect_value(t, get_text(&inp, "title_input"), "fix")

	// 3. Sticky Tab while editing carries edit mode directly into two-stage owner_input!
	resolve_input(&inp, &ctx, Key_Event{code = .Tab})
	testing.expect(t, is_focused(&inp, "owner_input"))
	testing.expect(t, is_editing(&inp, "owner_input"), "Tab while editing must carry edit mode to next Captures_Text field")

	resolve_input(
		&inp,
		&ctx,
		Key_Event{code = .Rune, ch = 'a'},
		Key_Event{code = .Rune, ch = 'd'},
		Key_Event{code = .Rune, ch = 'a'},
	)
	testing.expect_value(t, get_text(&inp, "owner_input"), "ada")

	// 4. Tab onto non-text save_btn clears editing_id = 0
	resolve_input(&inp, &ctx, Key_Event{code = .Tab})
	testing.expect(t, is_focused(&inp, "save_btn"))
	testing.expect_value(t, inp.editing_id, u64(0))

	// 5. Mouse click on two-stage title_input at col +1 focuses, enters edit mode immediately, updates history, and places cursor
	title_rect, _ := get_inner_rect(&ctx, "title_input")
	resolve_input(
		&inp,
		&ctx,
		Mouse_Event{x = title_rect.x + 1, y = title_rect.y, action = .Press, button = .Left},
		Mouse_Event{x = title_rect.x + 1, y = title_rect.y, action = .Release, button = .Left},
	)
	testing.expect(t, is_focused(&inp, "title_input"))
	testing.expect(t, is_editing(&inp, "title_input"), "Clicking two-stage input must immediately activate editing_id")
	testing.expect(t, is_scope_selected(&inp, "title_input"))
	testing.expect_value(t, get_text_slot(&inp, hash_id("title_input")).cursor_byte, 1)

	// 6. First Escape exits two-stage edit mode without dismissing modal; second Escape dismisses modal!
	resolve_input(&inp, &ctx, Key_Event{code = .Escape})
	testing.expect(t, is_focused(&inp, "title_input"))
	testing.expect(t, !is_editing(&inp, "title_input"))
	testing.expect(t, !was_modal_dismissed(&inp, "task_modal"))

	resolve_input(&inp, &ctx, Key_Event{code = .Escape})
	testing.expect(t, was_modal_dismissed(&inp, "task_modal"))
}

@(test)
test_scope_text_sink_delegation_filter_reset_and_zero_match_fallback :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	scr: Screen
	testing.expect_value(t, screen_init(&scr, 80, 24), nil)
	defer screen_destroy(&scr)

	ctx: Layout_Context
	inp: Input_State
	bind_key(&inp, Key_Event{code = .Rune, ch = 'q'}, "quit_app", .Root_And_Scopes)

	all_items := [3]string{"open_file", "quit_workspace", "quick_fix"}

	build_sink_palette :: proc(
		ctx: ^Layout_Context,
		scr: ^Screen,
		inp: ^Input_State,
		items: []string,
	) {
		query := get_text(inp, "palette_sink")
		begin_layout(ctx, 80, 24)
		begin_frame(scr)
		if container(ctx, "root", {dir = .Column, width = grow(1), height = grow(1)}) {
			if container(ctx, "palette_scope", {
				dir         = .Column,
				width       = fixed(50),
				height      = fixed(12),
				z_layer     = 30,
				floating    = true,
				focus_flags = {.Focus_Scope, .Trap_Focus},
			}) {
				// Non-focusable .Scope_Text_Sink search bar
				ui_text_input(ctx, scr, inp, "palette_sink", {
					placeholder = "Filter commands...",
					focus_flags = {.Captures_Text, .Auto_Edit, .Scope_Text_Sink},
				})
				matched_idx := 0
				for item in items {
					if len(query) == 0 || contains_case_insensitive(item, query) {
						item_id := fmt.tprintf("cmd_%d", matched_idx)
						flags := Focus_Flags{.Default_Focus} if matched_idx == 0 else Focus_Flags{}
						ui_button(ctx, scr, item_id, {label = item, focus_flags = flags})
						matched_idx += 1
					}
				}
			}
		}
		end_layout(ctx)
	}

	// 1. Initial mount: cmd_0 holds focus while palette_sink owns editing_id!
	build_sink_palette(&ctx, &scr, &inp, all_items[:])
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "cmd_0"))
	testing.expect(t, is_editing(&inp, "palette_sink"))

	// 2. Navigate Down / Ctrl+N to cmd_2 while editing_id remains palette_sink
	resolve_input(&inp, &ctx, Key_Event{code = .Down})
	testing.expect(t, is_focused(&inp, "cmd_1"))
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'n', mods = {.Ctrl}})
	testing.expect(t, is_focused(&inp, "cmd_2"))
	testing.expect(t, is_editing(&inp, "palette_sink"))

	// 3. Typing 'q' mutates palette_sink (does NOT trigger quit_app) and resets sibling selection to cmd_0!
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'q'})
	testing.expect_value(t, get_text(&inp, "palette_sink"), "q")
	testing.expect(t, !was_action_triggered(&inp, "quit_app"))

	build_sink_palette(&ctx, &scr, &inp, all_items[:])
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "cmd_0"), "Text mutation in .Scope_Text_Sink must reset scope selection to default item")

	// Move to cmd_1, then press Left arrow (cursor motion WITHOUT text mutation) -> keeps cmd_1 focused!
	resolve_input(&inp, &ctx, Key_Event{code = .Down})
	testing.expect(t, is_focused(&inp, "cmd_1"))
	resolve_input(&inp, &ctx, Key_Event{code = .Left})
	testing.expect(t, is_focused(&inp, "cmd_1"), "Horizontal cursor motion without text mutation must preserve item selection")
	resolve_input(&inp, &ctx, Key_Event{code = .End})

	// 4. Type "zzz" so 0 items match -> zero-match fallback focuses palette_sink so typing/Backspace continues working!
	resolve_input(
		&inp,
		&ctx,
		Key_Event{code = .Rune, ch = 'z'},
		Key_Event{code = .Rune, ch = 'z'},
		Key_Event{code = .Rune, ch = 'z'},
	)
	build_sink_palette(&ctx, &scr, &inp, all_items[:])
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "palette_sink"), "Zero-match scope must fall back to text_sink_idx")
	testing.expect(t, is_editing(&inp, "palette_sink"))

	// 5. Backspace 3 times to restore "q" -> next frame snaps focus right back onto cmd_0!
	resolve_input(
		&inp,
		&ctx,
		Key_Event{code = .Backspace},
		Key_Event{code = .Backspace},
		Key_Event{code = .Backspace},
	)
	testing.expect_value(t, get_text(&inp, "palette_sink"), "q")
	build_sink_palette(&ctx, &scr, &inp, all_items[:])
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "cmd_0"), "Restoring matches must snap focus from sink back onto cmd_0")
}

@(test)
test_spatial_2d_wrapping_and_bubbling :: proc(t: ^testing.T) {
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
	testing.expect_value(t, screen_init(&scr, 90, 24, alloc), nil)
	defer screen_destroy(&scr)

	// 1. Direct integer-only lane scorer invariants
	origin_rect := Rect{x = 0, y = 0, w = 10, h = 2}
	in_lane_far := Rect{x = 2, y = 10, w = 8, h = 2}
	out_lane_near := Rect{x = 14, y = 3, w = 10, h = 2}
	behind_rect := Rect{x = 0, y = 0, w = 10, h = 2}

	s_in, ok_in := score_spatial_candidate(origin_rect, in_lane_far, .Down)
	s_out, ok_out := score_spatial_candidate(origin_rect, out_lane_near, .Down)
	_, ok_behind := score_spatial_candidate(origin_rect, behind_rect, .Down)

	testing.expect(t, ok_in, "In-lane candidate below origin must be valid")
	testing.expect(t, ok_out, "Cone candidate below-right of origin must be valid")
	testing.expect(t, !ok_behind, "Overlapping/behind candidate must be rejected")
	testing.expect(t, s_in < OUT_OF_LANE_PENALTY, "In-lane candidate must avoid OUT_OF_LANE_PENALTY")
	testing.expect(t, s_out >= OUT_OF_LANE_PENALTY, "Out-of-lane candidate must incur OUT_OF_LANE_PENALTY")
	testing.expect(t, s_in < s_out, "In-lane candidate must beat closer diagonal out-of-lane candidate")

	// 2. Sticky orthogonal axis memory (`preferred_nav_pos`) across a wide full-row banner
	ctx: Layout_Context
	inp: Input_State

	build_ragged_grid :: proc(ctx: ^Layout_Context, scr: ^Screen) {
		begin_layout(ctx, 80, 20)
		begin_frame(scr)
		if container(ctx, "ragged_scope", {dir = .Column, width = fixed(60), height = fixed(14), gap = 1, focus_flags = {.Focus_Scope}}) {
			if container(ctx, "row_0", {dir = .Row, width = fixed(60), height = fixed(2), gap = 1}) {
				ui_button(ctx, scr, "r0_c0", {label = "0,0", width = fixed(18), height = fixed(2)})
				ui_button(ctx, scr, "r0_c1", {label = "0,1", width = fixed(18), height = fixed(2)})
				ui_button(ctx, scr, "r0_c2", {label = "0,2", width = fixed(18), height = fixed(2)})
			}
			ui_button(ctx, scr, "wide_banner", {label = "Full Span Banner", width = fixed(56), height = fixed(2)})
			if container(ctx, "row_2", {dir = .Row, width = fixed(60), height = fixed(2), gap = 1}) {
				ui_button(ctx, scr, "r2_c0", {label = "2,0", width = fixed(18), height = fixed(2)})
				ui_button(ctx, scr, "r2_c1", {label = "2,1", width = fixed(18), height = fixed(2)})
				ui_button(ctx, scr, "r2_c2", {label = "2,2", width = fixed(18), height = fixed(2)})
			}
		}
		end_layout(ctx)
	}

	build_ragged_grid(&ctx, &scr)
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "r0_c0"))

	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'l'}, Key_Event{code = .Rune, ch = 'l'})
	testing.expect(t, is_focused(&inp, "r0_c2"))

	// Step Down across full-width banner and Down again -> sticky preferred_x lands back on column 2 ("r2_c2")!
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'j'})
	testing.expect(t, is_focused(&inp, "wide_banner"))
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'j'})
	testing.expect(t, is_focused(&inp, "r2_c2"), "Sticky orthogonal axis memory must preserve column 2 across wide banner")

	// 3. `.Loop_Spatial` (same-lane ring wrap) vs `.Wrap_Spatial` (reading-order 2D grid wrap)
	inp_grid: Input_State
	build_2x3_grid :: proc(ctx: ^Layout_Context, scr: ^Screen, wrap_reading_order: bool) {
		flags := Focus_Flags{.Focus_Scope, .Wrap_Spatial} if wrap_reading_order else Focus_Flags{.Focus_Scope, .Loop_Spatial}
		begin_layout(ctx, 80, 20)
		begin_frame(scr)
		if container(ctx, "grid_scope", {dir = .Column, width = fixed(60), height = fixed(10), gap = 1, focus_flags = flags}) {
			if container(ctx, "g_row_0", {dir = .Row, width = fixed(60), height = fixed(2), gap = 1}) {
				ui_button(ctx, scr, "g00", {label = "00", width = fixed(18), height = fixed(2)})
				ui_button(ctx, scr, "g01", {label = "01", width = fixed(18), height = fixed(2)})
				ui_button(ctx, scr, "g02", {label = "02", width = fixed(18), height = fixed(2)})
			}
			if container(ctx, "g_row_1", {dir = .Row, width = fixed(60), height = fixed(2), gap = 1}) {
				ui_button(ctx, scr, "g10", {label = "10", width = fixed(18), height = fixed(2)})
				ui_button(ctx, scr, "g11", {label = "11", width = fixed(18), height = fixed(2)})
				ui_button(ctx, scr, "g12", {label = "12", width = fixed(18), height = fixed(2)})
			}
		}
		end_layout(ctx)
	}

	// 3a. Loop_Spatial: Right on g02 wraps in-lane to g00; Down on g11 wraps in-lane to g01
	build_2x3_grid(&ctx, &scr, false)
	resolve_input(&inp_grid, &ctx)
	resolve_input(&inp_grid, &ctx, Key_Event{code = .Right}, Key_Event{code = .Right})
	testing.expect(t, is_focused(&inp_grid, "g02"))
	resolve_input(&inp_grid, &ctx, Key_Event{code = .Right})
	testing.expect(t, is_focused(&inp_grid, "g00"), ".Loop_Spatial must wrap Right within the same row")
	resolve_input(&inp_grid, &ctx, Key_Event{code = .Right}, Key_Event{code = .Down})
	testing.expect(t, is_focused(&inp_grid, "g11"))
	resolve_input(&inp_grid, &ctx, Key_Event{code = .Down})
	testing.expect(t, is_focused(&inp_grid, "g01"), ".Loop_Spatial must wrap Down within the same column")

	// 3b. Wrap_Spatial: Right on g02 advances in reading order to g10; Left on g10 wraps back to g02; Right on g12 wraps to g00
	build_2x3_grid(&ctx, &scr, true)
	resolve_input(&inp_grid, &ctx, Key_Event{code = .Right})
	testing.expect(t, is_focused(&inp_grid, "g02"))
	resolve_input(&inp_grid, &ctx, Key_Event{code = .Right})
	testing.expect(t, is_focused(&inp_grid, "g10"), ".Wrap_Spatial must advance from end of Row 0 to start of Row 1")
	resolve_input(&inp_grid, &ctx, Key_Event{code = .Left})
	testing.expect(t, is_focused(&inp_grid, "g02"), ".Wrap_Spatial must wrap Left from start of Row 1 back to end of Row 0")
	resolve_input(&inp_grid, &ctx, Key_Event{code = .Down})
	testing.expect(t, is_focused(&inp_grid, "g12"))
	resolve_input(&inp_grid, &ctx, Key_Event{code = .Right})
	testing.expect(t, is_focused(&inp_grid, "g00"), ".Wrap_Spatial must wrap Right from final item back to first item")

	// 4. `.Strict_Spatial` boundary consumption vs Cross-Scope Bubbling with H* history
	inp_cols: Input_State
	build_two_cols :: proc(ctx: ^Layout_Context, scr: ^Screen, strict_left: bool) {
		left_flags := Focus_Flags{.Focus_Scope, .Strict_Spatial} if strict_left else Focus_Flags{.Focus_Scope}
		begin_layout(ctx, 80, 20)
		begin_frame(scr)
		if container(ctx, "board", {dir = .Row, width = fixed(70), height = fixed(14), gap = 2, focus_flags = {.Focus_Scope}}) {
			if container(ctx, "col_left", {dir = .Column, width = fixed(30), height = fixed(12), gap = 1, focus_flags = left_flags}) {
				ui_button(ctx, scr, "left_0", {label = "L0", width = fixed(26), height = fixed(2)})
				ui_button(ctx, scr, "left_1", {label = "L1", width = fixed(26), height = fixed(2)})
			}
			if container(ctx, "col_right", {dir = .Column, width = fixed(30), height = fixed(12), gap = 1, focus_flags = {.Focus_Scope}}) {
				ui_button(ctx, scr, "right_0", {label = "R0", width = fixed(26), height = fixed(2)})
				ui_button(ctx, scr, "right_1", {label = "R1", width = fixed(26), height = fixed(2), focus_flags = {.Default_Focus}})
			}
		}
		end_layout(ctx)
	}

	// With .Strict_Spatial on col_left, 'l' is swallowed at col_left's boundary
	build_two_cols(&ctx, &scr, true)
	resolve_input(&inp_cols, &ctx)
	testing.expect(t, is_focused(&inp_cols, "left_0"))
	resolve_input(&inp_cols, &ctx, Key_Event{code = .Rune, ch = 'l'})
	testing.expect(t, is_focused(&inp_cols, "left_0"), ".Strict_Spatial must swallow missed horizontal move at scope boundary")

	// Without .Strict_Spatial, 'l' bubbles to board, hits col_right, and resolves right_1 (.Default_Focus) -> H*
	build_two_cols(&ctx, &scr, false)
	resolve_input(&inp_cols, &ctx, Key_Event{code = .Rune, ch = 'l'})
	testing.expect(t, is_focused(&inp_cols, "right_1"), "Cross-scope 'l' must bubble to board and resolve col_right's default card")
	resolve_input(&inp_cols, &ctx, Key_Event{code = .Rune, ch = 'k'})
	testing.expect(t, is_focused(&inp_cols, "right_0"))
	resolve_input(&inp_cols, &ctx, Key_Event{code = .Rune, ch = 'h'})
	testing.expect(t, is_focused(&inp_cols, "left_0"))
	resolve_input(&inp_cols, &ctx, Key_Event{code = .Rune, ch = 'l'})
	testing.expect(t, is_focused(&inp_cols, "right_0"), "Cross-scope 'l' must restore col_right's remembered leaf (H*)")
}

@(test)
test_scroll_into_view_and_paging :: proc(t: ^testing.T) {
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
	testing.expect_value(t, screen_init(&scr, 80, 24, alloc), nil)
	defer screen_destroy(&scr)

	ctx: Layout_Context
	inp: Input_State

	build_scroll_cards :: proc(ctx: ^Layout_Context, scr: ^Screen) {
		begin_layout(ctx, 80, 24)
		begin_frame(scr)
		if container(ctx, "root", {dir = .Row, width = grow(1), height = grow(1), gap = 2}) {
			// Outer height = 8, Plain border (1+1) -> inner_rect.h = 6 rows.
			// 8 cards * 2 rows = 16 content_span -> max_offset = 10.
			if container(ctx, "scroll_col", {
				dir         = .Column,
				width       = fixed(30),
				height      = fixed(8),
				border      = .Plain,
				scrollable  = true,
				focus_flags = {.Focus_Scope},
			}) {
				for i in 0 ..< 8 {
					cid := fmt.tprintf("card_%d", i)
					ui_button(ctx, scr, cid, {label = cid, width = fixed(28), height = fixed(2)})
				}
			}

			// Read-only focusable scrollable log container with 0 focusable children
			if container(ctx, "readonly_log", {
				dir         = .Column,
				width       = fixed(30),
				height      = fixed(6),
				border      = .Plain,
				scrollable  = true,
				focus_flags = {.Focus_Scope, .Focusable},
			}) {
				for i in 0 ..< 12 {
					lid := fmt.tprintf("line_%d", i)
					ui_label(ctx, scr, lid, lid)
				}
			}
		}
		end_layout(ctx)
	}

	// 1. Initial mount: card_0 is focused, card_4 is offscreen (node_clip.h == 0)
	build_scroll_cards(&ctx, &scr)
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "card_0"))
	testing.expect_value(t, get_scroll_offset(&inp, "scroll_col"), 0)
	clip_4_before, _ := get_node_clip(&ctx, "card_4")
	testing.expect_value(t, clip_4_before.h, 0)

	// 2. Press 'j' 4 times -> focuses card_4 and scrolls it into view ON THE EXACT SAME FRAME (0 lag)!
	resolve_input(
		&inp,
		&ctx,
		Key_Event{code = .Rune, ch = 'j'},
		Key_Event{code = .Rune, ch = 'j'},
		Key_Event{code = .Rune, ch = 'j'},
		Key_Event{code = .Rune, ch = 'j'},
	)
	testing.expect(t, is_focused(&inp, "card_4"))
	testing.expect_value(t, get_scroll_offset(&inp, "scroll_col"), 4)
	clip_4_after, _ := get_node_clip(&ctx, "card_4")
	testing.expect_value(t, clip_4_after.h, 2)

	// 3. Mouse wheel scroll while focus does NOT change must NOT be fought by scroll_node_into_view!
	resolve_input(&inp, &ctx, Mouse_Event{x = 4, y = 2, action = .Scroll_Up})
	wheel_offset := get_scroll_offset(&inp, "scroll_col")
	testing.expect(t, wheel_offset < 4, "Mouse wheel must scroll away freely")

	// Rebuild next frame with idle input (no focus change) -> preserves wheel_offset!
	build_scroll_cards(&ctx, &scr)
	resolve_input(&inp, &ctx)
	testing.expect_value(t, get_scroll_offset(&inp, "scroll_col"), wheel_offset)

	// 4. Materialized sibling paging: Home -> card_0, Page_Down -> steps ~1 viewport in-lane, End -> card_7, Page_Up -> steps back up
	resolve_input(&inp, &ctx, Key_Event{code = .Home})
	testing.expect(t, is_focused(&inp, "card_0"))
	testing.expect_value(t, get_scroll_offset(&inp, "scroll_col"), 0)

	resolve_input(&inp, &ctx, Key_Event{code = .Page_Down})
	testing.expect(t, is_focused(&inp, "card_2") || is_focused(&inp, "card_3"), "Page_Down must advance ~1 viewport span in-lane")

	resolve_input(&inp, &ctx, Key_Event{code = .End})
	testing.expect(t, is_focused(&inp, "card_7"))
	testing.expect_value(t, get_scroll_offset(&inp, "scroll_col"), 10)
	clip_7, _ := get_node_clip(&ctx, "card_7")
	testing.expect_value(t, clip_7.h, 2)

	resolve_input(&inp, &ctx, Key_Event{code = .Page_Up})
	testing.expect(t, !is_focused(&inp, "card_7"), "Page_Up must step upward from card_7")

	// 5. Switch via F6 to read-only log container (0 focusable children) and page its viewport directly
	resolve_input(&inp, &ctx, Key_Event{code = .F6})
	testing.expect(t, is_focused(&inp, "readonly_log"))
	resolve_input(&inp, &ctx, Key_Event{code = .Page_Down})
	testing.expect(t, get_scroll_offset(&inp, "readonly_log") > 0, "Page_Down on focusable scroll container must scroll viewport")
	resolve_input(&inp, &ctx, Key_Event{code = .End})
	testing.expect_value(t, get_scroll_offset(&inp, "readonly_log"), 8) // 12 lines - 4 inner_rect.h = 8
	resolve_input(&inp, &ctx, Key_Event{code = .Home})
	testing.expect_value(t, get_scroll_offset(&inp, "readonly_log"), 0)
}

@(test)
test_virtual_list_2d_table_stepping_paging_and_boundary_bubbling :: proc(t: ^testing.T) {
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
	testing.expect_value(t, screen_init(&scr, 80, 16, alloc), nil)
	defer screen_destroy(&scr)

	ctx: Layout_Context
	inp: Input_State
	last_slice: Virtual_Slice

	build_virtual_workspace :: proc(
		ctx: ^Layout_Context,
		scr: ^Screen,
		inp: ^Input_State,
		out_slice: ^Virtual_Slice,
	) {
		begin_layout(ctx, 80, 16)
		begin_frame(scr)
		if container(ctx, "workspace", {dir = .Row, width = grow(1), height = grow(1), gap = 1, focus_flags = {.Focus_Scope}}) {
			if container(ctx, "sidebar", {dir = .Column, width = fixed(20), height = grow(1), border = .Plain, focus_flags = {.Focus_Scope}}) {
				ui_button(ctx, scr, "nav_home", {label = "Home", width = fixed(18), height = fixed(2)})
			}
			// Outer height = 16, Plain border (1+1) -> 14 visible rows, 100,000 logical rows, 3 columns
			if ui_virtual_list(ctx, scr, inp, "pkg_table", 100_000, {
				title         = "Packages (100k x 3)",
				width         = grow(1),
				height        = grow(1),
				border        = .Plain,
				fallback_rows = 14,
				total_cols    = 3,
				focus_flags   = {.Default_Focus},
			}, out_slice) {
				for r := out_slice.start_row; r < out_slice.end_row; r += 1 {
					rid := fmt.tprintf("vrow_%d", r)
					ui_label(ctx, scr, rid, rid)
				}
			}
		}
		end_layout(ctx)
	}

	// 1. Mount workspace -> Default_Focus lands on pkg_table in O(1) layout nodes
	build_virtual_workspace(&ctx, &scr, &inp, &last_slice)
	resolve_input(&inp, &ctx)
	testing.expect(t, is_focused(&inp, "pkg_table"))
	testing.expect(t, len(ctx.nodes) < 25, "100k virtual table must keep O(1) layout node budget")

	// 2. Directional j/k, Down/Up, Ctrl+N/Ctrl+P, Page_Down/Page_Up, Home/End on virtual rows
	resolve_input(
		&inp,
		&ctx,
		Key_Event{code = .Rune, ch = 'j'},
		Key_Event{code = .Down},
		Key_Event{code = .Rune, ch = 'n', mods = {.Ctrl}},
	)
	testing.expect_value(t, get_selected_row(&inp, "pkg_table"), 3)

	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'k'}, Key_Event{code = .Rune, ch = 'p', mods = {.Ctrl}})
	testing.expect_value(t, get_selected_row(&inp, "pkg_table"), 1)

	resolve_input(&inp, &ctx, Key_Event{code = .Page_Down})
	testing.expect_value(t, get_selected_row(&inp, "pkg_table"), 14) // 1 + (14 - 1) = 14
	testing.expect_value(t, get_scroll_offset(&inp, "pkg_table"), 1)

	resolve_input(&inp, &ctx, Key_Event{code = .End})
	testing.expect_value(t, get_selected_row(&inp, "pkg_table"), 99_999)
	testing.expect_value(t, get_scroll_offset(&inp, "pkg_table"), 99_986)

	resolve_input(&inp, &ctx, Key_Event{code = .Home})
	testing.expect_value(t, get_selected_row(&inp, "pkg_table"), 0)
	testing.expect_value(t, get_scroll_offset(&inp, "pkg_table"), 0)

	// 3. 2D Virtual Table Column Selection ('l'/'h') + Boundary Bubbling into sidebar!
	testing.expect_value(t, get_selected_col(&inp, "pkg_table"), 0)
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'l'}, Key_Event{code = .Right})
	testing.expect_value(t, get_selected_col(&inp, "pkg_table"), 2)

	// Rebuild to verify Virtual_Slice reports selected_col and total_cols
	build_virtual_workspace(&ctx, &scr, &inp, &last_slice)
	testing.expect_value(t, last_slice.selected_col, 2)
	testing.expect_value(t, last_slice.total_cols, 3)

	// Step Left twice back to col 0 -> stays inside pkg_table
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'h'}, Key_Event{code = .Left})
	testing.expect(t, is_focused(&inp, "pkg_table"))
	testing.expect_value(t, get_selected_col(&inp, "pkg_table"), 0)

	// Step Left once more at col 0 -> unhandled at pkg_table, bubbles to workspace, and focuses sidebar -> nav_home!
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'h'})
	testing.expect(t, is_focused(&inp, "nav_home"), "Pressing 'h' at column 0 of virtual table must bubble out to left sidebar")

	// Pressing 'l' from nav_home bubbles out of sidebar back into pkg_table!
	resolve_input(&inp, &ctx, Key_Event{code = .Rune, ch = 'l'})
	testing.expect(t, is_focused(&inp, "pkg_table"), "Pressing 'l' in sidebar must spatially enter pkg_table")
}

@(test)
test_two_pass_materialized_scroll_retention_and_lru_slot_eviction :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	scr: Screen
	testing.expect_value(t, screen_init(&scr, 80, 24), nil)
	defer screen_destroy(&scr)

	ctx: Layout_Context
	inp: Input_State

	build_scrollable_col :: proc(ctx: ^Layout_Context, scr: ^Screen) {
		begin_layout(ctx, 80, 24)
		begin_frame(scr)
		if container(ctx, "root", {dir = .Column, width = grow(1), height = grow(1)}) {
			if container(ctx, "mat_scroll", {
				dir         = .Column,
				width       = fixed(30),
				height      = fixed(6), // inner_rect.h = 4 rows; 6 cards * 2 rows = 12 -> max_offset = 8
				border      = .Plain,
				scrollable  = true,
				focus_flags = {.Focus_Scope},
			}) {
				for i in 0 ..< 6 {
					cid := fmt.tprintf("mcard_%d", i)
					ui_button(ctx, scr, cid, {label = cid, width = fixed(26), height = fixed(2)})
				}
			}
		}
		end_layout(ctx)
	}

	// 1. Frame 1: step down 4 cards so mat_scroll scrolls to offset 6
	build_scrollable_col(&ctx, &scr)
	resolve_input(
		&inp,
		&ctx,
		Key_Event{code = .Rune, ch = 'j'},
		Key_Event{code = .Rune, ch = 'j'},
		Key_Event{code = .Rune, ch = 'j'},
		Key_Event{code = .Rune, ch = 'j'},
	)
	testing.expect_value(t, get_scroll_offset(&inp, "mat_scroll"), 6)

	// Simulate a 2-pass mutating frame (re-running build_scrollable_col + apply_input_highlights without a second resolve_input)
	build_scrollable_col(&ctx, &scr)
	apply_input_highlights(&scr, &ctx, &inp)
	render_layout(&scr, &ctx)
	clip_4_pass2, _ := get_node_clip(&ctx, "mcard_4")
	testing.expect_value(t, clip_4_pass2.h, 2)
	testing.expect_value(t, get_scroll_offset(&inp, "mat_scroll"), 6)

	// Frame 2: next frame's Pass 1 must still preserve offset 6!
	build_scrollable_col(&ctx, &scr)
	resolve_input(&inp, &ctx)
	testing.expect_value(t, get_scroll_offset(&inp, "mat_scroll"), 6)

	// 2. LRU Scroll_Slot eviction: slot 0 with a recent last_layout_gen must NOT be evicted when MAX_SCROLL_SLOTS older slots exist
	inp.scroll_slots[0].last_layout_gen = 500
	for i := 1; i < MAX_SCROLL_SLOTS; i += 1 {
		inp.scroll_slots[i] = Scroll_Slot{
			id_hash         = u64(10_000 + i),
			last_layout_gen = u64(100 + i),
		}
	}
	// Slot 1 has the oldest last_layout_gen (101), so allocating an overflow slot must evict slot 1, preserving slot 0 ("mat_scroll")
	_ = get_scroll_slot(&inp, hash_id("new_overflow_scroll"))
	testing.expect_value(t, inp.scroll_slots[0].id_hash, hash_id("mat_scroll"))
	testing.expect_value(t, inp.scroll_slots[0].offset, 6)
	testing.expect_value(t, inp.scroll_slots[1].id_hash, hash_id("new_overflow_scroll"))
}

@(test)
test_try_resolve_hover_fast_path_respects_dirty_flag :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	ctx: Layout_Context
	layout_enable_arena(&ctx)
	defer layout_destroy(&ctx)
	begin_layout(&ctx, 40, 10)
	if container(&ctx, "root", Box_Config{dir = .Row, width = fixed(40), height = fixed(10)}) {
		leaf(&ctx, "chart_a", 20, 10, Box_Config{width = fixed(20), height = fixed(10), focus_flags = {.Focusable}})
		leaf(&ctx, "chart_b", 20, 10, Box_Config{width = fixed(20), height = fixed(10), focus_flags = {.Focusable}})
	}
	end_layout(&ctx)
	free_all(context.temp_allocator)

	inp: Input_State
	resolve_input(&inp, &ctx, Mouse_Event{x = 2, y = 2, action = .Move})
	testing.expect_value(t, inp.hovered_id, hash_id("chart_a"))

	// 1. Moving within `chart_a` with `dirty = false` short-circuits (.Hover_Unchanged)
	move_same := [1]Input_Event{Mouse_Event{x = 5, y = 3, action = .Move}}
	testing.expect_value(t, try_resolve_hover_fast_path(&inp, &ctx, move_same[:], false), Hover_Fast_Path_Result.Hover_Unchanged)
	testing.expect_value(t, inp.prev_hovered_id, hash_id("chart_a"))

	// 2. Moving within `chart_a` with `dirty = true` (e.g. background telemetry tick) MUST NOT short-circuit (.Not_Pure_Hover)
	move_dirty := [1]Input_Event{Mouse_Event{x = 25, y = 3, action = .Move}}
	testing.expect_value(t, try_resolve_hover_fast_path(&inp, &ctx, move_dirty[:], true), Hover_Fast_Path_Result.Not_Pure_Hover)
	testing.expect_value(t, inp.hovered_id, hash_id("chart_a"))

	// 3. Moving across into `chart_b` with `dirty = false` reports `.Hover_Changed` and updates `hovered_id`
	move_other := [1]Input_Event{Mouse_Event{x = 25, y = 3, action = .Move}}
	testing.expect_value(t, try_resolve_hover_fast_path(&inp, &ctx, move_other[:], false), Hover_Fast_Path_Result.Hover_Changed)
	testing.expect_value(t, inp.hovered_id, hash_id("chart_b"))
	testing.expect_value(t, inp.prev_hovered_id, hash_id("chart_a"))

	// 4. `.Leave` clears hover once as `.Hover_Changed`, then repeats as `.Hover_Unchanged`
	leave_ev := [1]Input_Event{Mouse_Event{action = .Leave}}
	testing.expect_value(t, try_resolve_hover_fast_path(&inp, &ctx, leave_ev[:], false), Hover_Fast_Path_Result.Hover_Changed)
	testing.expect_value(t, inp.prev_hovered_id, hash_id("chart_b"))
	testing.expect_value(t, inp.hovered_id, u64(0))
	testing.expect_value(t, try_resolve_hover_fast_path(&inp, &ctx, leave_ev[:], false), Hover_Fast_Path_Result.Hover_Unchanged)

	// 5. Active chord, mouse_down, or mixed button press rejects the fast path
	inp.pending_chord.active = true
	testing.expect_value(t, try_resolve_hover_fast_path(&inp, &ctx, move_same[:], false), Hover_Fast_Path_Result.Not_Pure_Hover)
	inp.pending_chord.active = false

	inp.mouse_down = true
	testing.expect_value(t, try_resolve_hover_fast_path(&inp, &ctx, move_same[:], false), Hover_Fast_Path_Result.Not_Pure_Hover)
	inp.mouse_down = false

	mixed := [2]Input_Event{Mouse_Event{x = 5, y = 3, action = .Move}, Mouse_Event{x = 5, y = 3, button = .Left, action = .Press}}
	testing.expect_value(t, try_resolve_hover_fast_path(&inp, &ctx, mixed[:], false), Hover_Fast_Path_Result.Not_Pure_Hover)
}

@(test)
test_scroll_node_into_view_terminates_on_parent_cycles :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	ctx: Layout_Context
	begin_layout(&ctx, 40, 10)
	if container(&ctx, "root", Box_Config{dir = .Column, width = fixed(40), height = fixed(10)}) {
		if container(&ctx, "child_a", Box_Config{dir = .Column, width = fixed(40), height = fixed(10)}) {
			leaf(&ctx, "child_b", 40, 10, Box_Config{width = fixed(40), height = fixed(10)})
		}
	}
	end_layout(&ctx)

	inp: Input_State
	ctx.nodes[0].parent_idx = 0
	scroll_node_into_view(&inp, &ctx, 1)

	ctx.nodes[1].parent_idx = 2
	ctx.nodes[2].parent_idx = 1
	scroll_node_into_view(&inp, &ctx, 2)
}
