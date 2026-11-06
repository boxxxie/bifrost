package bifrost_tests

import "core:testing"
import "../bifrost"

// =============================================================================
// Layer 1: Executable Specifications for Track 14
//          (Unicode Braille Sub-Cell Canvas `ui_canvas` & Sparkline `ui_sparkline`)
// =============================================================================

@(test)
@(scenario)
spec_braille_subcell_bitmask_encoding_and_per_cell_rgb :: proc(t: ^testing.T) {
	_ = scenario(t, w = 24, h = 6)

	// 1. Verify all 8 ISO/TR 11548-1 2x4 sub-cell dot positions:
	//    Left column  (sub_x = 0): rows 0..3 -> 0x01, 0x02, 0x04, 0x40
	//    Right column (sub_x = 1): rows 0..3 -> 0x08, 0x10, 0x20, 0x80
	then.braille_dot_bit_is(0, 0, 0x01)
	then.braille_dot_bit_is(0, 1, 0x02)
	then.braille_dot_bit_is(0, 2, 0x04)
	then.braille_dot_bit_is(0, 3, 0x40)
	then.braille_dot_bit_is(1, 0, 0x08)
	then.braille_dot_bit_is(1, 1, 0x10)
	then.braille_dot_bit_is(1, 2, 0x20)
	then.braille_dot_bit_is(1, 3, 0x80)

	// 2. Render an 8-cell wide x 1-cell high canvas where each cell has exactly one of the 8 dots set,
	//    plus a 9th cell combining all 8 dots (0xFF -> '⣿', U+28FF) and a 10th cell testing unset_point.
	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_canvas(ctx, scr, "braille_dots", bifrost.Canvas_Config{
				width  = bifrost.fixed(12),
				height = bifrost.fixed(1),
				fg     = bifrost.rgb(180, 200, 220),
				bg     = bifrost.rgb(20, 24, 32),
				draw_fn = proc(c: ^bifrost.Braille_Canvas, _: rawptr) {
					// Cell 0..3: left column dots (sub_x = 0, sub_y = 0..3)
					bifrost.canvas_set_point(c, 0, 0, bifrost.rgb(255, 80, 80))
					bifrost.canvas_set_point(c, 2, 1, bifrost.rgb(80, 255, 80))
					bifrost.canvas_set_point(c, 4, 2, bifrost.rgb(80, 80, 255))
					bifrost.canvas_set_point(c, 6, 3, bifrost.rgb(255, 220, 80))

					// Cell 4..7: right column dots (sub_x = 1, sub_y = 0..3)
					bifrost.canvas_set_point(c, 9,  0)
					bifrost.canvas_set_point(c, 11, 1)
					bifrost.canvas_set_point(c, 13, 2)
					bifrost.canvas_set_point(c, 15, 3)

					// Cell 8 (px = 16..17, py = 0..3): all 8 dots -> U+28FF ('⣿')
					for py: i32 = 0; py < 4; py += 1 {
						bifrost.canvas_set_point(c, 16, py, bifrost.rgb(120, 240, 255))
						bifrost.canvas_set_point(c, 17, py, bifrost.rgb(120, 240, 255))
					}

					// Cell 9 (px = 18..19): set top-left (0x01) + bottom-right (0x80), then unset top-left -> 0x80 ('⢀')
					bifrost.canvas_set_point(c, 18, 0)
					bifrost.canvas_set_point(c, 19, 3)
					bifrost.canvas_unset_point(c, 18, 0)
				},
			})
		}
	})

	then.cell_at_is(0, 0, rune(0x2801), 1)
	then.cell_at_is(1, 0, rune(0x2802), 1)
	then.cell_at_is(2, 0, rune(0x2804), 1)
	then.cell_at_is(3, 0, rune(0x2840), 1)
	then.cell_at_is(4, 0, rune(0x2808), 1)
	then.cell_at_is(5, 0, rune(0x2810), 1)
	then.cell_at_is(6, 0, rune(0x2820), 1)
	then.cell_at_is(7, 0, rune(0x2880), 1)
	then.cell_at_is(8, 0, rune(0x28FF), 1)
	then.cell_at_is(9, 0, rune(0x2880), 1)
	// Cell 10 has mask == 0 so it remains space ' ' with the canvas background
	then.cell_at_is(10, 0, ' ', 1)

	// Verify per-cell RGB foreground overrides and fallback to Canvas_Config.fg
	then.cell_colors_at_are(0, 0, bifrost.rgb(255, 80, 80),   bifrost.rgb(20, 24, 32))
	then.cell_colors_at_are(1, 0, bifrost.rgb(80, 255, 80),   bifrost.rgb(20, 24, 32))
	then.cell_colors_at_are(4, 0, bifrost.rgb(180, 200, 220), bifrost.rgb(20, 24, 32))
	then.cell_colors_at_are(8, 0, bifrost.rgb(120, 240, 255), bifrost.rgb(20, 24, 32))
}

