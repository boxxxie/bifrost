package bifrost_tests

import "core:testing"
import "../bifrost"

// =============================================================================
// Layer 1: Executable Specifications for Track 16
//          (Progress Bars, Gauges & Indeterminate Spinners)
// =============================================================================

@(private="file")
s_test_thresholds := [3]bifrost.Gauge_Threshold{
	{above = 0.0, fg = bifrost.Color{kind = .RGB, r = 60, g = 220, b = 80}},
	{above = 0.7, fg = bifrost.Color{kind = .RGB, r = 255, g = 200, b = 40}},
	{above = 0.9, fg = bifrost.Color{kind = .RGB, r = 255, g = 60, b = 60}},
}

@(test)
@(scenario)
spec_progress_subcell_eighths_calculation :: proc(t: ^testing.T) {
	_ = scenario(t, w = 40, h = 10)

	// Width 10 cells -> 80 eighths
	// Ratio 0.0 -> 0 full, 0 rem
	then.progress_subcell_eighths_are(0.0, 10, 0, 0)

	// Ratio 0.05 -> 4 eighths -> 0 full, 4 rem ('▌')
	then.progress_subcell_eighths_are(0.05, 10, 0, 4)

	// Ratio 0.125 on width 8 (64 eighths) -> 8 eighths -> 1 full, 0 rem
	then.progress_subcell_eighths_are(0.125, 8, 1, 0)

	// Ratio 0.35 on width 10 -> 28 eighths -> 3 full, 4 rem ('▌')
	then.progress_subcell_eighths_are(0.35, 10, 3, 4)

	// Ratio 0.50 on width 10 -> 40 eighths -> 5 full, 0 rem
	then.progress_subcell_eighths_are(0.50, 10, 5, 0)

	// Ratio 1.0 on width 10 -> 80 eighths -> 10 full, 0 rem
	then.progress_subcell_eighths_are(1.0, 10, 10, 0)
}

@(test)
@(scenario)
spec_progress_bar_render_subcell_blocks :: proc(t: ^testing.T) {
	_ = scenario(t, w = 20, h = 5)

	fill_color := bifrost.rgb(60, 160, 240)
	track_color := bifrost.rgb(25, 30, 40)

	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.fixed(10), height = bifrost.fixed(1)}) {
			bifrost.ui_progress_bar(ctx, scr, "pb_subcell", bifrost.Progress_Bar_Config{
				ratio       = 0.35,
				filled_fg   = bifrost.rgb(60, 160, 240),
				unfilled_bg = bifrost.rgb(25, 30, 40),
			})
		}
	})

	// Width 10, ratio 0.35 -> 3 full cells ('█'), 1 subcell ('▌' = 4 eighths), 6 empty (' ')
	then.cell_at_is(0, 0, '█', 1)
	then.cell_at_is(1, 0, '█', 1)
	then.cell_at_is(2, 0, '█', 1)
	then.cell_at_is(3, 0, '▌', 1)
	then.cell_at_is(4, 0, ' ', 1)
	then.cell_at_is(9, 0, ' ', 1)

	// Full blocks foreground and track background
	then.cell_colors_at_are(0, 0, fill_color, track_color)
	// Partial subcell: left half filled fg, right half unfilled bg
	then.cell_colors_at_are(3, 0, fill_color, track_color)
	// Empty cell bg
	then.cell_colors_at_are(4, 0, bifrost.rgb(120, 130, 145), track_color)
}

