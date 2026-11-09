package bifrost_tests

import "core:testing"
import "../bifrost"

// =============================================================================
// Layer 1: Executable Specifications for Track 17
//          (Cartesian 2D Coordinate Charts & Categorical Bar Charts)
// =============================================================================

@(private="file")
s_test_points := [3][2]f64{
	{0.0, 0.0},
	{2.0, 5.0},
	{4.0, 10.0},
}

@(private="file")
s_vbar_items := [2]bifrost.Bar_Data{
	{label = "CPU", value = 50, color = bifrost.Color{kind = .RGB, r = 80, g = 180, b = 240}},
	{label = "MEM", value = 100, color = bifrost.Color{kind = .RGB, r = 240, g = 100, b = 120}},
}

@(private="file")
s_hbar_items := [2]bifrost.Bar_Data{
	{label = "Disk", value = 25, color = bifrost.Color{kind = .RGB, r = 100, g = 220, b = 140}},
	{label = "Net",  value = 100, color = bifrost.Color{kind = .RGB, r = 250, g = 180, b = 60}},
}

@(test)
@(scenario)
spec_chart_world_to_subcell_projection :: proc(t: ^testing.T) {
	_ = scenario(t, w = 30, h = 10)

	// Bounds X in [0..10], Y in [0..100], pixel dimensions 21x21 (subcells 0..20)
	x_bounds := [2]f64{0.0, 10.0}
	y_bounds := [2]f64{0.0, 100.0}

	// Bottom-left origin (0, 0) -> px = 0, py = 20
	then.projected_point_is({0.0, 0.0}, x_bounds, y_bounds, 21, 21, 0, 20, true)

	// Top-right (10, 100) -> px = 20, py = 0
	then.projected_point_is({10.0, 100.0}, x_bounds, y_bounds, 21, 21, 20, 0, true)

	// Center (5, 50) -> px = 10, py = 10
	then.projected_point_is({5.0, 50.0}, x_bounds, y_bounds, 21, 21, 10, 10, true)

	// Out-of-bounds point (15, 50) -> in_bounds = false, clamped px = 20, py = 10
	then.projected_point_is({15.0, 50.0}, x_bounds, y_bounds, 21, 21, 20, 10, false)
}

@(test)
@(scenario)
spec_chart_render_axes_ticks_and_data_series :: proc(t: ^testing.T) {
	_ = scenario(t, w = 30, h = 10)

	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.fixed(24), height = bifrost.fixed(8)}) {
			bifrost.ui_chart(ctx, scr, "test_chart", bifrost.Chart_Config{
				width  = bifrost.fixed(24),
				height = bifrost.fixed(8),
				x_axis = bifrost.Axis_Config{
					bounds = {0.0, 4.0},
					labels = {"0", "2", "4"},
				},
				y_axis = bifrost.Axis_Config{
					bounds = {0.0, 10.0},
					labels = {"0", "10"},
				},
				datasets = {
					{
						name   = "metrics",
						data   = s_test_points[:],
						marker = .Braille_Line,
						fg     = bifrost.rgb(100, 200, 255),
					},
				},
			})
		}
	})

	// Y-axis labels max width is 2 ("10"), so axis_col = 0 + 2 = 2 (col 2 is axis column)
	// Plot height: inner.h (8) - x_margin (2) = 6 rows (rows 0..5).
	// axis_row = 6 (row 6 is X-axis line, row 7 is X-axis labels).
	// At (2, 6) should be origin intersection '└'
	then.cell_at_is(2, 6, '└', 1)

	// At (2, 0) should be top Y tick '├'
	then.cell_at_is(2, 0, '├', 1)

	// At (2, 5) should be bottom Y tick '├'
	then.cell_at_is(2, 5, '├', 1)

	// Verify Y label "10" at top left
	then.cell_at_is(0, 0, '1', 1)
	then.cell_at_is(1, 0, '0', 1)

	// Verify X axis tick at origin
	then.cell_at_is(3, 6, '┬', 1)
}