@(test)
@(scenario)
spec_braille_bresenham_line_rect_and_series_polyline :: proc(t: ^testing.T) {
	_ = scenario(t, w = 30, h = 10)

	canvas: bifrost.Braille_Canvas
	_ = bifrost.canvas_init(&canvas, 6, 2)

	// 1. Draw a horizontal Bresenham line across top sub-row y=0 from x=0..3 (cells 0 and 1: top two dots 0x01 | 0x08 = 0x09 -> '⠉')
	bifrost.canvas_draw_line(&canvas, 0, 0, 3, 0, bifrost.rgb(100, 220, 255))
	then.canvas_cell_mask_is(&canvas, 0, 0, 0x09)
	then.canvas_cell_mask_is(&canvas, 1, 0, 0x09)

	// 2. Clear and draw a 4x4 sub-cell rectangle covering cell (0, 0) (px = 0..1, py = 0..3) and cell (1, 0) (px = 2..3, py = 0..3)
	//    In a 2x4 single-cell rectangle (x=0, y=0, w=2, h=4), all 8 border pixels of cell (0,0) are set -> 0xFF ('⣿')
	bifrost.canvas_clear(&canvas)
	bifrost.canvas_draw_rect(&canvas, 0, 0, 2, 4, bifrost.rgb(255, 180, 90))
	then.canvas_cell_mask_is(&canvas, 0, 0, 0xFF)
	then.canvas_point_is(&canvas, 0, 0, true)
	then.canvas_point_is(&canvas, 1, 3, true)
	then.canvas_point_is(&canvas, 2, 0, false)

	// 3. Clear and plot a 3-point time series [0.0, 50.0, 100.0] across a 6x2 cell canvas (12x8 virtual pixels):
	//    - sample[0] = 0.0   -> (px = 0,  py = 7) (bottom-left pixel: cell (0, 1), sub=(0, 3) -> bit 0x40)
	//    - sample[1] = 50.0  -> (px = 6,  py = 4) (midpoint pixel:    cell (3, 1), sub=(0, 0) -> bit 0x01)
	//    - sample[2] = 100.0 -> (px = 11, py = 0) (top-right pixel:   cell (5, 0), sub=(1, 0) -> bit 0x08)
	bifrost.canvas_clear(&canvas)
	series := [3]f32{0.0, 50.0, 100.0}
	bifrost.canvas_draw_series(&canvas, series[:], 0.0, 100.0, bifrost.rgb(130, 240, 170))

	then.canvas_point_is(&canvas, 0, 7, true)
	then.canvas_point_is(&canvas, 6, 4, true)
	then.canvas_point_is(&canvas, 11, 0, true)

	// 4. Mount the pre-populated canvas inside a bordered `ui_canvas` widget and verify screen cell output
	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_canvas(ctx, scr, "series_chart", bifrost.Canvas_Config{
				title       = "Series",
				width       = bifrost.fixed(8), // 6 inner cols + 2 border cols
				height      = bifrost.fixed(4), // 2 inner rows + 2 border rows
				border      = .Rounded,
				fg          = bifrost.rgb(130, 240, 170),
				border_fg   = bifrost.rgb(90, 120, 160),
				focus_flags = {.Focusable, .Default_Focus},
				draw_fn     = proc(c: ^bifrost.Braille_Canvas, _: rawptr) {
					pts := [3]f32{0.0, 50.0, 100.0}
					bifrost.canvas_draw_series(c, pts[:], 0.0, 100.0, bifrost.rgb(130, 240, 170))
				},
			})
		}
	})

	then.focused_widget_is("series_chart")
	then.node_inner_rect_is("series_chart", {x = 1, y = 1, w = 6, h = 2})
	// Bottom-left cell (cx=0, cy=1 -> screen x=1, y=2) and top-right cell (cx=5, cy=0 -> screen x=6, y=1) must contain non-space Braille glyphs
	then.cell_colors_at_are(1, 2, bifrost.rgb(130, 240, 170), {})
	then.cell_colors_at_are(6, 1, bifrost.rgb(130, 240, 170), {})
}

