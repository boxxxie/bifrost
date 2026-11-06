package bifrost_tests

import "core:testing"
import "../bifrost"

// =============================================================================
// Layer 1: Pure Executable Specifications (Track 11: Multi-Line Text Editor)
// =============================================================================

@(test)
@(scenario)
spec_text_area_2d_grapheme_navigation_and_sticky_preferred_column :: proc(t: ^testing.T) {
	_ = scenario(t, 48, 12)

	build_ui :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		in_ctx := current_scenario()
		if bifrost.container(ctx, "root", {width = bifrost.fixed(48), height = bifrost.fixed(12), dir = .Column}) {
			bifrost.ui_text_area(ctx, scr, &in_ctx.input, "editor", {
				title             = "Notes",
				width             = bifrost.fixed(40),
				height            = bifrost.fixed(8),
				border            = .Rounded,
				show_line_numbers = true,
			})
		}
	}

	// Line 0: "alpha_beta_123" (14 cols)
	// Line 1: ""               (0 cols, empty line)
	// Line 2: "0123456789ABCD" (14 cols)
	// Line 3: "A🚀B"           (4 cols: 'A' col 0, '🚀' cols 1..2, 'B' col 3)
	given.text_area_text("editor", "alpha_beta_123\n\n0123456789ABCD\nA🚀B")
	upon.rendering_frame(build_ui)

	then.focused_widget_is("editor")
	then.editing_widget_is("editor")
	then.text_area_line_count_is("editor", 4)
	// Cursor starts at end of buffer: row 3, col 4 ("A🚀B")
	then.text_area_cursor_is("editor", 3, 4)

	// Step Left across 'B' -> col 3, then Left across 2-column '🚀' -> col 1
	upon.pressing_key(.Left)
	upon.rendering_frame(build_ui)
	then.text_area_cursor_is("editor", 3, 3)

	upon.pressing_key(.Left)
	upon.rendering_frame(build_ui)
	then.text_area_cursor_is("editor", 3, 1)

	// Ctrl+Home jumps to (0, 0); Move to col 10 on row 0 ("alpha_beta")
	upon.pressing_key(.Home, {.Ctrl})
	upon.pressing_key(.End)
	upon.pressing_key(.Left)
	upon.pressing_key(.Left)
	upon.pressing_key(.Left)
	upon.pressing_key(.Left)
	upon.rendering_frame(build_ui)
	then.text_area_cursor_is("editor", 0, 10)
	then.text_area_preferred_col_is("editor", 10)

	// Press Down onto empty row 1: cursor clamps to (1, 0), but preferred_col remains 10!
	upon.pressing_key(.Down)
	upon.rendering_frame(build_ui)
	then.text_area_cursor_is("editor", 1, 0)
	then.text_area_preferred_col_is("editor", 10)

	// Press Down again onto row 2 ("0123456789ABCD"): cursor restores to (2, 10)!
	upon.pressing_key(.Down)
	upon.rendering_frame(build_ui)
	then.text_area_cursor_is("editor", 2, 10)
	then.text_area_preferred_col_is("editor", 10)

	// Ctrl+End jumps to document end (row 3, col 4)
	upon.pressing_key(.End, {.Ctrl})
	upon.rendering_frame(build_ui)
	then.text_area_cursor_is("editor", 3, 4)
}

