package bifrost_tests

import "core:strings"
import "core:testing"
import "../bifrost"

// =============================================================================
// Layer 2: Domain-Specific Language (Composable BDD Steps for Layout & Render)
// =============================================================================

given_terminal :: proc(s: ^Suite_Ctx, t: ^testing.T, w: i32 = 80, h: i32 = 24) {
	driver_init(s, t, w, h)
}

upon_rendering_frame :: proc(s: ^Suite_Ctx, build_ui: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen), default_bg: bifrost.Color = {}) {
	driver_begin_frame(s, default_bg)
	build_ui(&s.layout_ctx, &s.screen)
	driver_end_frame(s)
}

then_node_rect_is :: proc(s: ^Suite_Ctx, id: string, expected: bifrost.Rect, loc := #caller_location) {
	rect, ok := bifrost.get_rect(&s.layout_ctx, id)
	testing.expect(s.t, ok, "Expected layout node to exist", loc = loc)
	testing.expect_value(s.t, rect, expected, loc = loc)
}

then_node_inner_rect_is :: proc(s: ^Suite_Ctx, id: string, expected: bifrost.Rect, loc := #caller_location) {
	rect, ok := bifrost.get_inner_rect(&s.layout_ctx, id)
	testing.expect(s.t, ok, "Expected layout node to exist", loc = loc)
	testing.expect_value(s.t, rect, expected, loc = loc)
}

then_cell_at_is :: proc(
	s: ^Suite_Ctx,
	x, y: i32,
	expected_ch: rune,
	expected_width: u8 = 1,
	loc := #caller_location,
) {
	idx := int(y * s.screen.width + x)
	cell := s.screen.back[idx]
	testing.expect_value(s.t, cell.ch, expected_ch, loc = loc)
	testing.expect_value(s.t, cell.width, expected_width, loc = loc)
}

then_cell_colors_at_are :: proc(
	s: ^Suite_Ctx,
	x, y: i32,
	expected_fg: bifrost.Color,
	expected_bg: bifrost.Color,
	loc := #caller_location,
) {
	idx := int(y * s.screen.width + x)
	cell := s.screen.back[idx]
	testing.expect_value(s.t, cell.fg, expected_fg, loc = loc)
	testing.expect_value(s.t, cell.bg, expected_bg, loc = loc)
}

then_cell_style_at_has :: proc(
	s: ^Suite_Ctx,
	x, y: i32,
	flag: bifrost.Style_Flag,
	loc := #caller_location,
) {
	idx := int(y * s.screen.width + x)
	cell := s.screen.back[idx]
	testing.expect(s.t, flag in cell.style, "Expected style flag on cell", loc = loc)
}

then_diff_bytes_equal :: proc(s: ^Suite_Ctx, expected_bytes: int, loc := #caller_location) {
	testing.expect_value(s.t, s.last_diff_bytes, expected_bytes, loc = loc)
}

then_diff_ansi_equals :: proc(s: ^Suite_Ctx, expected_ansi: string, loc := #caller_location) {
	testing.expect_value(s.t, s.last_ansi_str, expected_ansi, loc = loc)
}

then_diff_ansi_contains :: proc(s: ^Suite_Ctx, substr: string, loc := #caller_location) {
	testing.expect(s.t, strings.contains(s.last_ansi_str, substr), "Expected ANSI diff to contain substring", loc = loc)
}