@(test)
@(scenario)
spec_bar_chart_vertical_categorical_scaling :: proc(t: ^testing.T) {
	_ = scenario(t, w = 30, h = 10)

	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.fixed(20), height = bifrost.fixed(6)}) {
			bifrost.ui_bar_chart(ctx, scr, "v_bar", bifrost.Bar_Chart_Config{
				direction   = .Vertical,
				width       = bifrost.fixed(20),
				height      = bifrost.fixed(6),
				bar_width   = 3,
				gap         = 2,
				show_values = true,
				data        = s_vbar_items[:],
			})
		}
	})

	// Inner height = 6.
	// avail_h = 6 - 1 (labels) - 1 (values) = 4.
	// Base row for bars = inner.y + inner.h - 2 = 0 + 6 - 2 = 4.
	// CPU (value = 50 / 100 -> ratio 0.5 -> bar_h = 2):
	// start_x = 0, bar_w = 3. Drawn on rows 4 and 3. Row 2 is value "50".
	then.cell_at_is(0, 4, '█', 1)
	then.cell_at_is(1, 4, '█', 1)
	then.cell_at_is(2, 4, '█', 1)
	then.cell_at_is(0, 3, '█', 1)

	// Category label on row 5: "CPU"
	then.cell_at_is(0, 5, 'C', 1)
	then.cell_at_is(1, 5, 'P', 1)
	then.cell_at_is(2, 5, 'U', 1)

	// MEM (value = 100 / 100 -> ratio 1.0 -> bar_h = 4):
	// start_x = 0 + 1 * (3 + 2) = 5.
	// Drawn on rows 4, 3, 2, 1, with value indicator "100" at row 0.
	then.cell_at_is(5, 4, '█', 1)
	then.cell_at_is(5, 1, '█', 1)
	then.cell_at_is(5, 0, '1', 1)

	// Category label on row 5: "MEM"
	then.cell_at_is(5, 5, 'M', 1)
	then.cell_at_is(6, 5, 'E', 1)
	then.cell_at_is(7, 5, 'M', 1)
}

@(test)
@(scenario)
spec_bar_chart_horizontal_categorical_scaling :: proc(t: ^testing.T) {
	_ = scenario(t, w = 30, h = 10)

	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.fixed(25), height = bifrost.fixed(4)}) {
			bifrost.ui_bar_chart(ctx, scr, "h_bar", bifrost.Bar_Chart_Config{
				direction   = .Horizontal,
				width       = bifrost.fixed(25),
				height      = bifrost.fixed(4),
				gap         = 1,
				show_values = true,
				data        = s_hbar_items[:],
			})
		}
	})

	// Row 0 has label "Disk", Row 2 has label "Net"
	then.cell_at_is(0, 0, 'D', 1)
	then.cell_at_is(1, 0, 'i', 1)
	then.cell_at_is(2, 0, 's', 1)
	then.cell_at_is(3, 0, 'k', 1)

	then.cell_at_is(0, 2, 'N', 1)
	then.cell_at_is(1, 2, 'e', 1)
	then.cell_at_is(2, 2, 't', 1)

	// Both rows have '█' bar cells
	then.vt_contains_text("Disk", true)
	then.vt_contains_text("Net", true)

	// Verify Horizontal Bar Chart inside a right-hand column (`inner.x > 0`) scales proportionally
	// instead of collapsing to 1 cell wide
	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Row, width = bifrost.fixed(30), height = bifrost.fixed(4)}) {
			bifrost.leaf(ctx, "left_spacer", 12, 4, {width = bifrost.fixed(12), height = bifrost.fixed(4)})
			bifrost.ui_bar_chart(ctx, scr, "h_bar_right", bifrost.Bar_Chart_Config{
				direction   = .Horizontal,
				width       = bifrost.fixed(18),
				height      = bifrost.fixed(4),
				gap         = 1,
				show_values = false,
				data        = s_hbar_items[:],
			})
		}
	})
	// inner.x = 12, inner.w = 18, max_lbl_w = 4 ("Disk"), label_w = min(4, 18/4) = 4, bar_start_x = 12 + 4 + 1 = 17.
	// Net (100% of avail_bar_w = 18 - 5 = 13 cells) spans x = 17..29 on row 2
	then.cell_at_is(17, 2, '█', 1)
	then.cell_at_is(25, 2, '█', 1)

	// Verify Cartesian chart with show_grid = true and <= 2 Y-axis labels still renders interior grid dots
	// and reserves a header row above plot_y when y_axis.title or show_legend is present
	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.fixed(28), height = bifrost.fixed(8)}) {
			bifrost.ui_chart(ctx, scr, "grid_chart", bifrost.Chart_Config{
				width       = bifrost.fixed(28),
				height      = bifrost.fixed(8),
				show_grid   = true,
				show_legend = true,
				x_axis      = bifrost.Axis_Config{bounds = {0.0, 4.0}, labels = {"0", "4"}},
				y_axis      = bifrost.Axis_Config{bounds = {0.0, 10.0}, labels = {"0", "10"}, title = "ms"},
				datasets    = {
					{
						name   = "lat",
						data   = s_test_points[:],
						marker = .Braille_Line,
						fg     = bifrost.rgb(100, 200, 255),
					},
				},
			})
		}
	})
	// Row 0 has y_axis.title "ms" and legend "lat", while top Y tick '├' starts at plot_y = 1
	then.vt_row_contains_text(0, "ms", true)
	then.vt_row_contains_text(0, "lat", true)
	then.cell_at_is(2, 1, '├', 1)
}
