package bifrost_tests

import "core:testing"
import "../bifrost"

// =============================================================================
// Layer 1: Executable Specifications (Track 2: Focus, Input & Hit-Testing)
// =============================================================================

@(test)
@(scenario)
spec_three_phase_event_dispatch_and_capture_short_circuit :: proc(t: ^testing.T) {
	_ = scenario(t, w = 80, h = 24)

	given.focused_widget("save_btn")
	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root_panel", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			if bifrost.container(ctx, "toolbar", {dir = .Row, width = bifrost.grow(1), height = bifrost.fixed(3)}) {
				bifrost.ui_button(ctx, scr, "save_btn", {label = "Save"})
			}
		}
	})
	then.focused_widget_is("save_btn")

	// 1. Pressing Enter traverses Capturing (root_panel -> toolbar), At_Target (save_btn), and Bubbling (toolbar -> root_panel)
	upon.pressing_key(.Enter)
	then.dispatch_steps_are([]bifrost.Dispatch_Step{
		{id = "root_panel", phase = .Capturing},
		{id = "toolbar",    phase = .Capturing},
		{id = "save_btn",   phase = .At_Target},
		{id = "toolbar",    phase = .Bubbling},
		{id = "root_panel", phase = .Bubbling},
	})
	then.activated_widget_is("save_btn")

	// 2. When toolbar consumes events during Capturing, propagation halts before reaching save_btn
	given.widget_consumes_at("toolbar", .Capturing)
	upon.pressing_key(.Enter)
	then.dispatch_steps_are([]bifrost.Dispatch_Step{
		{id = "root_panel", phase = .Capturing},
		{id = "toolbar",    phase = .Capturing},
	})
	then.activated_widget_is("")
}

@(test)
spec_scoped_tab_cycling_f6_pane_switching_and_modal_dismissal :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, w = 60, h = 20)
	defer driver_destroy(&s)

	build_scoped_ui :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen, show_modal: bool) {
		if bifrost.container(ctx, "root", {dir = .Row, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			if bifrost.container(ctx, "sidebar", {
				dir         = .Column,
				width       = bifrost.fixed(20),
				height      = bifrost.grow(1),
				border      = .Plain,
				gap         = 1,
				focus_scope = true,
			}) {
				bifrost.ui_button(ctx, scr, "nav_logs", {label = "Logs"})
				bifrost.ui_button(ctx, scr, "nav_metrics", {label = "Metrics"})

				if show_modal {
					if bifrost.ui_modal(ctx, scr, "confirm_modal", {
						title   = "Confirm Compaction",
						z_layer = 20,
						width   = bifrost.fixed(30),
						height  = bifrost.fixed(8),
						border  = .Double,
						gap     = 1,
					}) {
						bifrost.ui_button(ctx, scr, "modal_yes", {label = "Yes"})
						bifrost.ui_button(ctx, scr, "modal_no", {label = "No"})
					}
				}
			}
			if bifrost.container(ctx, "main_panel", {
				dir         = .Column,
				width       = bifrost.grow(1),
				height      = bifrost.grow(1),
				border      = .Plain,
				focus_scope = true,
			}) {
				bifrost.ui_button(ctx, scr, "main_compact_btn", {label = "Compact DB"})
			}
		}
	}

	// Frame 1: Base UI without modal
	upon_rendering_frame(&s, proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		build_scoped_ui(ctx, scr, false)
	})
	then_focused_widget_is(&s, "nav_logs")

	// Tab cycles strictly within sidebar focus_scope
	upon_pressing_key(&s, .Tab)
	then_focused_widget_is(&s, "nav_metrics")
	upon_pressing_key(&s, .Tab)
	then_focused_widget_is(&s, "nav_logs")
	upon_pressing_key(&s, .Tab, {.Shift})
	then_focused_widget_is(&s, "nav_metrics")

	// F6 switches between focus scopes (sidebar -> main_panel)
	upon_pressing_key(&s, .F6)
	then_focused_widget_is(&s, "main_compact_btn")

	// Frame 2: Modal opens at z_layer = 20
	upon_rendering_frame(&s, proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		build_scoped_ui(ctx, scr, true)
	})
	then_focused_widget_is(&s, "modal_yes")

	// Tab & Shift+Tab trap focus inside modal; F6 cannot escape modal
	upon_pressing_key(&s, .Tab)
	then_focused_widget_is(&s, "modal_no")
	upon_pressing_key(&s, .Tab)
	then_focused_widget_is(&s, "modal_yes")
	upon_pressing_key(&s, .Tab, {.Shift})
	then_focused_widget_is(&s, "modal_no")
	upon_pressing_key(&s, .F6)
	then_focused_widget_is(&s, "modal_no")

	// Clicking background nav_logs is blocked and reports backdrop dismissal
	nav_rect, _ := bifrost.get_rect(&s.layout_ctx, "nav_logs")
	upon_mouse_click(&s, nav_rect.x + 1, nav_rect.y)
	then_activated_widget_is(&s, "")
	then_modal_dismissed_is(&s, "confirm_modal", true)

	// Pressing Escape also reports modal dismissal
	upon_pressing_key(&s, .Escape)
	then_modal_dismissed_is(&s, "confirm_modal", true)
}

