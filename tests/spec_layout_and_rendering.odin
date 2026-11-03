package bifrost_tests

import "core:testing"
import "../bifrost"

// =============================================================================
// Layer 1: Executable Specifications for Track 1 (Layout & Renderer)
// =============================================================================

@(test)
spec_clay_water_filling_grow_and_percent_sizing :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, 100, 20)
	defer driver_destroy(&s)

	// Scenario 1: Water-filling Grow equalizes children with different intrinsic Fit bases (10 vs 30)
	// before expanding both equally to 50 + 50 = 100.
	// Also verifies Percent(0.25) contributes 0 to a Fit parent during Pass 1 but resolves to 25% of parent inner width in Pass 2.
	upon_rendering_frame(&s, proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			if bifrost.container(ctx, "water_row", {dir = .Row, width = bifrost.grow(1), height = bifrost.fixed(4)}) {
				bifrost.leaf(ctx, "narrow_base", 10, 1, {width = bifrost.grow(1), height = bifrost.grow(1)})
				bifrost.leaf(ctx, "wide_base", 30, 1, {width = bifrost.grow(1), height = bifrost.grow(1)})
			}
			if bifrost.container(ctx, "pct_fit_row", {dir = .Row, width = bifrost.fit(), height = bifrost.fixed(4)}) {
				bifrost.leaf(ctx, "fixed_40", 40, 1, {width = bifrost.fixed(40), height = bifrost.grow(1)})
				bifrost.leaf(ctx, "pct_50", 0, 1, {width = bifrost.percent(0.50), height = bifrost.grow(1)})
			}
		}
	})

	then_node_rect_is(&s, "narrow_base", {x = 0, y = 0, w = 50, h = 4})
	then_node_rect_is(&s, "wide_base", {x = 50, y = 0, w = 50, h = 4})

	// pct_50 contributed 0 to pct_fit_row in Pass 1 (so pct_fit_row fit to 40), then pct_50 took 50% of 40 = 20 in Pass 2
	then_node_rect_is(&s, "pct_fit_row", {x = 0, y = 4, w = 40, h = 4})
	then_node_rect_is(&s, "pct_50", {x = 40, y = 4, w = 20, h = 4})
}

@(test)
spec_water_draining_overflow_compression :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, 50, 10)
	defer driver_destroy(&s)

	// Two Fit children with intrinsic widths 50 (min=15) and 30 (min=15) inside a 50-wide row:
	// Total intrinsic = 80 (overflow = 30).
	// Water-draining compresses the 50-wide child down to 30 first (-20), then compresses both equally by 5 -> 25 and 25.
	upon_rendering_frame(&s, proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "row", {dir = .Row, width = bifrost.fixed(50), height = bifrost.fixed(10)}) {
			bifrost.leaf(ctx, "large_child", 50, 1, {width = bifrost.fit(min = 15), height = bifrost.grow(1)})
			bifrost.leaf(ctx, "small_child", 30, 1, {width = bifrost.fit(min = 15), height = bifrost.grow(1)})
		}
	})

	then_node_rect_is(&s, "large_child", {x = 0, y = 0, w = 25, h = 10})
	then_node_rect_is(&s, "small_child", {x = 25, y = 0, w = 25, h = 10})
}

@(test)
spec_text_wrapping_repropagates_fit_ancestor_height :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, 40, 15)
	defer driver_destroy(&s)

	// A 28-col string ("alpha beta gamma delta omega") inside a Grow column constrained to 12 outer cols
	// (10 inner cols with Plain border) wraps into 3 lines:
	// Line 1: "alpha beta" (10 cols)
	// Line 2: "gamma"      (5 cols)
	// Line 3: "delta"      (5 cols) -- wait: "delta omega" is 11 cols > 10, so 4 lines:
	// "alpha beta", "gamma", "delta", "omega" -> 4 inner rows + 2 border rows = 6 outer rows!
	// And its Fit parent card expands from 3 rows to 6 rows, pushing the lower sibling to y = 6.
	upon_rendering_frame(&s, proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "col", {dir = .Column, width = bifrost.fixed(12), height = bifrost.grow(1)}) {
			if bifrost.container(ctx, "fit_card", {dir = .Column, width = bifrost.grow(1), height = bifrost.fit(), border = .Plain}) {
				bifrost.ui_label(
					ctx,
					scr,
					"wrapped_lbl",
					"alpha beta gamma delta omega",
					bifrost.rgb(220, 220, 220),
					{},
					{width = bifrost.grow(1), height = bifrost.fit(), wrap_mode = .Words},
				)
			}
			bifrost.ui_label(ctx, scr, "below_card", "Footer", bifrost.rgb(180, 180, 180))
		}
	})

	then_node_rect_is(&s, "fit_card", {x = 0, y = 0, w = 12, h = 6})
	then_node_rect_is(&s, "wrapped_lbl", {x = 1, y = 1, w = 10, h = 4})
	then_node_rect_is(&s, "below_card", {x = 0, y = 6, w = 6, h = 1})
	then_cell_at_is(&s, 1, 1, 'a', 1)
	then_cell_at_is(&s, 1, 2, 'g', 1)
	then_cell_at_is(&s, 1, 3, 'd', 1)
	then_cell_at_is(&s, 1, 4, 'o', 1)
}

