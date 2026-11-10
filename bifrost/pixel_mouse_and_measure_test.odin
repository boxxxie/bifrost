package bifrost

import "core:testing"

@(test)
test_mouse_event_from_pixels_and_measure_text_intrinsic_hook :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// 1. Positive sub-cell pixel mouse coordinate conversion
	ev := mouse_event_from_pixels(23.5, 39.25, 9.0, 18.0, .Drag, .Left, {.Shift, .Ctrl})
	testing.expect_value(t, ev.x, 2)
	testing.expect_value(t, ev.y, 2)
	testing.expect_value(t, ev.col, 2)
	testing.expect_value(t, ev.row, 2)
	testing.expect_value(t, ev.x_offset, 5)
	testing.expect_value(t, ev.y_offset, 3)
	testing.expect_value(t, ev.action, Mouse_Action.Drag)
	testing.expect_value(t, ev.button, Mouse_Button.Left)
	testing.expect_value(t, ev.mods, Mod_Flags{.Shift, .Ctrl})

	// 2. Negative pixel coordinates floor toward -inf during out-of-window drags
	ev_neg := mouse_event_from_pixels(-0.5, -18.5, 9.0, 18.0, .Drag, .Left)
	testing.expect_value(t, ev_neg.x, -1)
	testing.expect_value(t, ev_neg.y, -2)
	testing.expect_value(t, ev_neg.col, -1)
	testing.expect_value(t, ev_neg.row, -2)
	testing.expect_value(t, ev_neg.x_offset, 8)
	testing.expect_value(t, ev_neg.y_offset, 17)

	ev_edge := mouse_event_from_pixels(-9.0, -18.0, 9.0, 18.0, .Move)
	testing.expect_value(t, ev_edge.x, -1)
	testing.expect_value(t, ev_edge.y, -1)
	testing.expect_value(t, ev_edge.x_offset, 0)
	testing.expect_value(t, ev_edge.y_offset, 0)

	// 3. Pluggable Layout_Context.measure_text_fn hook in Pass 1
	scale_factor: i32 = 2
	custom_measure :: proc "contextless" (text: string, userdata: rawptr) -> (unwrapped_w, longest_word, line_count: i32) {
		factor := (^i32)(userdata)^ if userdata != nil else 1
		w, lw, lc := measure_text_intrinsic(text)
		return w * factor, lw * factor, lc
	}

	ctx: Layout_Context
	begin_layout(&ctx, 80, 24, context.temp_allocator)
	ctx.measure_text_fn  = custom_measure
	ctx.measure_userdata = &scale_factor

	if container(&ctx, "root", {dir = .Row, width = fixed(80), height = fixed(24)}) {
		leaf(&ctx, "lbl", 0, 1, {width = fit(), height = fit(), text = "hello"})
	}
	end_layout(&ctx)

	lbl_rect, ok := get_rect(&ctx, "lbl")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, lbl_rect.w, 10)
	testing.expect_value(t, lbl_rect.h, 1)
}

@(test)
test_mouse_event_from_sgr_pixels_decodes_buttons_motion_wheel_and_mods :: proc(t: ^testing.T) {
	// 1-based pixel (1, 1) -> cell (0, 0), sub-cell offset (0, 0), Left Press
	ev_press, ok1 := mouse_event_from_sgr_pixels(0, 1, 1, false, 10.0, 20.0)
	testing.expect_value(t, ok1, true)
	testing.expect_value(t, ev_press.x, 0)
	testing.expect_value(t, ev_press.y, 0)
	testing.expect_value(t, ev_press.x_offset, 0)
	testing.expect_value(t, ev_press.y_offset, 0)
	testing.expect_value(t, ev_press.action, Mouse_Action.Press)
	testing.expect_value(t, ev_press.button, Mouse_Button.Left)

	// Shift (4) + Ctrl (16) + Motion (32) + Right (2) = 54 at 1-based (26, 48) -> px (25, 47) -> cell (2, 2), offset (5, 7)
	ev_drag, ok2 := mouse_event_from_sgr_pixels(54, 26, 48, false, 10.0, 20.0)
	testing.expect_value(t, ok2, true)
	testing.expect_value(t, ev_drag.x, 2)
	testing.expect_value(t, ev_drag.y, 2)
	testing.expect_value(t, ev_drag.x_offset, 5)
	testing.expect_value(t, ev_drag.y_offset, 7)
	testing.expect_value(t, ev_drag.action, Mouse_Action.Drag)
	testing.expect_value(t, ev_drag.button, Mouse_Button.Right)
	testing.expect_value(t, ev_drag.mods, Mod_Flags{.Shift, .Ctrl})

	// Pure hover motion: Motion (32) + None (3) = 35
	ev_move, ok3 := mouse_event_from_sgr_pixels(35, 15, 25, false, 10.0, 20.0)
	testing.expect_value(t, ok3, true)
	testing.expect_value(t, ev_move.action, Mouse_Action.Move)
	testing.expect_value(t, ev_move.button, Mouse_Button.None)

	// Wheel scroll down (64 + 1 = 65); wheel release ('m') is ignored
	ev_wheel, ok4 := mouse_event_from_sgr_pixels(65, 11, 21, false, 10.0, 20.0)
	testing.expect_value(t, ok4, true)
	testing.expect_value(t, ev_wheel.action, Mouse_Action.Scroll_Down)
	_, ok_wheel_rel := mouse_event_from_sgr_pixels(65, 11, 21, true, 10.0, 20.0)
	testing.expect_value(t, ok_wheel_rel, false)

	// VT parser SGR-Pixels integration (`parse_ansi_input` with `sgr_pixel_mode = true`)
	vt_ev, vt_n, vt_st := parse_ansi_input(transmute([]byte)string("\x1b[<54;26;48M"), false, true, 10.0, 20.0)
	testing.expect_value(t, vt_st, Parse_Status.Ok)
	testing.expect_value(t, vt_n, 12)
	vt_m := vt_ev.(Mouse_Event)
	testing.expect_value(t, vt_m.x, 2)
	testing.expect_value(t, vt_m.y, 2)
	testing.expect_value(t, vt_m.x_offset, 5)
	testing.expect_value(t, vt_m.y_offset, 7)
	testing.expect_value(t, vt_m.action, Mouse_Action.Drag)
	testing.expect_value(t, vt_m.button, Mouse_Button.Right)
	testing.expect_value(t, vt_m.mods, Mod_Flags{.Shift, .Ctrl})
}