@(test)
spec_nested_modals_shield_and_lifo_focus_restoration :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, w = 80, h = 24)
	defer driver_destroy(&s)

	build_nested_modals_ui :: proc(
		ctx: ^bifrost.Layout_Context,
		scr: ^bifrost.Screen,
		show_confirm: bool,
		show_palette: bool,
	) {
		if bifrost.container(ctx, "base_root", {dir = .Row, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_button(ctx, scr, "editor_a", {label = "Editor A", width = bifrost.fixed(20), height = bifrost.fixed(3)})
			bifrost.ui_button(ctx, scr, "editor_b", {label = "Editor B", width = bifrost.fixed(20), height = bifrost.fixed(3)})

			if show_confirm {
				if bifrost.ui_modal(ctx, scr, "confirm_modal", {
					title   = "Confirm",
					z_layer = 20,
					width   = bifrost.fixed(40),
					height  = bifrost.fixed(8),
					border  = .Double,
					gap     = 1,
				}) {
					bifrost.ui_button(ctx, scr, "confirm_cancel", {label = "Cancel"})
					bifrost.ui_button(ctx, scr, "confirm_ok", {label = "OK"})
				}
			}

			if show_palette {
				if bifrost.ui_modal(ctx, scr, "palette_modal", {
					title   = "Command Palette",
					z_layer = 30,
					width   = bifrost.fixed(30),
					height  = bifrost.fixed(5),
					border  = .Double,
				}) {
					bifrost.ui_button(ctx, scr, "palette_input", {label = "Search..."})
				}
			}
		}
	}

	// 1. Base UI (z = 0) focused on editor_b
	given_focused_widget(&s, "editor_b")
	upon_rendering_frame(&s, proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		build_nested_modals_ui(ctx, scr, false, false)
	})
	then_focused_widget_is(&s, "editor_b")

	// 2. Open Confirmation Modal (z = 20) -> focus moves to confirm_cancel, then Tab to confirm_ok
	upon_rendering_frame(&s, proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		build_nested_modals_ui(ctx, scr, true, false)
	})
	then_focused_widget_is(&s, "confirm_cancel")
	upon_pressing_key(&s, .Tab)
	then_focused_widget_is(&s, "confirm_ok")

	// Clicking editor_a at (2, 1) is blocked by z = 20 shield
	upon_mouse_click(&s, 2, 1)
	then_activated_widget_is(&s, "")
	then_focused_widget_is(&s, "confirm_ok")

	// 3. Open Command Palette (z = 30) on top of Confirmation Modal (z = 20)
	upon_rendering_frame(&s, proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		build_nested_modals_ui(ctx, scr, true, true)
	})
	then_focused_widget_is(&s, "palette_input")

	// Clicking confirm_ok inside z = 20 is blocked by z = 30 shield
	ok_rect, _ := bifrost.get_rect(&s.layout_ctx, "confirm_ok")
	upon_mouse_click(&s, ok_rect.x + 1, ok_rect.y)
	then_activated_widget_is(&s, "")
	then_focused_widget_is(&s, "palette_input")

	// 4. Close Command Palette (z = 30) while Confirmation Modal (z = 20) remains mounted
	// Focus must restore in LIFO order to confirm_ok (not confirm_cancel and not editor_b!)
	upon_rendering_frame(&s, proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		build_nested_modals_ui(ctx, scr, true, false)
	})
	then_focused_widget_is(&s, "confirm_ok")

	// And Base UI (z = 0) remains shielded by Confirmation Modal (z = 20)
	upon_mouse_click(&s, 2, 1)
	then_activated_widget_is(&s, "")

	// 5. Close Confirmation Modal (z = 20) -> focus restores to editor_b in Base UI (z = 0)
	upon_rendering_frame(&s, proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		build_nested_modals_ui(ctx, scr, false, false)
	})
	then_focused_widget_is(&s, "editor_b")
}