@(test)
spec_wide_cell_clip_degradation_and_overwrite_healing :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, 20, 6)
	defer driver_destroy(&s)

	upon_rendering_frame(&s, proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		clip := bifrost.Rect{x = 0, y = 0, w = 6, h = 4}

		// 1. Place wide CJK '界' (width=2) at x=5 (rightmost column of 6-col clip [0..5]):
		// Must degrade to 1-col space ' ' so it never spills into x=6.
		bifrost.put_cell_clipped(scr, 5, 0, bifrost.Cell{ch = '界', width = 2, fg = bifrost.rgb(255, 255, 255)}, clip)

		// 2. Place two adjacent wide CJK glyphs '你' at x=0..1 and '好' at x=2..3 on row 1,
		// then overwrite x=1 (spacer of '你') with narrow 'X':
		// Lead cell at x=0 must heal to ' ' (width=1).
		bifrost.put_cell_clipped(scr, 0, 1, bifrost.Cell{ch = '你', width = 2, fg = bifrost.rgb(200, 200, 200)}, clip)
		bifrost.put_cell_clipped(scr, 2, 1, bifrost.Cell{ch = '好', width = 2, fg = bifrost.rgb(200, 200, 200)}, clip)
		bifrost.put_cell_clipped(scr, 1, 1, bifrost.Cell{ch = 'X', width = 1, fg = bifrost.rgb(255, 0, 0)}, clip)

		// 3. Overwrite x=2 (lead of '好') with narrow 'Y':
		// Orphaned spacer at x=3 must heal to ' ' (width=1).
		bifrost.put_cell_clipped(scr, 2, 1, bifrost.Cell{ch = 'Y', width = 1, fg = bifrost.rgb(0, 255, 0)}, clip)

		// 4. On row 2, place '你' at x=0..1 and '好' at x=2..3, then write wide '界' at x=1..2:
		// Must heal x=0 (lost right half) AND x=3 (lost left half) to ' ' (width=1).
		bifrost.put_cell_clipped(scr, 0, 2, bifrost.Cell{ch = '你', width = 2, fg = bifrost.rgb(200, 200, 200)}, clip)
		bifrost.put_cell_clipped(scr, 2, 2, bifrost.Cell{ch = '好', width = 2, fg = bifrost.rgb(200, 200, 200)}, clip)
		bifrost.put_cell_clipped(scr, 1, 2, bifrost.Cell{ch = '界', width = 2, fg = bifrost.rgb(255, 255, 0)}, clip)
	})

	// Row 0: right-edge wide glyph degraded to space
	then_cell_at_is(&s, 5, 0, ' ', 1)
	then_cell_at_is(&s, 6, 0, ' ', 1)

	// Row 1: Case A & Case B healed
	then_cell_at_is(&s, 0, 1, ' ', 1)
	then_cell_at_is(&s, 1, 1, 'X', 1)
	then_cell_at_is(&s, 2, 1, 'Y', 1)
	then_cell_at_is(&s, 3, 1, ' ', 1)

	// Row 2: Case C healed on both ends
	then_cell_at_is(&s, 0, 2, ' ', 1)
	then_cell_at_is(&s, 1, 2, '界', 2)
	then_cell_at_is(&s, 2, 2, 0, 0)
	then_cell_at_is(&s, 3, 2, ' ', 1)
}