@(test)
@(scenario)
spec_text_area_multiline_editing_selection_osc52_and_bracketed_paste :: proc(t: ^testing.T) {
	_ = scenario(t, 48, 12)

	build_ui :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		in_ctx := current_scenario()
		if bifrost.container(ctx, "root", {width = bifrost.fixed(48), height = bifrost.fixed(12), dir = .Column}) {
			bifrost.ui_text_area(ctx, scr, &in_ctx.input, "editor", {
				title  = "Editor",
				width  = bifrost.fixed(36),
				height = bifrost.fixed(6),
				border = .Rounded,
			})
		}
	}

	upon.rendering_frame(build_ui)
	then.editing_widget_is("editor")

	// Type "hello", press Enter to split line, type "world"
	upon.typing_text("hello")
	upon.pressing_key(.Enter)
	upon.typing_text("world")
	upon.rendering_frame(build_ui)
	then.text_area_value_is("editor", "hello\nworld")
	then.text_area_cursor_is("editor", 1, 5)
	then.text_area_line_count_is("editor", 2)

	// Move to start of line 1 and press Backspace to merge line 1 back into line 0
	upon.pressing_key(.Home)
	upon.rendering_frame(build_ui)
	then.text_area_cursor_is("editor", 1, 0)

	upon.pressing_key(.Backspace)
	upon.rendering_frame(build_ui)
	then.text_area_value_is("editor", "helloworld")
	then.text_area_cursor_is("editor", 0, 5)
	then.text_area_line_count_is("editor", 1)

	// Re-split with Enter, then select all (Ctrl+A) and copy (Ctrl+C) to OSC 52 clipboard
	upon.pressing_key(.Enter)
	upon.rendering_frame(build_ui)
	then.text_area_value_is("editor", "hello\nworld")

	upon.pressing_key_rune('a', {.Ctrl})
	upon.rendering_frame(build_ui)
	then.text_area_selection_is("editor", "hello\nworld")

	upon.pressing_key_rune('c', {.Ctrl})
	upon.rendering_frame(build_ui)
	then.clipboard_text_is("hello\nworld", true)
	// Verify `flush_osc52_clipboard` emits RFC 4648 base64 (`"hello\nworld"` -> `"aGVsbG8Kd29ybGQ="`) and clears `osc52_pending`
	then.osc52_flushed_is("\x1b]52;c;aGVsbG8Kd29ybGQ=\x07")

	// Replace active multi-line selection via bracketed Paste_Event containing newline, `\r\n`, and `\t` tab expansion
	upon.pasting_text("line_one\r\nline_two\n\tindented")
	upon.rendering_frame(build_ui)
	then.text_area_value_is("editor", "line_one\nline_two\n    indented")
	then.text_area_line_count_is("editor", 3)
	then.text_area_cursor_is("editor", 2, 12)

	// Verify word-wise jump (`Ctrl+Left`), kill-to-start (`Ctrl+U`), and kill-to-end (`Ctrl+K`)
	upon.pressing_key(.Left, {.Ctrl})
	then.text_area_cursor_is("editor", 2, 4)

	upon.pressing_key_rune('k', {.Ctrl})
	then.text_area_value_is("editor", "line_one\nline_two\n    ")
	then.clipboard_text_is("indented", true)

	upon.pressing_key_rune('u', {.Ctrl})
	then.text_area_value_is("editor", "line_one\nline_two\n")
	then.clipboard_text_is("    ", true)

	// Mouse click on row 0 (`y = 1` inside border), column 4 (`x = 5` inside border) places caret at (0, 4)
	upon.mouse_click(5, 1)
	then.text_area_cursor_is("editor", 0, 4)
}

@(test)
@(scenario)
spec_text_area_2d_viewport_scrolling_gutter_and_two_stage_edit_mode :: proc(t: ^testing.T) {
	_ = scenario(t, 50, 14)

	build_ui :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		in_ctx := current_scenario()
		if bifrost.container(ctx, "root", {width = bifrost.fixed(50), height = bifrost.fixed(14), dir = .Column, gap = 1}) {
			bifrost.ui_text_area(ctx, scr, &in_ctx.input, "editor", {
				title             = "Scratchpad",
				width             = bifrost.fixed(22), // inner_rect.w = 20, gutter_w = 4 (" 1 │"), text_w = 16
				height            = bifrost.fixed(5),  // inner_rect.h = 3 visible rows
				border            = .Rounded,
				show_line_numbers = true,
				two_stage         = true,
			})
			bifrost.ui_button(ctx, scr, "save_btn", {
				label  = "Save",
				width  = bifrost.fixed(12),
				height = bifrost.fixed(3),
				border = .Rounded,
			})
		}
	}

	given.text_area_text("editor", "r1_short\nr2_short\nr3_short\nr4_very_long_horizontal_line_end\nr5_bottom")
	upon.rendering_frame(build_ui)

	// Because two_stage = true, editor starts focused in .Navigation mode (editing_id == 0)
	then.focused_widget_is("editor")
	then.editing_widget_is("")

	// Press 'i' to enter .Editing mode
	upon.pressing_key_rune('i')
	upon.rendering_frame(build_ui)
	then.editing_widget_is("editor")

	// Jump to (0, 0) with Ctrl+Home; verify scroll is (0, 0) and gutter " 1 │" is rendered
	upon.pressing_key(.Home, {.Ctrl})
	upon.rendering_frame(build_ui)
	then.text_area_cursor_is("editor", 0, 0)
	then.text_area_scroll_is("editor", 0, 0)
	then.vt_contains_text(" 1 │r1_short", true)

	// Move Down 3 times to row 3 (4th line, index 3) and End of long line -> triggers both vertical & horizontal scroll!
	upon.pressing_key(.Down)
	upon.pressing_key(.Down)
	upon.pressing_key(.Down)
	upon.pressing_key(.End)
	upon.rendering_frame(build_ui)
	then.text_area_cursor_is("editor", 3, 32)
	// Viewport height is 3 rows -> row 3 scrolls scroll_row to 1 (visible rows 1..3, 1-based lines 2..4)
	// Text width is 16 cols (usable_cols = 15) -> col 32 scrolls scroll_col to 18
	then.text_area_scroll_is("editor", 1, 18)
	then.vt_contains_text(" 4 │", true)

	// Select characters with Shift+Left, then first Escape clears selection while staying in .Editing mode
	upon.pressing_key(.Left, {.Shift})
	upon.pressing_key(.Left, {.Shift})
	upon.pressing_key(.Left, {.Shift})
	upon.rendering_frame(build_ui)
	then.text_area_selection_is("editor", "end")

	upon.pressing_key(.Escape)
	upon.rendering_frame(build_ui)
	then.text_area_selection_is("editor", "")
	then.editing_widget_is("editor")

	// Second Escape exits .Editing mode back to .Navigation mode (editing_id == 0)
	upon.pressing_key(.Escape)
	upon.rendering_frame(build_ui)
	then.editing_widget_is("")
	then.focused_widget_is("editor")

	// In .Navigation mode, pressing 'j' navigates spatially down to "save_btn" instead of inserting 'j'!
	upon.pressing_key_rune('j')
	upon.rendering_frame(build_ui)
	then.focused_widget_is("save_btn")
}