@(test)
@(scenario)
spec_progress_bar_centered_label_contrast :: proc(t: ^testing.T) {
	_ = scenario(t, w = 20, h = 5)

	fill_color := bifrost.rgb(80, 200, 120)
	track_color := bifrost.rgb(30, 35, 45)
	text_fill_fg := bifrost.rgb(10, 20, 10)
	text_unfill_fg := bifrost.rgb(240, 240, 240)

	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.fixed(10), height = bifrost.fixed(1)}) {
			bifrost.ui_progress_bar(ctx, scr, "pb_label", bifrost.Progress_Bar_Config{
				ratio            = 0.50,
				label            = " 50% ",
				filled_fg        = bifrost.rgb(80, 200, 120),
				unfilled_bg      = bifrost.rgb(30, 35, 45),
				text_filled_fg   = bifrost.rgb(10, 20, 10),
				text_unfilled_fg = bifrost.rgb(240, 240, 240),
			})
		}
	})

	// Width 10, label " 50% " centered at start x = (10 - 5) / 2 = 2.
	// Columns 0..4 are filled.
	// Col 0: '█' (fill)
	// Col 1: '█' (fill)
	// Col 2: ' ' (in label, filled section: fg = text_filled_fg, bg = fill_color)
	// Col 3: '5' (in label, filled section: fg = text_filled_fg, bg = fill_color)
	// Col 4: '0' (in label, filled section: fg = text_filled_fg, bg = fill_color)
	// Col 5: '%' (in label, unfilled section: fg = text_unfilled_fg, bg = track_color)
	// Col 6: ' ' (in label, unfilled section: fg = text_unfilled_fg, bg = track_color)
	// Col 7: ' ' (unfilled background)
	then.cell_at_is(0, 0, '█', 1)
	then.cell_at_is(1, 0, '█', 1)
	then.cell_at_is(2, 0, ' ', 1)
	then.cell_at_is(3, 0, '5', 1)
	then.cell_at_is(4, 0, '0', 1)
	then.cell_at_is(5, 0, '%', 1)
	then.cell_at_is(6, 0, ' ', 1)
	then.cell_at_is(7, 0, ' ', 1)

	// Verify dual-tone contrast colors across the 50% boundary:
	// '5' and '0' have fill_color as background and text_fill_fg as foreground
	then.cell_colors_at_are(3, 0, text_fill_fg, fill_color)
	then.cell_colors_at_are(4, 0, text_fill_fg, fill_color)
	// '%' has track_color as background and text_unfill_fg as foreground
	then.cell_colors_at_are(5, 0, text_unfill_fg, track_color)
}

@(test)
@(scenario)
spec_gauge_threshold_color_rules :: proc(t: ^testing.T) {
	_ = scenario(t, w = 30, h = 5)

	green := bifrost.rgb(60, 220, 80)
	yellow := bifrost.rgb(255, 200, 40)
	red := bifrost.rgb(255, 60, 60)

	thresholds := s_test_thresholds[:]

	// 1. Check threshold evaluation
	then.gauge_threshold_color_is(0.20, thresholds, green)
	then.gauge_threshold_color_is(0.75, thresholds, yellow)
	then.gauge_threshold_color_is(0.95, thresholds, red)

	// 2. Render gauge with ratio 0.95 and verify cell foreground is red
	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.fixed(10), height = bifrost.fixed(1)}) {
			bifrost.ui_gauge(ctx, scr, "gauge_crit", bifrost.Gauge_Config{
				ratio      = 0.95,
				thresholds = s_test_thresholds[:],
			})
		}
	})

	then.cell_at_is(0, 0, '█', 1)
	then.cell_colors_at_are(0, 0, red, bifrost.Color{})
}

@(test)
@(scenario)
spec_spinner_animation_cycling_presets :: proc(t: ^testing.T) {
	_ = scenario(t, w = 40, h = 5)

	// 1. Verify Dots preset frames and wrapping
	then.spinner_frame_is(.Dots, 0, "⠋")
	then.spinner_frame_is(.Dots, 1, "⠙")
	then.spinner_frame_is(.Dots, 2, "⠹")
	then.spinner_frame_is(.Dots, 9, "⠏")
	then.spinner_frame_is(.Dots, 10, "⠋")

	// 2. Verify Line preset frames
	then.spinner_frame_is(.Line, 0, "-")
	then.spinner_frame_is(.Line, 1, "\\")
	then.spinner_frame_is(.Line, 2, "|")
	then.spinner_frame_is(.Line, 3, "/")
	then.spinner_frame_is(.Line, 4, "-")

	// 3. Render spinner with label and verify output
	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.fixed(1)}) {
			bifrost.ui_spinner(ctx, scr, "sp_active", bifrost.Spinner_Config{
				kind  = .Dots,
				tick  = 2,
				label = "Actor worker idle",
			})
		}
	})

	// tick 2 -> "⠹"
	then.cell_at_is(0, 0, '⠹', 1)
	then.vt_contains_text("⠹ Actor worker idle", true)

	// 4. Verify bordered spinner without explicit width includes border + padding in intrinsic size
	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_spinner(ctx, scr, "sp_bordered", bifrost.Spinner_Config{
				kind   = .Dots,
				tick   = 0,
				label  = "Sync",
				border = .Plain,
			})
		}
	})
	then.vt_contains_text("⠋ Sync", true)
}