@(test)
spec_rgb_and_ansi256_backdrop_dimming_with_9point_anchors :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, 40, 10)
	defer driver_destroy(&s)

	upon_rendering_frame(&s, proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root", {dir = .Row, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			if bifrost.container(ctx, "panel", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
				// Cell with neutral cube gray 59 (95,95,95) fg and dark chromatic cube 52 (95,0,0) bg
				bifrost.put_cell_clipped(
					scr,
					2,
					2,
					bifrost.Cell{ch = 'G', width = 1, fg = bifrost.ansi256(59), bg = bifrost.ansi256(52), style = {.Bold}},
					{0, 0, 40, 10},
				)
				// Wide CJK cell straddling x=9..10 where a Dim_Rect overlay starts at x=10
				bifrost.put_cell_clipped(
					scr,
					9,
					3,
					bifrost.Cell{ch = '漢', width = 2, fg = bifrost.rgb(200, 100, 50), bg = bifrost.rgb(40, 60, 80)},
					{0, 0, 40, 10},
				)

				// Floating HUD with 9-point Center attachment and Dim_Rect backdrop over x=10..30, y=2..6
				if bifrost.container(ctx, "hud", {
					dir            = .Column,
					width          = bifrost.fixed(20),
					height         = bifrost.fixed(4),
					z_layer        = 10,
					floating       = true,
					anchor         = .Screen,
					parent_anchor  = .Center,
					element_anchor = .Center,
				}) {
					bifrost.set_paint(scr, "hud", {
						backdrop = .Dim_Rect,
					})
				}
			}
		}
	})

	// HUD anchored at screen center: (40/2 - 20/2 = 10, 10/2 - 4/2 = 3)
	then_node_rect_is(&s, "hud", {x = 10, y = 3, w = 20, h = 4})

	// The wide cell '漢' at x=9..10 y=3 was bisected by hud's Dim_Rect left boundary (x=10):
	// Both halves (x=9 and x=10) must heal to 1-col spaces, with x=10 dimmed 50% and x=9 undimmed!
	then_cell_at_is(&s, 9, 3, ' ', 1)
	then_cell_at_is(&s, 10, 3, ' ', 1)
	then_cell_colors_at_are(&s, 9, 3, bifrost.rgb(200, 100, 50), bifrost.rgb(40, 60, 80))
	then_cell_colors_at_are(&s, 10, 3, bifrost.rgb(100, 50, 25), bifrost.rgb(20, 30, 40))

	// Now test full-screen dimming on neutral cube gray 59 -> grayscale 236 (48,48,48) and dark chromatic 52 -> 234
	bifrost.dim_rect_backdrop(&s.screen, {0, 0, 40, 10})
	then_cell_colors_at_are(&s, 2, 2, bifrost.ansi256(236), bifrost.ansi256(234))
	then_cell_style_at_has(&s, 2, 2, .Dim)
}

@(test)
spec_incremental_ansi_diff_and_sync_output :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_terminal(&s, t, 30, 6)
	defer driver_destroy(&s)

	// Frame 1: Initial render
	upon_rendering_frame(&s, proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "panel", {
			dir    = .Column,
			width  = bifrost.grow(1),
			height = bifrost.grow(1),
			border = .Rounded,
		}) {
			bifrost.set_paint(scr, "panel", {
				title     = "xitdb",
				border_fg = bifrost.rgb(100, 200, 255),
				style     = {.Bold},
			})
			bifrost.ui_label(ctx, scr, "status", "Moment #41", bifrost.rgb(0, 255, 128))
		}
	})

	then_cell_at_is(&s, 0, 0, '╭', 1)
	then_cell_at_is(&s, 2, 0, 'x', 1)
	then_cell_at_is(&s, 6, 0, 'b', 1)
	then_cell_at_is(&s, 1, 1, 'M', 1)
	then_cell_at_is(&s, 10, 1, '1', 1)

	// Frame 2: Identical state -> 0 bytes emitted
	upon_rendering_frame(&s, proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "panel", {
			dir    = .Column,
			width  = bifrost.grow(1),
			height = bifrost.grow(1),
			border = .Rounded,
		}) {
			bifrost.set_paint(scr, "panel", {
				title     = "xitdb",
				border_fg = bifrost.rgb(100, 200, 255),
				style     = {.Bold},
			})
			bifrost.ui_label(ctx, scr, "status", "Moment #41", bifrost.rgb(0, 255, 128))
		}
	})
	then_diff_bytes_equal(&s, 0)

	// Frame 3: Single character changed ('Moment #41' -> 'Moment #42')
	upon_rendering_frame(&s, proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "panel", {
			dir    = .Column,
			width  = bifrost.grow(1),
			height = bifrost.grow(1),
			border = .Rounded,
		}) {
			bifrost.set_paint(scr, "panel", {
				title     = "xitdb",
				border_fg = bifrost.rgb(100, 200, 255),
				style     = {.Bold},
			})
			bifrost.ui_label(ctx, scr, "status", "Moment #42", bifrost.rgb(0, 255, 128))
		}
	})

	expected_delta := "\x1b[?2026h\x1b[2;11H\x1b[0;38;2;0;255;128m2\x1b[0m\x1b[?2026l"
	then_diff_bytes_equal(&s, len(expected_delta))
	then_diff_ansi_equals(&s, expected_delta)
}