@(test)
@(scenario)
spec_text_area_dynamic_buffer_state_ownership_and_max_lines_cap :: proc(t: ^testing.T) {
	_ = scenario(t, w = 48, h = 10)
	sc := current_scenario()

	dyn_state: bifrost.Text_Area_State
	_ = bifrost.text_area_init(&dyn_state, context.allocator, "line_a\nline_b")
	defer bifrost.text_area_destroy(&dyn_state)

	// Passing `state = &dyn_state` to `ui_text_area` must preserve `dyn_state.use_dyn` and `dyn_state.dyn_buf`
	// across layout construction, input editing, and paint sync without leaking or clobbering `dyn_buf`!
	sc.input.action_userdata = &dyn_state
	build_dyn_ui :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		s := current_scenario()
		st := (^bifrost.Text_Area_State)(s.input.action_userdata)
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_text_area(ctx, scr, &s.input, "dyn_editor", {
				width  = bifrost.fixed(10), // inner_rect.w = 8 cols
				height = bifrost.fixed(5),
				border = .Rounded,
				state  = st,
			})
		}
	}

	upon.rendering_frame(build_dyn_ui)
	upon.pressing_key_rune('!')
	upon.rendering_frame(build_dyn_ui)

	then.text_area_value_is("dyn_editor", "line_a\nline_b!")
	then.text_area_dynamic_state_is(&dyn_state, "line_a\nline_b!")

	// Verify that when a line is horizontally clipped and ends 1 column early because a 2-column emoji ('🚀')
	// doesn't fit in the 8th column ("0123456🚀" = 9 display cols -> visible slice is 7 cols "0123456"),
	// selecting all (`Ctrl+A`) does NOT draw a spurious reversed trailing-newline cell in the 8th column (`x = 8, y = 1`)!
	given.text_area_text("dyn_editor", "0123456🚀\nr2")
	upon.pressing_key(.Home, {.Ctrl})
	upon.pressing_key_rune('a', {.Ctrl})
	upon.rendering_frame(build_dyn_ui)
	then.cell_style_has(8, 1, .Reverse, false)

	// Setting a string with > MAX_TEXT_AREA_LINES (256) lines caps at 256 lines and never leaves raw '\n' in line 255
	b := make([dynamic]u8, 0, 1200, context.temp_allocator)
	for i := 0; i < 300; i += 1 {
		append(&b, 'x')
		append(&b, '\n')
	}
	given.text_area_text("dyn_editor", string(b[:]))
	then.text_area_line_count_is("dyn_editor", bifrost.MAX_TEXT_AREA_LINES)
	then.text_area_line_length_is("dyn_editor", bifrost.MAX_TEXT_AREA_LINES - 1, 1)

	// Pasting additional lines via `Paste_Event` when already at `MAX_TEXT_AREA_LINES` stops at the first newline
	// instead of silently dropping '\n' and concatenating onto line 255!
	upon.pasting_text("\nextra_tail_line")
	upon.rendering_frame(build_dyn_ui)
	then.text_area_line_length_is("dyn_editor", bifrost.MAX_TEXT_AREA_LINES - 1, 1)
}
