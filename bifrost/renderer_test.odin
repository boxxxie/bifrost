package bifrost

import "core:strings"
import "core:testing"

@(test)
test_render_layout_and_incremental_diff :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	scr: Screen
	err := screen_init(&scr, 30, 6)
	testing.expect_value(t, err, nil)
	defer screen_destroy(&scr)

	out := strings.builder_make(context.temp_allocator)

	// --- Frame 1: Initial Render ---
	ctx: Layout_Context
	begin_layout(&ctx, 30, 6)
	begin_frame(&scr)

	if container(&ctx, "panel", {
		dir    = .Column,
		width  = grow(1),
		height = grow(1),
		border = .Rounded,
	}) {
		set_paint(&scr, "panel", {
			title     = "xitdb",
			border_fg = rgb(100, 200, 255),
			style     = {.Bold},
		})
		ui_label(&ctx, &scr, "status", "Moment #41", rgb(0, 255, 128))
	}

	end_layout(&ctx)
	render_layout(&scr, &ctx)

	testing.expect_value(t, scr.back[0].ch, '╭')
	testing.expect_value(t, scr.back[2].ch, 'x')
	testing.expect_value(t, scr.back[6].ch, 'b')
	testing.expect_value(t, scr.back[1 * 30 + 1].ch, 'M')
	testing.expect_value(t, scr.back[1 * 30 + 10].ch, '1')

	bytes_frame1 := screen_diff_ansi(&scr, &out)
	testing.expect(t, bytes_frame1 > 0, "Frame 1 should emit full initial ANSI buffer")

	// --- Frame 2: Identical State -> 0 Bytes Emitted ---
	strings.builder_reset(&out)
	begin_layout(&ctx, 30, 6)
	begin_frame(&scr)

	if container(&ctx, "panel", {
		dir    = .Column,
		width  = grow(1),
		height = grow(1),
		border = .Rounded,
	}) {
		set_paint(&scr, "panel", {
			title     = "xitdb",
			border_fg = rgb(100, 200, 255),
			style     = {.Bold},
		})
		ui_label(&ctx, &scr, "status", "Moment #41", rgb(0, 255, 128))
	}

	end_layout(&ctx)
	render_layout(&scr, &ctx)

	bytes_frame2 := screen_diff_ansi(&scr, &out)
	testing.expect_value(t, bytes_frame2, 0)

	// --- Frame 3: Single Character Changed ('Moment #41' -> 'Moment #42') ---
	strings.builder_reset(&out)
	begin_layout(&ctx, 30, 6)
	begin_frame(&scr)

	if container(&ctx, "panel", {
		dir    = .Column,
		width  = grow(1),
		height = grow(1),
		border = .Rounded,
	}) {
		set_paint(&scr, "panel", {
			title     = "xitdb",
			border_fg = rgb(100, 200, 255),
			style     = {.Bold},
		})
		ui_label(&ctx, &scr, "status", "Moment #42", rgb(0, 255, 128))
	}

	end_layout(&ctx)
	render_layout(&scr, &ctx)

	bytes_frame3 := screen_diff_ansi(&scr, &out)
	diff_str := strings.to_string(out)

	expected_delta := "\x1b[?2026h\x1b[2;11H\x1b[0;38;2;0;255;128m2\x1b[0m\x1b[?2026l"
	testing.expect_value(t, bytes_frame3, len(expected_delta))
	testing.expect_value(t, diff_str, expected_delta)
}