@(test)
@(scenario)
spec_active_press_mouse_capture_off_axis_drag_and_press_cancel :: proc(t: ^testing.T) {
	s := scenario(t, w = 80, h = 24)

	s->upon_rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Row, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.leaf(ctx, "left_pane", 20, 20, {width = bifrost.fixed(20), height = bifrost.fixed(20)})
			// 1-column splitter bar at x = 20
			bifrost.leaf(ctx, "splitter", 1, 20, {
				width     = bifrost.fixed(1),
				height    = bifrost.fixed(20),
				focusable = true,
				draggable = true,
				hoverable = true,
				splitter  = true,
			})
			// Adjacent button at x = 25..35, y = 2..4
			if bifrost.container(ctx, "right_pane", {
				dir     = .Column,
				width   = bifrost.grow(1),
				height  = bifrost.grow(1),
				padding = {left = 4, top = 2},
			}) {
				bifrost.ui_button(ctx, scr, "run_btn", {
					label  = "Run",
					width  = bifrost.fixed(10),
					height = bifrost.fixed(2),
				})
			}
		}
	})

	// 1. Press left mouse on 1-column splitter (x = 20, y = 3) and drag outside to x = 28 (over run_btn)
	s->upon_mouse_press(20, 3)
	s->upon_mouse_drag(28, 3)

	// Splitter retains active_press_id, receives +8 drag delta, and suppresses background hover on run_btn
	s->then_active_press_is("splitter")
	s->then_drag_delta_is(8, 0)
	s->then_hovered_widget_is("")

	// 2. Release mouse at x = 28 (over run_btn): clears active_press_id, does NOT activate run_btn,
	// and transfers hover to run_btn
	s->upon_mouse_release(28, 3)
	s->then_active_press_is("")
	s->then_activated_widget_is("")
	s->then_hover_transition_is(hovered_id = "run_btn", entered_id = "run_btn", left_id = "")

	// 3. Press run_btn, drag outside to x = 5, release outside -> press-cancel (no activation)
	s->upon_mouse_press(28, 3)
	s->upon_mouse_drag(5, 3)
	s->upon_mouse_release(5, 3)
	s->then_activated_widget_is("")

	// 4. Press run_btn, drag outside to x = 5, drag back inside to x = 27, release inside -> activates run_btn!
	s->upon_mouse_press(28, 3)
	s->upon_mouse_drag(5, 3)
	s->then_activated_widget_is("")
	s->upon_mouse_drag(27, 3)
	s->upon_mouse_release(27, 3)
	s->then_activated_widget_is("run_btn")
}