@(test)
@(scenario)
spec_sparkline_8_level_quantization_and_multirow_bars :: proc(t: ^testing.T) {
	_ = scenario(t, w = 24, h = 8)

	// 1. Single-row sparkline with 8 linearly spaced samples [0..7] must emit the exact 8 Unicode block glyphs `▁▂▃▄▅▆▇█`
	// 2. Explicit [min_val = 0, max_val = 100] sparkline with [0, 50, 100] emits `▁▅█`
	// 3. Multi-row (2-row high) sparkline with [0, 50, 100] fills bottom row with full block '█' for 100% and half block for 50%
	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			ramp := [8]f32{0, 1, 2, 3, 4, 5, 6, 7}
			bifrost.ui_sparkline(ctx, scr, "spark_ramp", ramp[:], bifrost.Sparkline_Config{
				width  = bifrost.fixed(8),
				height = bifrost.fixed(1),
				fg     = bifrost.rgb(120, 220, 255),
			})

			explicit_vals := [3]int{0, 50, 100}
			bifrost.ui_sparkline(ctx, scr, "spark_explicit", explicit_vals[:], bifrost.Sparkline_Config{
				width   = bifrost.fixed(3),
				height  = bifrost.fixed(1),
				min_val = 0,
				max_val = 100,
				fg      = bifrost.rgb(255, 200, 90),
			})

			tall_vals := [2]f32{0, 100}
			bifrost.ui_sparkline(ctx, scr, "spark_tall", tall_vals[:], bifrost.Sparkline_Config{
				width   = bifrost.fixed(2),
				height  = bifrost.fixed(2),
				min_val = 0,
				max_val = 100,
				fg      = bifrost.rgb(140, 240, 160),
			})
		}
	})

	then.row_runes_at_are(0, 0, "▁▂▃▄▅▆▇█")
	then.row_runes_at_are(0, 1, "▁▅█")

	// Multi-row sparkline at y = 2..3:
	// Col 0 (val=0):   top row (y=2) = ' ', bottom row (y=3) = '▁'
	// Col 1 (val=100): top row (y=2) = '█', bottom row (y=3) = '█'
	then.cell_at_is(0, 2, ' ', 1)
	then.cell_at_is(0, 3, '▁', 1)
	then.cell_at_is(1, 2, '█', 1)
	then.cell_at_is(1, 3, '█', 1)
}

@(test)
@(scenario)
spec_canvas_nan_inf_resilience_and_extreme_bresenham_coordinates :: proc(t: ^testing.T) {
	_ = scenario(t, w = 24, h = 6)

	// Guard against NaN / ±Inf samples in `canvas_draw_series`, `ui_sparkline`, and `min(i32)` in `canvas_draw_line`
	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_canvas(ctx, scr, "nan_canvas", bifrost.Canvas_Config{
				width  = bifrost.fixed(10),
				height = bifrost.fixed(2),
				draw_fn = proc(c: ^bifrost.Braille_Canvas, _: rawptr) {
					zero: f32 = 0.0
					nan32 := zero / zero
					inf32 := f32(1.0) / zero
					samples32 := [4]f32{0.0, nan32, inf32, 10.0}
					bifrost.canvas_draw_series(c, samples32[:])

					zero64: f64 = 0.0
					nan64 := zero64 / zero64
					samples64 := [3]f64{nan64, 5.0, -5.0}
					bifrost.canvas_draw_series(c, samples64[:])

					// Extreme coordinate stress test (`min(i32)` and `max(i32)`)
					bifrost.canvas_draw_line(c, min(i32), min(i32), max(i32), max(i32))
				},
			})

			zero: f32 = 0.0
			nan32 := zero / zero
			inf32 := f32(1.0) / zero
			spark_samples := [3]f32{0.0, nan32, inf32}
			bifrost.ui_sparkline(ctx, scr, "nan_spark", spark_samples[:], bifrost.Sparkline_Config{
				width  = bifrost.fixed(3),
				height = bifrost.fixed(1),
			})

			// Trailing window slicing: 6 samples in a 3-column sparkline must display the trailing 3 samples [10, 20, 30] -> `▁▅█`
			window_samples := [6]int{999, 888, 777, 10, 20, 30}
			bifrost.ui_sparkline(ctx, scr, "trailing_spark", window_samples[:], bifrost.Sparkline_Config{
				width  = bifrost.fixed(3),
				height = bifrost.fixed(1),
			})
		}
	})

	// Non-finite sparkline sample at col 1 defaults to mid-level `▅` (`norm = 0.5`) without hanging or crashing
	then.cell_at_is(1, 2, '▅', 1)
	// Trailing 3 samples [10, 20, 30] at y = 3 render `▁▅█`
	then.row_runes_at_are(0, 3, "▁▅█")
}