@(test)
test_z_layer_sorting_and_backdrop_dimming :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	scr: Screen
	err := screen_init(&scr, 40, 10)
	testing.expect_value(t, err, nil)
	defer screen_destroy(&scr)

	ctx: Layout_Context
	begin_layout(&ctx, 40, 10)
	begin_frame(&scr, rgb(20, 30, 40))

	if container(&ctx, "root", {dir = .Row, width = grow(1), height = grow(1)}) {
		if container(&ctx, "sidebar", {dir = .Column, width = fixed(16), height = grow(1), border = .Plain}) {
			set_paint(&scr, "sidebar", {border_fg = rgb(100, 120, 140), bg = rgb(20, 30, 40)})
			ui_label(&ctx, &scr, "nav_item", "Logs", rgb(200, 100, 50))

			if ui_modal(&ctx, &scr, "confirm_modal", {
				title     = "Confirm",
				z_layer   = 20,
				width     = fixed(20),
				height    = fit(),
				border    = .Double,
				bg        = rgb(30, 30, 50),
				border_fg = rgb(255, 200, 0),
				backdrop  = .Dim_Screen,
			}) {
				ui_label(&ctx, &scr, "modal_msg", "Compact DB?", rgb(255, 255, 255))
			}
		}

		if container(&ctx, "right_pane", {dir = .Column, width = grow(1), height = grow(1), border = .Plain}) {
			set_paint(&scr, "right_pane", {border_fg = rgb(80, 160, 240), bg = rgb(40, 60, 80)})
			ui_label(&ctx, &scr, "right_text", "Active", rgb(120, 240, 160))
		}
	}

	end_layout(&ctx)
	render_layout(&scr, &ctx)

	sidebar_rect, _ := get_rect(&ctx, "sidebar")
	right_rect, _ := get_rect(&ctx, "right_pane")
	testing.expect_value(t, sidebar_rect, Rect{x = 0, y = 0, w = 16, h = 10})
	testing.expect_value(t, right_rect, Rect{x = 16, y = 0, w = 24, h = 10})

	modal_rect, _ := get_rect(&ctx, "confirm_modal")
	testing.expect_value(t, modal_rect, Rect{x = 10, y = 3, w = 20, h = 3})

	nav_cell := scr.back[1 * 40 + 1]
	testing.expect_value(t, nav_cell.ch, 'L')
	testing.expect_value(t, nav_cell.fg, rgb(100, 50, 25))
	testing.expect_value(t, nav_cell.bg, rgb(10, 15, 20))

	right_cell := scr.back[1 * 40 + 17]
	testing.expect_value(t, right_cell.ch, 'A')
	testing.expect_value(t, right_cell.fg, rgb(60, 120, 80))
	testing.expect_value(t, right_cell.bg, rgb(20, 30, 40))

	modal_corner := scr.back[3 * 40 + 10]
	testing.expect_value(t, modal_corner.ch, '╔')
	testing.expect_value(t, modal_corner.fg, rgb(255, 200, 0))
	testing.expect_value(t, modal_corner.bg, rgb(30, 30, 50))

	modal_text_cell := scr.back[4 * 40 + 11]
	testing.expect_value(t, modal_text_cell.ch, 'C')
	testing.expect_value(t, modal_text_cell.fg, rgb(255, 255, 255))
	testing.expect_value(t, modal_text_cell.bg, rgb(30, 30, 50))
}

@(test)
test_unicode_symbol_widths_and_wide_row_clear_diff :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Bare text-presentation symbols ('⌨' U+2328, '🗂' U+1F5C2) have East_Asian_Width = N (width 1),
	// whereas VS16 ("⌨️") and East_Asian_Width = W ('⚡' U+26A1, '📝' U+1F4DD) have width 2.
	testing.expect_value(t, rune_display_width('⌨'), u8(1))
	testing.expect_value(t, rune_display_width('🗂'), u8(1))
	testing.expect_value(t, rune_display_width('⚡'), u8(2))
	testing.expect_value(t, rune_display_width('📝'), u8(2))
	testing.expect_value(t, string_display_width("⌨️"), i32(2))

	scr: Screen
	_ = screen_init(&scr, 24, 2)
	defer screen_destroy(&scr)

	out := strings.builder_make(0, 256, context.temp_allocator)

	// Frame 1: Render a row containing a wide emoji + spaces + text ("📝 tabs.odin (T13)")
	begin_frame(&scr)
	clip := Rect{x = 0, y = 0, w = 24, h = 2}
	fill_rect(&scr, clip, clip, ' ', rgb(200, 200, 200), rgb(20, 20, 30), {})
	put_text_clipped(&scr, 1, 0, "📝 tabs.odin (T13)", rgb(200, 200, 200), rgb(20, 20, 30), {}, clip)
	_ = screen_diff_ansi(&scr, &out)
	frame1_ansi := strings.to_string(out)
	// Cursor is explicitly re-anchored at col 4 (`\x1b[1;4H`) right after the 2-column '📝' at cols 2..3
	testing.expect(t, strings.contains(frame1_ansi, "\x1b[1;4H"), "Expected explicit CUP re-anchor after 2-column glyph")

	// Frame 2: Clear row 0 back to blank spaces; `force_row_flush` ensures interior space cells
	// are also emitted so no shifted glyph can ever remain on screen.
	strings.builder_reset(&out)
	begin_frame(&scr)
	fill_rect(&scr, clip, clip, ' ', rgb(200, 200, 200), rgb(20, 20, 30), {})
	_ = screen_diff_ansi(&scr, &out)
	frame2_ansi := strings.to_string(out)
	testing.expect(t, strings.contains(frame2_ansi, "                  "), "Expected full contiguous space wipe across cleared wide row")
}