@(test)
spec_clipped_hit_testing_and_stationary_scroll_hover_transitions :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, w = 80, h = 24)
	defer driver_destroy(&s)

	build_scroll_ui :: proc(
		ctx: ^bifrost.Layout_Context,
		scr: ^bifrost.Screen,
		store: ^bifrost.Widget_State_Store,
		row_ids: []string,
	) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.fixed(40), height = bifrost.fixed(20)}) {
			if len(row_ids) > 0 {
				persisted := bifrost.state_store_get_scroll(store, "scroll_list", default_step = 4)
				if bifrost.container(ctx, "scroll_list", {
					dir           = .Column,
					width         = bifrost.fixed(40),
					height        = bifrost.fixed(6),
					gap           = 2,
					scrollable    = true,
					scroll_step   = persisted.wheel_step,
					scroll_offset = persisted.scroll_offset[1],
				}) {
					for id in row_ids {
						bifrost.ui_button(ctx, scr, id, {
							label  = id,
							width  = bifrost.fixed(40),
							height = bifrost.fixed(2),
						})
					}
				}
			}
			// Footer button directly below scroll_list at y = 6..8 (or y = 0..2 when unmounted)
			bifrost.ui_button(ctx, scr, "footer_btn", {
				label  = "Footer",
				width  = bifrost.fixed(40),
				height = bifrost.fixed(2),
			})
		}
	}

	// --- Frame 1: Initial mount (scroll_offset = 0, max_scroll = 10 - 6 = 4) ---
	// row_1: y = 0..2 (visible)
	// row_2: y = 4..6 (visible)
	// row_3: y = 8..10 (clipped out below viewport y = 0..6!)
	// footer_btn: y = 6..8 (below scroll_list)
	driver_begin_frame(&s)
	build_scroll_ui(&s.layout_ctx, &s.screen, &s.state_store, []string{"row_1", "row_2", "row_3"})
	driver_end_frame(&s)

	then_persisted_scroll_is(&s, "scroll_list", offset_y = 0, max_y = 4)
	then_node_clip_is(&s, "row_1", {x = 0, y = 0, w = 40, h = 2})
	then_node_clip_is(&s, "row_3", {x = 0, y = 8, w = 0, h = 0})

	// Clicking at y = 8 (inside row_3.rect, but row_3.node_clip is empty!) must NOT ghost-click row_3
	upon_mouse_click(&s, 5, 8)
	then_activated_widget_is(&s, "")

	// Clicking at y = 7 hits footer_btn
	upon_mouse_click(&s, 5, 7)
	then_activated_widget_is(&s, "footer_btn")

	// Move mouse to (5, 1) -> hovers row_1
	upon_mouse_move(&s, 5, 1)
	then_hover_transition_is(&s, hovered_id = "row_1", entered_id = "row_1", left_id = "footer_btn")

	// Scroll wheel down at (5, 1) -> scrolls scroll_list by +4 (offset_y = 4)
	upon_mouse_scroll(&s, 5, 1, .Scroll_Down)
	then_persisted_scroll_is(&s, "scroll_list", offset_y = 4, max_y = 4)

	// --- Frame 2: Rebuild with persisted scroll_offset = 4 under stationary cursor at (5, 1) ---
	driver_begin_frame(&s)
	build_scroll_ui(&s.layout_ctx, &s.screen, &s.state_store, []string{"row_1", "row_2", "row_3"})
	driver_end_frame(&s)

	then_node_clip_is(&s, "row_1", {x = 0, y = 0, w = 0, h = 0}) // Clipped out above
	then_node_clip_is(&s, "row_2", {x = 0, y = 0, w = 40, h = 2}) // Shifted to y = 0..2
	then_node_clip_is(&s, "row_3", {x = 0, y = 4, w = 40, h = 2}) // Shifted to y = 4..6

	// Stationary cursor at (5, 1) automatically leaves row_1 and enters row_2
	then_hover_transition_is(&s, hovered_id = "row_2", entered_id = "row_2", left_id = "row_1")

	// Clicking at (5, 5) now activates newly visible row_3
	upon_mouse_click(&s, 5, 5)
	then_activated_widget_is(&s, "row_3")

	// --- Frame 3: Shrink content to 1 row ("row_1") -> clamps scroll_offset from 4 -> 0 ---
	driver_begin_frame(&s)
	build_scroll_ui(&s.layout_ctx, &s.screen, &s.state_store, []string{"row_1"})
	driver_end_frame(&s)

	then_persisted_scroll_is(&s, "scroll_list", offset_y = 0, max_y = 0)
	then_node_clip_is(&s, "row_1", {x = 0, y = 0, w = 40, h = 2})

	// --- Frame 4: Unmount scroll_list -> Widget_State_Store prunes "scroll_list" ---
	driver_begin_frame(&s)
	build_scroll_ui(&s.layout_ctx, &s.screen, &s.state_store, nil)
	driver_end_frame(&s)

	then_state_store_contains(&s, "scroll_list", false)
}


