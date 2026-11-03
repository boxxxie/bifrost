package bifrost

import "core:testing"

@(private)
build_input_test_ui :: proc(ctx: ^Layout_Context, scr: ^Screen, show_modal: bool) {
	begin_layout(ctx, 60, 20)
	begin_frame(scr, rgb(20, 25, 30))
	if container(ctx, "root", {dir = .Row, width = grow(1), height = grow(1)}) {
		if container(ctx, "sidebar", {
			dir         = .Column,
			width       = fixed(20),
			height      = grow(1),
			border      = .Plain,
			gap         = 1,
			focus_scope = true,
		}) {
			ui_button(ctx, scr, "nav_logs", {label = "Logs"})
			ui_button(ctx, scr, "nav_metrics", {label = "Metrics"})

			if show_modal {
				if ui_modal(ctx, scr, "confirm_modal", {
					title   = "Confirm Compaction",
					z_layer = 20,
					width   = fixed(30),
					height  = fixed(8),
					border  = .Double,
					gap     = 1,
				}) {
					ui_button(ctx, scr, "modal_yes", {label = "Yes"})
					ui_button(ctx, scr, "modal_no", {label = "No"})
				}
			}
		}
		if container(ctx, "main_panel", {
			dir         = .Column,
			width       = grow(1),
			height      = grow(1),
			border      = .Plain,
			focus_scope = true,
		}) {
			ui_button(ctx, scr, "main_compact_btn", {label = "Compact DB"})
		}
	}
	end_layout(ctx)
}

@(test)
test_scoped_tab_and_modal_input_capture :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	scr: Screen
	err := screen_init(&scr, 60, 20)
	testing.expect_value(t, err, nil)
	defer screen_destroy(&scr)

	ctx: Layout_Context
	inp: Input_State

	// Frame 1: Base UI (No Modal)
	build_input_test_ui(&ctx, &scr, false)
	resolve_input(&inp, &ctx)

	testing.expect(t, is_focused(&inp, "nav_logs"), "Initial focus should be nav_logs")

	resolve_input(&inp, &ctx, Key_Event{code = .Tab})
	testing.expect(t, is_focused(&inp, "nav_metrics"), "Tab should advance to nav_metrics")

	resolve_input(&inp, &ctx, Key_Event{code = .Tab})
	testing.expect(t, is_focused(&inp, "nav_logs"), "Tab should wrap inside sidebar focus_scope")

	resolve_input(&inp, &ctx, Key_Event{code = .F6})
	testing.expect(t, is_focused(&inp, "main_compact_btn"), "F6 should switch focus scope to main_compact_btn")

	// Frame 2: Modal Opens (z_layer = 20, capture_input = true)
	build_input_test_ui(&ctx, &scr, true)
	resolve_input(&inp, &ctx)

	testing.expect(t, is_focused(&inp, "modal_yes"), "Opening modal should trap focus on modal_yes")
	testing.expect_value(t, inp.focus_history_len, 1)

	resolve_input(&inp, &ctx, Key_Event{code = .Tab})
	testing.expect(t, is_focused(&inp, "modal_no"), "Tab inside modal should focus modal_no")

	resolve_input(&inp, &ctx, Key_Event{code = .Tab})
	testing.expect(t, is_focused(&inp, "modal_yes"), "Tab inside modal should wrap to modal_yes")

	resolve_input(&inp, &ctx, Key_Event{code = .Tab, mods = {.Shift}})
	testing.expect(t, is_focused(&inp, "modal_no"), "Shift+Tab should cycle backward to modal_no")

	resolve_input(&inp, &ctx, Key_Event{code = .F6})
	testing.expect(t, is_focused(&inp, "modal_no"), "F6 must not escape an active capturing modal")

	// Frame 3: Mouse Click Outside Modal vs Inside Modal
	nav_logs_rect, _ := get_rect(&ctx, "nav_logs")
	resolve_input(
		&inp,
		&ctx,
		Mouse_Event{x = nav_logs_rect.x + 1, y = nav_logs_rect.y, action = .Press, button = .Left},
		Mouse_Event{x = nav_logs_rect.x + 1, y = nav_logs_rect.y, action = .Release, button = .Left},
	)
	testing.expect(t, !was_activated(&inp, "nav_logs"), "Background button must be shielded by active modal")
	testing.expect(t, was_modal_dismissed(&inp, "confirm_modal"), "Outside click should report backdrop dismissal")

	yes_rect, _ := get_rect(&ctx, "modal_yes")
	resolve_input(
		&inp,
		&ctx,
		Mouse_Event{x = yes_rect.x + 1, y = yes_rect.y, action = .Press, button = .Left},
		Mouse_Event{x = yes_rect.x + 1, y = yes_rect.y, action = .Release, button = .Left},
	)
	testing.expect(t, was_activated(&inp, "modal_yes"), "Clicking modal_yes should activate it")
	testing.expect(t, is_focused(&inp, "modal_yes"), "Clicking modal_yes should focus it")

	// Frame 4: Modal Closes -> Focus Automatically Restores to "main_compact_btn"
	build_input_test_ui(&ctx, &scr, false)
	resolve_input(&inp, &ctx)

	testing.expect(t, is_focused(&inp, "main_compact_btn"), "Closing modal should restore focus to main_compact_btn")
	testing.expect_value(t, inp.focus_history_len, 0)
}