@(test)
spec_disabled_widget_and_subtree_auto_advance_and_floating_window_bring_to_front :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, w = 80, h = 24)
	defer driver_destroy(&s)

	build_disabled_and_floating_ui :: proc(
		s: ^Suite_Ctx,
		disable_btn_2: bool,
		disable_group: bool,
		events: ..bifrost.Input_Event,
	) {
		driver_begin_frame(s, bifrost.rgb(18, 22, 30))
		if bifrost.container(&s.layout_ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_button(&s.layout_ctx, &s.screen, "btn_1", {label = "One"})
			b2_flags := bifrost.Focus_Flags{.Disabled} if disable_btn_2 else bifrost.Focus_Flags{}
			bifrost.ui_button(&s.layout_ctx, &s.screen, "btn_2", {label = "Two", focus_flags = b2_flags})

			grp_flags := bifrost.Focus_Flags{.Disabled} if disable_group else bifrost.Focus_Flags{}
			if bifrost.container(&s.layout_ctx, "sub_grp", {
				dir         = .Row,
				width       = bifrost.fit(),
				height      = bifrost.fit(),
				focus_flags = grp_flags,
			}) {
				bifrost.ui_button(&s.layout_ctx, &s.screen, "btn_3", {label = "Three"})
			}

			// Two overlapping non-modal floating tool windows at z_layer = 10
			if bifrost.container(&s.layout_ctx, "float_a", {
				dir         = .Column,
				width       = bifrost.fixed(20),
				height      = bifrost.fixed(4),
				z_layer     = 10,
				floating    = true,
				offset      = {10, 8},
				focus_flags = {.Focus_Scope},
			}) {
				bifrost.ui_button(&s.layout_ctx, &s.screen, "float_a_btn", {
					label  = "Float A",
					width  = bifrost.fixed(18),
					height = bifrost.fixed(2),
				})
			}
			if bifrost.container(&s.layout_ctx, "float_b", {
				dir         = .Column,
				width       = bifrost.fixed(20),
				height      = bifrost.fixed(4),
				z_layer     = 10,
				floating    = true,
				offset      = {10, 8},
				focus_flags = {.Focus_Scope},
			}) {
				bifrost.ui_button(&s.layout_ctx, &s.screen, "float_b_btn", {
					label  = "Float B",
					width  = bifrost.fixed(18),
					height = bifrost.fixed(2),
				})
			}
		}
		driver_end_frame(s, ..events)
	}

	// 1. Focus btn_2 via Tab, then mark btn_2 .Disabled on next frame -> auto-advances off disabled btn_2
	build_disabled_and_floating_ui(&s, false, false, bifrost.Key_Event{code = .Tab})
	then_focused_widget_is(&s, "btn_2")

	build_disabled_and_floating_ui(&s, true, false)
	then_focused_widget_is(&s, "btn_1")

	// Clicking disabled btn_2 must not focus or activate it
	upon_clicking_widget(&s, "btn_2")
	then_activated_widget_is(&s, "")
	then_focused_widget_is(&s, "btn_1")

	// 2. Focus btn_3 inside sub_grp, then disable ancestor sub_grp -> inherited .Disabled evacuates focus
	upon_requesting_focus(&s, "btn_3")
	build_disabled_and_floating_ui(&s, true, false)
	then_focused_widget_is(&s, "btn_3")

	build_disabled_and_floating_ui(&s, true, true)
	then_focused_widget_is(&s, "btn_1")

	// 3. Promoting non-modal floating window float_a brings it in front of sibling float_b at z_layer=10
	upon_requesting_focus(&s, "float_a_btn")
	build_disabled_and_floating_ui(&s, false, false)
	then_focused_widget_is(&s, "float_a_btn")

	build_disabled_and_floating_ui(
		&s,
		false,
		false,
		bifrost.Mouse_Event{x = 12, y = 8, action = .Press, button = .Left},
		bifrost.Mouse_Event{x = 12, y = 8, action = .Release, button = .Left},
	)
	then_activated_widget_is(&s, "float_a_btn")
}

