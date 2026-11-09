package bifrost

import "core:mem"
import "core:strings"
import "../deps/heimdall/heimdall"

// =============================================================================
// Color, Style & Cell Primitives
// =============================================================================

Style_Flag :: enum u8 {
	Bold,
	Dim,
	Italic,
	Underline,
	Blink,
	Reverse,
	Strikethrough,
}

Style_Flags :: bit_set[Style_Flag; u8]

Color_Kind :: enum u8 {
	Default = 0,
	ANSI_16,
	ANSI_256,
	RGB,
}

// Compact 4-byte color descriptor. For ANSI_16 and ANSI_256, `r` stores the palette index.
Color :: struct {
	kind: Color_Kind,
	r:    u8,
	g:    u8,
	b:    u8,
}

// width == 1: standard 1-column narrow glyph
// width == 2: lead (left) cell of a 2-column wide glyph
// width == 0: trailing (right) spacer cell of a 2-column wide glyph (ch == 0)
Cell :: struct {
	ch:    rune,
	fg:    Color,
	bg:    Color,
	style: Style_Flags,
	width: u8,
}

EMPTY_CELL :: Cell{
	ch    = ' ',
	width = 1,
}

DEFAULT_CELL :: EMPTY_CELL

Backdrop_Mode :: enum u8 {
	None,       // Standard drawing without modifying underlying cells
	Dim_Screen, // Dims colors by 50% across the entire screen before drawing this node
	Dim_Rect,   // Dims colors by 50% only inside this node's clipped outer Rect
}

Styled_Span :: struct {
	text:  string,
	fg:    Color,
	bg:    Color,
	style: Style_Flags,
}

Paint_Spec :: struct {
	title:       string,
	text:        string,
	spans:       []Styled_Span,
	fg:          Color,
	bg:          Color,
	border_fg:   Color,
	title_fg:    Color,
	style:       Style_Flags,
	title_style: Style_Flags,
	fill_bg:     bool,
	fill_char:   rune,
	backdrop:    Backdrop_Mode,
	has_cursor:  bool,
	cursor_col:  i32,
}

Modal_Spec :: struct {
	title:       string,
	z_layer:     u8,
	width:       Axis_Size,
	height:      Axis_Size,
	padding:     Padding,
	gap:         i32,
	border:      Border_Kind,
	fg:          Color,
	bg:          Color,
	border_fg:   Color,
	title_fg:    Color,
	backdrop:    Backdrop_Mode,
	focus_flags: Focus_Flags,
}

Border_Glyphs :: struct {
	tl, tr, bl, br: rune,
	horiz, vert:    rune,
}

@(rodata)
BORDER_GLYPHS := [Border_Kind]Border_Glyphs{
	.None    = {},
	.Plain   = {tl = '┌', tr = '┐', bl = '└', br = '┘', horiz = '─', vert = '│'},
	.Rounded = {tl = '╭', tr = '╮', bl = '╰', br = '╯', horiz = '─', vert = '│'},
	.Double  = {tl = '╔', tr = '╗', bl = '╚', br = '╝', horiz = '═', vert = '║'},
}

@(rodata)
CUBE_LEVELS := [6]u8{0, 95, 135, 175, 215, 255}

@(rodata)
ANSI_16_DARK_TO_256 := [8]u8{
	0 = 0,   // Black -> Black
	1 = 52,  // Red (128,0,0) -> Cube(1,0,0) (95,0,0)
	2 = 22,  // Green (0,128,0) -> Cube(0,1,0) (0,95,0)
	3 = 58,  // Yellow (128,128,0) -> Cube(1,1,0) (95,95,0)
	4 = 18,  // Blue (0,0,128) -> Cube(0,0,1) (0,0,95)
	5 = 53,  // Magenta (128,0,128) -> Cube(1,0,1) (95,0,95)
	6 = 23,  // Cyan (0,128,128) -> Cube(0,1,1) (0,95,95)
	7 = 246, // Silver (192,192,192) -> Gray(98,98,98)
}

Screen :: struct {
	width:           i32,
	height:          i32,
	front:           []Cell,
	back:            []Cell,
	paints:          map[u64]Paint_Spec,
	text_areas:      map[u64]^Text_Area_State,
	dynamic_bars:    [dynamic]Dynamic_Bar_Entry,
	canvas_entries:  map[u64]Canvas_Render_Entry,
	table_entries:   map[u64]Table_Render_Entry,
	active_table_id: u64,
	first_frame:     bool,
	allocator:       mem.Allocator,
	recorder:        ^heimdall.Recorder,
}

// =============================================================================
// Color Constructors & Comparison Helpers
// =============================================================================

rgb :: #force_inline proc "contextless" (r, g, b: u8) -> Color {
	return Color{kind = .RGB, r = r, g = g, b = b}
}

ansi256 :: #force_inline proc "contextless" (idx: u8) -> Color {
	return Color{kind = .ANSI_256, r = idx}
}

ansi16 :: #force_inline proc "contextless" (idx: u8) -> Color {
	return Color{kind = .ANSI_16, r = idx}
}

colors_equal :: #force_inline proc "contextless" (a, b: Color) -> bool {
	return a == b
}

cells_equal :: #force_inline proc "contextless" (a, b: Cell) -> bool {
	return a == b
}

// =============================================================================
// Unicode Display Width Measurement
// =============================================================================

// Computes terminal display column width (0, 1, or 2) for a rune.
rune_display_width :: proc "contextless" (r: rune) -> u8 {
	if r == 0 || r < 32 || (r >= 0x7f && r < 0xa0) {
		return 0
	}
	// Zero-width joiners, non-joiners, soft hyphen, BOM, combining marks, variation selectors
	if r == 0x00ad || (r >= 0x0300 && r <= 0x036f) || r == 0x034f ||
	   (r >= 0x180b && r <= 0x180d) || (r >= 0x200b && r <= 0x200f) ||
	   (r >= 0x202a && r <= 0x202e) || (r >= 0x2060 && r <= 0x2064) ||
	   r == 0xfeff || (r >= 0xfe00 && r <= 0xfe0f) || (r >= 0xe0100 && r <= 0xe01ef) {
		return 0
	}
	// Wide / Fullwidth East Asian, CJK, and Emoji blocks (Unicode East_Asian_Width = W / F)
	if (r >= 0x1100 && r <= 0x115f) ||
	   r == 0x231a || r == 0x231b ||
	   r == 0x2329 || r == 0x232a ||
	   (r >= 0x23e9 && r <= 0x23ec) || r == 0x23f0 || r == 0x23f3 ||
	   r == 0x25fd || r == 0x25fe ||
	   r == 0x2614 || r == 0x2615 ||
	   (r >= 0x2648 && r <= 0x2653) || r == 0x267f || r == 0x2693 || r == 0x26a1 ||
	   r == 0x26aa || r == 0x26ab || r == 0x26bd || r == 0x26be ||
	   r == 0x26c4 || r == 0x26c5 || r == 0x26ce || r == 0x26d4 || r == 0x26ea ||
	   r == 0x26f2 || r == 0x26f3 || r == 0x26f5 || r == 0x26fa || r == 0x26fd ||
	   r == 0x2705 || r == 0x270a || r == 0x270b || r == 0x2728 || r == 0x274c ||
	   r == 0x274e || (r >= 0x2753 && r <= 0x2755) || r == 0x2757 ||
	   (r >= 0x2795 && r <= 0x2797) || r == 0x27b0 || r == 0x27bf ||
	   r == 0x2b1b || r == 0x2b1c || r == 0x2b50 || r == 0x2b55 ||
	   (r >= 0x2e80 && r <= 0x303e) ||
	   (r >= 0x3040 && r <= 0xa4cf && r != 0x303f) ||
	   (r >= 0xac00 && r <= 0xd7a3) ||
	   (r >= 0xf900 && r <= 0xfaff) ||
	   (r >= 0xfe10 && r <= 0xfe19) ||
	   (r >= 0xfe30 && r <= 0xfe6f) ||
	   (r >= 0xff00 && r <= 0xff60) ||
	   (r >= 0xffe0 && r <= 0xffe6) ||
	   (r >= 0x1f1e6 && r <= 0x1f6ff && !(r >= 0x1f568 && r <= 0x1f5fa && r != 0x1f57a && r != 0x1f595 && r != 0x1f596 && r != 0x1f5a4)) ||
	   (r >= 0x1f900 && r <= 0x1faff) ||
	   (r >= 0x20000 && r <= 0x3fffd) {
		return 2
	}
	return 1
}

string_display_width :: proc "contextless" (str: string) -> i32 {
	total: i32 = 0
	idx := 0
	for idx < len(str) {
		next_idx, w, _ := next_grapheme_cluster(str, idx)
		total += w
		idx = next_idx
	}
	return total
}

// =============================================================================
// Screen Double-Buffer Lifecycle & Widget Paint Helpers
// =============================================================================

screen_init :: proc(
	s: ^Screen,
	w, h: i32,
	allocator := context.allocator,
) -> mem.Allocator_Error {
	total := int(max(0, w * h))
	s.front = make([]Cell, total, allocator) or_return
	s.back  = make([]Cell, total, allocator) or_return
	s.width       = max(0, w)
	s.height      = max(0, h)
	s.first_frame = true
	s.allocator   = allocator
	for i in 0 ..< total {
		s.front[i] = EMPTY_CELL
		s.back[i]  = EMPTY_CELL
	}
	return nil
}

screen_destroy :: proc(s: ^Screen) {
	delete(s.front, s.allocator)
	delete(s.back, s.allocator)
	s^ = {}
}

screen_resize :: proc(s: ^Screen, new_w, new_h: i32) -> mem.Allocator_Error {
	if s.width == new_w && s.height == new_h {
		return nil
	}
	alloc := s.allocator
	delete(s.front, alloc)
	delete(s.back, alloc)
	return screen_init(s, new_w, new_h, alloc)
}

begin_frame :: proc(s: ^Screen, default_bg: Color = {}, temp_alloc := context.temp_allocator) {
	clear_cell := EMPTY_CELL
	clear_cell.bg = default_bg
	for i in 0 ..< len(s.back) {
		s.back[i] = clear_cell
	}
	s.paints          = make(map[u64]Paint_Spec, 128, temp_alloc)
	s.text_areas      = make(map[u64]^Text_Area_State, 8, temp_alloc)
	s.dynamic_bars    = make([dynamic]Dynamic_Bar_Entry, 0, 8, temp_alloc)
	s.canvas_entries  = make(map[u64]Canvas_Render_Entry, 16, temp_alloc)
	s.table_entries   = make(map[u64]Table_Render_Entry, 8, temp_alloc)
	s.active_table_id = 0
}

set_paint :: proc(s: ^Screen, id: string, spec: Paint_Spec) {
	s.paints[hash_id(id)] = spec
}

ui_label :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	id: string,
	text: string,
	fg: Color = {},
	style: Style_Flags = {},
	cfg: Box_Config = {},
) -> i32 {
	disp_w := string_display_width(text)
	s.paints[hash_id(id)] = Paint_Spec{
		text  = text,
		fg    = fg,
		style = style,
	}
	label_cfg := cfg
	label_cfg.text = text
	return leaf(ctx, id, disp_w, 1, label_cfg)
}

@(deferred_in = defer_end_modal)
ui_modal :: proc(ctx: ^Layout_Context, s: ^Screen, id: string, spec: Modal_Spec) -> bool {
	z := spec.z_layer if spec.z_layer > 0 else 20
	border := spec.border if spec.border != .None else .Double
	w := spec.width if spec.width != nil else fit(min = 30)
	h := spec.height if spec.height != nil else fit()

	s.paints[hash_id(id)] = Paint_Spec{
		title       = spec.title,
		fg          = spec.fg,
		bg          = spec.bg,
		border_fg   = spec.border_fg,
		title_fg    = spec.title_fg,
		title_style = {.Bold},
		fill_bg     = true,
		backdrop    = spec.backdrop if spec.backdrop != .None else .Dim_Screen,
	}
	idx := push_node(ctx, id, Box_Config{
		dir           = .Column,
		width         = w,
		height        = h,
		padding       = spec.padding,
		gap           = spec.gap,
		border        = border,
		z_layer       = z,
		floating      = true,
		anchor        = .Screen,
		self_align    = {.Center, .Center},
		focus_flags   = spec.focus_flags + {.Focus_Scope, .Trap_Focus},
		focus_scope   = true,
		capture_input = true,
	}, {0, 0})
	enter_container_node(ctx, idx)
	return true
}

defer_end_modal :: proc(ctx: ^Layout_Context, s: ^Screen, id: string, spec: Modal_Spec) {
	exit_container_node(ctx)
}

// =============================================================================
// Wide-Cell Overwrite Healing & Clipped Cell Primitives
// =============================================================================

@(private)
heal_overwrite_at :: proc(s: ^Screen, x, y: i32) {
	idx := int(y * s.width + x)
	existing := s.back[idx]

	if existing.width == 0 && x > 0 {
		// Case A: Overwriting the right half (spacer) of a wide cell: degrade lead cell at x - 1 to 1-col space
		lead_idx := idx - 1
		lead := s.back[lead_idx]
		if lead.width == 2 {
			lead.ch    = ' '
			lead.width = 1
			s.back[lead_idx] = lead
		}
	} else if existing.width == 2 && x + 1 < s.width {
		// Case B: Overwriting the left half (lead) of a wide cell: heal orphaned spacer at x + 1 to 1-col space
		spacer_idx := idx + 1
		spacer := s.back[spacer_idx]
		if spacer.width == 0 {
			spacer.ch    = ' '
			spacer.width = 1
			s.back[spacer_idx] = spacer
		}
	}
}

// Safely writes a 1-column or 2-column cell within clip, healing any split wide neighbors.
put_cell_clipped :: proc(s: ^Screen, x, y: i32, cell: Cell, clip: Rect) {
	if cell.width == 0 {
		return
	}
	screen_bounds := Rect{x = 0, y = 0, w = s.width, h = s.height}
	eff_clip := rect_intersect(clip, screen_bounds)
	if x < eff_clip.x || x >= eff_clip.x + eff_clip.w || y < eff_clip.y || y >= eff_clip.y + eff_clip.h {
		return
	}

	c := cell
	if c.ch < 32 || (c.ch >= 0x7f && c.ch < 0xa0) {
		c.ch    = ' '
		c.width = 1
	}
	if c.width > 2 {
		c.width = 2
	}

	// Right-boundary clip degradation: a 2-column glyph at the last column of eff_clip degrades to ' '
	if c.width == 2 && x + 1 >= eff_clip.x + eff_clip.w {
		c.ch    = ' '
		c.width = 1
	}

	// Heal any wide glyph split at (x, y)
	heal_overwrite_at(s, x, y)

	idx := int(y * s.width + x)
	if c.width == 2 {
		// Case C: Also heal any wide glyph whose lead cell sits at (x + 1, y)
		heal_overwrite_at(s, x + 1, y)
		s.back[idx] = c
		s.back[idx + 1] = Cell{
			ch    = 0,
			fg    = c.fg,
			bg    = c.bg,
			style = c.style,
			width = 0,
		}
	} else {
		s.back[idx] = c
	}
}

set_cell_clipped :: #force_inline proc(s: ^Screen, x, y: i32, clip: Rect, cell: Cell) {
	put_cell_clipped(s, x, y, cell, clip)
}

put_text_clipped :: proc(
	s: ^Screen,
	x, y: i32,
	text: string,
	fg, bg: Color,
	style: Style_Flags,
	clip: Rect,
) -> i32 {
	cur_x := x
	idx := 0
	for idx < len(text) {
		next_idx, cluster_w, lead_r := next_grapheme_cluster(text, idx)
		idx = next_idx
		if cluster_w <= 0 {
			continue
		}
		w := u8(clamp(cluster_w, 1, 2))
		eff_bg := bg
		if eff_bg.kind == .Default && cur_x >= 0 && cur_x < s.width && y >= 0 && y < s.height {
			eff_bg = s.back[int(y * s.width + cur_x)].bg
		}
		put_cell_clipped(s, cur_x, y, Cell{
			ch    = lead_r,
			fg    = fg,
			bg    = eff_bg,
			style = style,
			width = w,
		}, clip)
		cur_x += i32(w)
	}
	return cur_x - x
}

draw_string_clipped :: proc(
	s: ^Screen,
	x, y: i32,
	clip: Rect,
	text: string,
	fg, bg: Color,
	style: Style_Flags,
) {
	put_text_clipped(s, x, y, text, fg, bg, style, clip)
}

fill_rect :: proc(s: ^Screen, r: Rect, clip: Rect, ch: rune, fg, bg: Color, style: Style_Flags) {
	bounds := rect_intersect(r, clip)
	bounds = rect_intersect(bounds, Rect{x = 0, y = 0, w = s.width, h = s.height})
	if bounds.w <= 0 || bounds.h <= 0 {
		return
	}
	fill_ch := ch if ch >= 32 else ' '
	w := rune_display_width(fill_ch)
	if w != 1 {
		fill_ch = ' '
	}
	cell := Cell{
		ch    = fill_ch,
		fg    = fg,
		bg    = bg,
		style = style,
		width = 1,
	}
	for y := bounds.y; y < bounds.y + bounds.h; y += 1 {
		for x := bounds.x; x < bounds.x + bounds.w; x += 1 {
			put_cell_clipped(s, x, y, cell, bounds)
		}
	}
}

draw_border :: proc(
	s: ^Screen,
	r: Rect,
	clip: Rect,
	kind: Border_Kind,
	fg, bg: Color,
	style: Style_Flags,
) {
	if r.w < 2 || r.h < 2 || kind == .None {
		return
	}
	glyphs := BORDER_GLYPHS[kind]
	x0 := r.x
	y0 := r.y
	x1 := r.x + r.w - 1
	y1 := r.y + r.h - 1

	draw_border_cell(s, x0, y0, clip, glyphs.tl, fg, bg, style)
	draw_border_cell(s, x1, y0, clip, glyphs.tr, fg, bg, style)
	draw_border_cell(s, x0, y1, clip, glyphs.bl, fg, bg, style)
	draw_border_cell(s, x1, y1, clip, glyphs.br, fg, bg, style)

	for x := x0 + 1; x < x1; x += 1 {
		draw_border_cell(s, x, y0, clip, glyphs.horiz, fg, bg, style)
		draw_border_cell(s, x, y1, clip, glyphs.horiz, fg, bg, style)
	}
	for y := y0 + 1; y < y1; y += 1 {
		draw_border_cell(s, x0, y, clip, glyphs.vert, fg, bg, style)
		draw_border_cell(s, x1, y, clip, glyphs.vert, fg, bg, style)
	}
}

@(private)
draw_border_cell :: #force_inline proc(
	s: ^Screen,
	x, y: i32,
	clip: Rect,
	ch: rune,
	fg, bg: Color,
	style: Style_Flags,
) {
	eff_bg := bg
	if eff_bg.kind == .Default && x >= 0 && x < s.width && y >= 0 && y < s.height {
		eff_bg = s.back[int(y * s.width + x)].bg
	}
	put_cell_clipped(s, x, y, Cell{ch = ch, fg = fg, bg = eff_bg, style = style, width = 1}, clip)
}

draw_border_title :: proc(
	s: ^Screen,
	r: Rect,
	clip: Rect,
	title: string,
	fg, bg: Color,
	style: Style_Flags,
) {
	max_title_w := r.w - 4
	if max_title_w <= 0 {
		return
	}
	title_clip := rect_intersect(clip, Rect{x = r.x + 1, y = r.y, w = r.w - 2, h = 1})
	draw_border_cell(s, r.x + 1, r.y, title_clip, ' ', fg, bg, style)

	cx := r.x + 2
	used_w: i32 = 0
	for ch in title {
		rw := i32(rune_display_width(ch))
		if rw == 0 {
			continue
		}
		if used_w + rw > max_title_w {
			break
		}
		eff_bg := bg
		if eff_bg.kind == .Default && cx >= 0 && cx < s.width && r.y >= 0 && r.y < s.height {
			eff_bg = s.back[int(r.y * s.width + cx)].bg
		}
		put_cell_clipped(s, cx, r.y, Cell{ch = ch, fg = fg, bg = eff_bg, style = style, width = u8(rw)}, title_clip)
		cx += rw
		used_w += rw
	}
	draw_border_cell(s, cx, r.y, title_clip, ' ', fg, bg, style)
}

draw_vertical_scrollbar :: proc(
	s: ^Screen,
	outer: Rect,
	inner: Rect,
	clip: Rect,
	offset: i32,
	total_content: i32,
	fg, bg: Color,
) {
	track_h := inner.h
	metrics := compute_scrollbar_metrics(track_h, total_content, offset)
	if !metrics.visible {
		return
	}

	sb_x := (outer.x + outer.w - 1) if outer.w > inner.w else (inner.x + inner.w - 1)
	track_y := inner.y

	for row: i32 = 0; row < track_h; row += 1 {
		is_thumb := row >= metrics.thumb_offset && row < (metrics.thumb_offset + metrics.thumb_height)
		y := track_y + row
		eff_bg := bg
		if eff_bg.kind == .Default && sb_x >= 0 && sb_x < s.width && y >= 0 && y < s.height {
			eff_bg = s.back[int(y * s.width + sb_x)].bg
		}
		cell := Cell{
			ch    = '┃' if is_thumb else '│',
			fg    = fg,
			bg    = eff_bg,
			style = {.Bold} if is_thumb else {.Dim},
			width = 1,
		}
		put_cell_clipped(s, sb_x, y, cell, clip)
	}
}

draw_horizontal_scrollbar :: proc(
	s: ^Screen,
	outer: Rect,
	inner: Rect,
	clip: Rect,
	offset_x: i32,
	total_content_w: i32,
	fg, bg: Color,
) {
	track_w := inner.w
	metrics := compute_scrollbar_metrics(track_w, total_content_w, offset_x)
	if !metrics.visible {
		return
	}

	sb_y := (outer.y + outer.h - 1) if outer.h > inner.h else (inner.y + inner.h - 1)
	track_x := inner.x

	for col: i32 = 0; col < track_w; col += 1 {
		is_thumb := col >= metrics.thumb_offset && col < (metrics.thumb_offset + metrics.thumb_height)
		x := track_x + col
		eff_bg := bg
		if eff_bg.kind == .Default && x >= 0 && x < s.width && sb_y >= 0 && sb_y < s.height {
			eff_bg = s.back[int(sb_y * s.width + x)].bg
		}
		cell := Cell{
			ch    = '━' if is_thumb else '─',
			fg    = fg,
			bg    = eff_bg,
			style = {.Bold} if is_thumb else {.Dim},
			width = 1,
		}
		put_cell_clipped(s, x, sb_y, cell, clip)
	}
}

dim_color :: proc "contextless" (c: Color, is_fg: bool) -> Color {
	switch c.kind {
	case .Default:
		return c

	case .ANSI_16:
		idx := c.r
		if idx >= 8 && idx <= 15 {
			if idx == 8 {
				return ansi16(0)
			}
			return ansi16(idx - 8)
		}
		if idx == 7 {
			return ansi16(8)
		}
		if !is_fg {
			return ansi16(0)
		}
		return c

	case .ANSI_256:
		idx := c.r
		// Band 1a: Standard ANSI 0..7
		if idx < 8 {
			return ansi256(ANSI_16_DARK_TO_256[idx])
		}
		// Band 1b: Bright ANSI 8..15
		if idx < 16 {
			if idx == 8 {
				return ansi256(238) // Gray(68,68,68)
			}
			return ansi256(idx - 8)
		}
		// Band 2: 6x6x6 RGB Color Cube (16..231)
		if idx <= 231 {
			offset := idx - 16
			r6 := offset / 36
			g6 := (offset / 6) % 6
			b6 := offset % 6

			// Neutral cube grays (16, 59, 102, 145, 188, 231) -> project onto 232..255 grayscale ramp
			if r6 == g6 && g6 == b6 {
				if r6 == 0 {
					return ansi256(16)
				}
				lum := int(CUBE_LEVELS[r6]) >> 1
				g_step := clamp((lum - 8 + 5) / 10, 0, 23)
				return ansi256(u8(232 + g_step))
			}

			dr := r6 >> 1
			dg := g6 >> 1
			db := b6 >> 1
			// Prevent dark chromatic cube colors (max(r6,g6,b6) == 1) from collapsing to pure black 16
			if dr == 0 && dg == 0 && db == 0 {
				return ansi256(234) // Dark gray (28,28,28)
			}
			return ansi256(16 + 36 * dr + 6 * dg + db)
		}

		// Band 3: 24-Step Grayscale Ramp (232..255)
		g_idx := int(idx - 232)
		lum := (8 + 10 * g_idx) >> 1
		if lum < 6 {
			return ansi256(16)
		}
		g_step := clamp((lum - 8 + 5) / 10, 0, 23)
		return ansi256(u8(232 + g_step))

	case .RGB:
		return Color{
			kind = .RGB,
			r    = c.r >> 1,
			g    = c.g >> 1,
			b    = c.b >> 1,
		}
	}
	return c
}

// Dims all existing cells inside `bounds` in-place while healing boundary-split wide cells.
dim_rect_backdrop :: proc(s: ^Screen, bounds: Rect) {
	screen_bounds := Rect{x = 0, y = 0, w = s.width, h = s.height}
	eff := rect_intersect(bounds, screen_bounds)
	if eff.w <= 0 || eff.h <= 0 {
		return
	}

	for y := eff.y; y < eff.y + eff.h; y += 1 {
		// Heal wide cell bisected by the left edge of the dim rect
		if eff.x > 0 {
			left_idx := int(y * s.width + eff.x)
			if s.back[left_idx].width == 0 {
				heal_overwrite_at(s, eff.x, y)
				s.back[left_idx].ch    = ' '
				s.back[left_idx].width = 1
			}
		}
		// Heal wide cell bisected by the right edge of the dim rect
		right_col := eff.x + eff.w - 1
		if right_col + 1 < s.width {
			right_idx := int(y * s.width + right_col)
			if s.back[right_idx].width == 2 {
				heal_overwrite_at(s, right_col, y)
				s.back[right_idx].ch    = ' '
				s.back[right_idx].width = 1
			}
		}

		row_offset := y * s.width
		for x := eff.x; x < eff.x + eff.w; x += 1 {
			idx := int(row_offset + x)
			c := s.back[idx]
			c.fg    = dim_color(c.fg, true)
			c.bg    = dim_color(c.bg, false)
			c.style = (c.style - {.Bold}) + {.Dim}
			s.back[idx] = c
		}
	}
}

// =============================================================================
// Z-Sorted Layout Tree Rasterizer
// =============================================================================

render_layout :: proc(s: ^Screen, ctx: ^Layout_Context, temp_alloc := context.temp_allocator) {
	_ = temp_alloc
	node_count := len(ctx.nodes)
	rec := resolve_recorder(s.recorder if s.recorder != nil else ctx.recorder)
	heimdall.scoped_span(rec, TELEMETRY_SCOPE_RENDERER, "render_layout", i64(node_count))

	if node_count == 0 {
		return
	}

	screen_bounds := Rect{x = 0, y = 0, w = s.width, h = s.height}

	for idx in ctx.z_order {
		node := ctx.nodes[idx]
		node_clip  := node.node_clip
		inner_clip := node.inner_clip

		paint := s.paints[node.id_hash]

		// 1. Apply backdrop dimming over lower z_layers before painting this node
		switch paint.backdrop {
		case .None:
		case .Dim_Screen:
			dim_rect_backdrop(s, screen_bounds)
		case .Dim_Rect:
			dim_rect_backdrop(s, node_clip)
		}

		if node_clip.w <= 0 || node_clip.h <= 0 {
			continue
		}

		// 2. Fill background if requested or if a non-default bg color or fill_char is set
		if paint.fill_bg || paint.bg.kind != .Default || paint.fill_char != 0 {
			ch := paint.fill_char if paint.fill_char != 0 else ' '
			fill_rect(s, node.rect, node_clip, ch, paint.fg, paint.bg, paint.style)
		}

		// 3. Draw border, optional title, and vertical scrollbar
		if node.config.border != .None {
			b_fg := paint.border_fg if paint.border_fg.kind != .Default else paint.fg
			draw_border(s, node.rect, node_clip, node.config.border, b_fg, paint.bg, paint.style)

			if len(paint.title) > 0 && node.rect.w > 4 {
				t_fg := paint.title_fg if paint.title_fg.kind != .Default else b_fg
				t_style := paint.title_style if paint.title_style != {} else paint.style
				draw_border_title(s, node.rect, node_clip, paint.title, t_fg, paint.bg, t_style)
			}
		}

		t_entry, has_table := s.table_entries[node.id_hash]
		table_hdr_rows := t_entry.header_rows if has_table else 0
		eff_v_inner := Rect{
			x = node.inner_rect.x,
			y = node.inner_rect.y + table_hdr_rows,
			w = node.inner_rect.w,
			h = max(0, node.inner_rect.h - table_hdr_rows),
		}
		if node.config.scrollable && node.content_span[1] > eff_v_inner.h && eff_v_inner.h > 0 {
			sb_fg := paint.border_fg if paint.border_fg.kind != .Default else paint.fg
			draw_vertical_scrollbar(
				s,
				node.rect,
				eff_v_inner,
				node_clip,
				node.config.scroll_offset,
				node.content_span[1],
				sb_fg,
				paint.bg,
			)
		}

		if node.config.scrollable && node.content_span[0] > node.inner_rect.w {
			sb_fg := paint.border_fg if paint.border_fg.kind != .Default else paint.fg
			draw_horizontal_scrollbar(
				s,
				node.rect,
				node.inner_rect,
				node_clip,
				node.config.scroll_offset_x,
				node.content_span[0],
				sb_fg,
				paint.bg,
			)
		}

		// 3b. Multi-line text_area custom line/gutter/selection/cursor renderer
		if node.config.text_area {
			render_text_area_node(s, node, paint, inner_clip, node_clip)
			continue
		}

		// 4. Draw wrapped or single-line text inside inner_rect
		if inner_clip.w > 0 && inner_clip.h > 0 {
			h_align := node.config.main_align if node.config.dir == .Row else node.config.cross_align
			v_align := node.config.cross_align if node.config.dir == .Row else node.config.main_align

			if len(node.wrapped_lines) > 0 && node.config.wrap_mode != .None {
				total_lines := i32(len(node.wrapped_lines))
				base_y := node.inner_rect.y + align_offset(node.inner_rect.h, total_lines, v_align)
				for line, line_idx in node.wrapped_lines {
					line_w := string_display_width(line)
					tx := node.inner_rect.x + align_offset(node.inner_rect.w, line_w, h_align)
					ty := base_y + i32(line_idx)
					draw_string_clipped(s, tx, ty, inner_clip, line, paint.fg, paint.bg, paint.style)
				}
			} else if len(paint.spans) > 0 {
				spans_w: i32 = 0
				for sp in paint.spans {
					spans_w += string_display_width(sp.text)
				}
				tx := node.inner_rect.x + align_offset(node.inner_rect.w, spans_w, h_align)
				ty := node.inner_rect.y + align_offset(node.inner_rect.h, 1, v_align)
				cur_x := tx
				for sp in paint.spans {
					sp_fg := sp.fg if sp.fg.kind != .Default else paint.fg
					sp_bg := sp.bg if sp.bg.kind != .Default else paint.bg
					cur_x += put_text_clipped(s, cur_x, ty, sp.text, sp_fg, sp_bg, paint.style + sp.style, inner_clip)
				}
			} else {
				text_str := paint.text if len(paint.text) > 0 else node.text
				if len(text_str) > 0 {
					text_w := string_display_width(text_str)
					tx := node.inner_rect.x + align_offset(node.inner_rect.w, text_w, h_align)
					ty := node.inner_rect.y + align_offset(node.inner_rect.h, 1, v_align)
					draw_string_clipped(s, tx, ty, inner_clip, text_str, paint.fg, paint.bg, paint.style)
				}
			}

			if c_entry, has_canvas := s.canvas_entries[node.id_hash]; has_canvas {
				render_canvas_entry(s, node, paint, c_entry, temp_alloc)
			}
			if has_table {
				render_table_entry(s, node, paint, t_entry)
			}
		}

		// 5. Invert block cursor cell for focused text input widgets
		if paint.has_cursor && inner_clip.w > 0 && inner_clip.h > 0 {
			cx := node.inner_rect.x + paint.cursor_col
			cy := node.inner_rect.y + align_offset(node.inner_rect.h, 1, node.config.cross_align)
			if point_in_rect(cx, cy, inner_clip) && cx >= 0 && cx < s.width && cy >= 0 && cy < s.height {
				c_idx := int(cy * s.width + cx)
				cur_cell := s.back[c_idx]
				if cur_cell.width == 0 {
					heal_overwrite_at(s, cx, cy)
					cur_cell = s.back[c_idx]
					cur_cell.ch    = ' '
					cur_cell.width = 1
				}
				cur_cell.fg = paint.fg if paint.fg.kind != .Default else cur_cell.fg
				cur_cell.style += {.Reverse, .Bold}
				s.back[c_idx] = cur_cell
				if cur_cell.width == 2 && cx + 1 < s.width {
					s.back[c_idx + 1].fg    = cur_cell.fg
					s.back[c_idx + 1].style = cur_cell.style
				}
			}
		}
	}
}

// =============================================================================
// Minimal ANSI Diff Emitter (DEC Mode 2026 Synchronized Output)
// =============================================================================

screen_diff_ansi :: proc(s: ^Screen, out: ^strings.Builder) -> int {
	rec := resolve_recorder(s.recorder)
	heimdall.scoped_span(rec, TELEMETRY_SCOPE_RENDERER, "screen_diff_ansi", i64(s.width) * i64(s.height))
	start_len := len(out.buf)

	cur_x := i32(-1)
	cur_y := i32(-1)
	cur_fg := Color{kind = .Default}
	cur_bg := Color{kind = .Default}
	cur_style := Style_Flags{}
	sgr_initialized := false
	emitted_any := false

	for y: i32 = 0; y < s.height; y += 1 {
		row_base := int(y * s.width)
		last_dirty_x: i32 = -1
		if !s.first_frame {
			for rx: i32 = 0; rx < s.width; rx += 1 {
				r_idx := row_base + int(rx)
				if s.back[r_idx] != s.front[r_idx] {
					last_dirty_x = rx
				}
			}
		}
		force_row_flush := false
		x: i32 = 0
		for x < s.width {
			idx := row_base + int(x)
			next := s.back[idx]
			prev := s.front[idx]

			// Trailing spacer cell of a 2-column glyph is never emitted directly
			if next.width == 0 {
				s.front[idx] = next
				x += 1
				continue
			}

			dirty := s.first_frame || (next != prev) || (force_row_flush && x <= last_dirty_x)
			if next.width == 2 && x + 1 < s.width {
				if s.back[idx + 1] != s.front[idx + 1] {
					dirty = true
				}
			}

			if !dirty {
				x += i32(max(1, next.width))
				continue
			}

			if prev.width != 1 || next.width != 1 || prev.ch >= 0x2000 || next.ch >= 0x2000 {
				force_row_flush = true
			}

			if !emitted_any {
				// Begin DEC Mode 2026 Synchronized Update
				strings.write_string(out, "\x1b[?2026h")
				emitted_any = true
			}

			// Emit 1-based cursor position only when non-contiguous
			if x != cur_x || y != cur_y {
				strings.write_string(out, "\x1b[")
				strings.write_int(out, int(y + 1))
				strings.write_byte(out, ';')
				strings.write_int(out, int(x + 1))
				strings.write_byte(out, 'H')
			}

			// Emit SGR sequence only when style or colors differ from active state
			if !sgr_initialized || next.fg != cur_fg || next.bg != cur_bg || next.style != cur_style {
				emit_sgr_transition(out, cur_fg, cur_bg, cur_style, next.fg, next.bg, next.style, !sgr_initialized)
				cur_fg = next.fg
				cur_bg = next.bg
				cur_style = next.style
				sgr_initialized = true
			}

			ch := next.ch if next.ch != 0 else ' '
			strings.write_rune(out, ch)

			s.front[idx] = next
			if next.width == 2 && x + 1 < s.width {
				s.front[idx + 1] = s.back[idx + 1]
				// Re-anchor cursor position after 2-column glyphs so any terminal font/wcwidth
				// discrepancy cannot shift subsequent characters on the same row.
				cur_x = -1
				cur_y = -1
				x += 2
			} else {
				// Also re-anchor after non-box-drawing astral/symbol glyphs (>= U+2300, excluding 2500..259F & 2800..28FF)
				if ch >= 0x2300 && !(ch >= 0x2500 && ch <= 0x259f) && !(ch >= 0x2800 && ch <= 0x28ff) {
					cur_x = -1
					cur_y = -1
				} else {
					cur_x = x + 1
					cur_y = y
				}
				x += 1
			}
		}
	}

	if emitted_any {
		// Reset SGR attributes and end Synchronized Update
		strings.write_string(out, "\x1b[0m\x1b[?2026l")
	}

	s.first_frame = false
	diff_bytes := len(out.buf) - start_len
	heimdall.histogram_record(rec, TELEMETRY_SCOPE_RENDERER, "ansi_diff_bytes", f64(diff_bytes), i64(diff_bytes))
	return diff_bytes
}

emit_sgr_transition :: proc(
	out: ^strings.Builder,
	old_fg, old_bg: Color,
	old_style: Style_Flags,
	new_fg, new_bg: Color,
	new_style: Style_Flags,
	force_reset: bool,
) {
	strings.write_string(out, "\x1b[")
	first := true

	removed_styles := old_style - new_style
	need_reset := force_reset || removed_styles != {}

	if need_reset {
		strings.write_byte(out, '0')
		first = false
	}

	styles_to_apply := new_style if need_reset else (new_style - old_style)
	for flag in styles_to_apply {
		if !first {
			strings.write_byte(out, ';')
		}
		first = false
		switch flag {
		case .Bold:          strings.write_byte(out, '1')
		case .Dim:           strings.write_byte(out, '2')
		case .Italic:        strings.write_byte(out, '3')
		case .Underline:     strings.write_byte(out, '4')
		case .Blink:         strings.write_byte(out, '5')
		case .Reverse:       strings.write_byte(out, '7')
		case .Strikethrough: strings.write_byte(out, '9')
		}
	}

	if need_reset || new_fg != old_fg {
		if !(need_reset && new_fg.kind == .Default) {
			if !first {
				strings.write_byte(out, ';')
			}
			first = false
			write_color_sgr(out, new_fg, false)
		}
	}

	if need_reset || new_bg != old_bg {
		if !(need_reset && new_bg.kind == .Default) {
			if !first {
				strings.write_byte(out, ';')
			}
			first = false
			write_color_sgr(out, new_bg, true)
		}
	}

	strings.write_byte(out, 'm')
}

color_to_rgb :: proc "contextless" (c: Color, is_bg: bool) -> (r, g, b: u8) {
	switch c.kind {
	case .RGB:
		return c.r, c.g, c.b
	case .ANSI_16:
		ANSI_16_RGB := [16][3]u8{
			0  = {30, 30, 30},
			1  = {244, 71, 71},
			2  = {106, 153, 85},
			3  = {220, 220, 170},
			4  = {86, 156, 214},
			5  = {197, 134, 192},
			6  = {78, 201, 176},
			7  = {212, 212, 212},
			8  = {128, 128, 128},
			9  = {244, 71, 71},
			10 = {106, 153, 85},
			11 = {220, 220, 170},
			12 = {86, 156, 214},
			13 = {197, 134, 192},
			14 = {78, 201, 176},
			15 = {255, 255, 255},
		}
		idx := clamp(c.r, 0, 15)
		return ANSI_16_RGB[idx][0], ANSI_16_RGB[idx][1], ANSI_16_RGB[idx][2]
	case .ANSI_256:
		if c.r < 16 {
			return color_to_rgb(Color{kind = .ANSI_16, r = c.r}, is_bg)
		} else if c.r < 232 {
			idx := c.r - 16
			r_val := CUBE_LEVELS[idx / 36]
			g_val := CUBE_LEVELS[(idx / 6) % 6]
			b_val := CUBE_LEVELS[idx % 6]
			return r_val, g_val, b_val
		} else {
			gray := 8 + (c.r - 232) * 10
			return gray, gray, gray
		}
	case .Default:
		if is_bg {
			return 22, 26, 34
		} else {
			return 216, 222, 233
		}
	}
	return 0, 0, 0
}

write_html_escaped_rune :: proc(out: ^strings.Builder, r: rune) {
	switch r {
	case '&': strings.write_string(out, "&amp;")
	case '<': strings.write_string(out, "&lt;")
	case '>': strings.write_string(out, "&gt;")
	case '"': strings.write_string(out, "&quot;")
	case:     strings.write_rune(out, r)
	}
}

write_html_escaped_string :: proc(out: ^strings.Builder, str: string) {
	for r in str {
		write_html_escaped_rune(out, r)
	}
}

screen_export_html :: proc(s: ^Screen, title: string, out: ^strings.Builder) {
	if s == nil || s.width <= 0 || s.height <= 0 || len(s.front) == 0 {
		return
	}

	win_bg_r: u8 = 22
	win_bg_g: u8 = 26
	win_bg_b: u8 = 34
	if s.front[0].bg.kind == .RGB {
		win_bg_r = s.front[0].bg.r
		win_bg_g = s.front[0].bg.g
		win_bg_b = s.front[0].bg.b
	}

	strings.write_string(out, "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<style>\n")
	strings.write_string(out, "* { box-sizing: border-box; }\n")
	strings.write_string(out, "body {\n  margin: 0;\n  padding: 24px;\n  background: #0d1117;\n  display: inline-block;\n}\n")
	strings.write_string(out, ".window {\n  background: rgb(")
	strings.write_int(out, int(win_bg_r))
	strings.write_string(out, ", ")
	strings.write_int(out, int(win_bg_g))
	strings.write_string(out, ", ")
	strings.write_int(out, int(win_bg_b))
	strings.write_string(out, ");\n  border-radius: 10px;\n  box-shadow: 0 20px 50px rgba(0, 0, 0, 0.75), 0 0 0 1px rgba(255, 255, 255, 0.12);\n  overflow: hidden;\n  display: inline-block;\n}\n")
	strings.write_string(out, ".titlebar {\n  background: #181d26;\n  padding: 10px 14px;\n  display: flex;\n  align-items: center;\n  border-bottom: 1px solid rgba(255, 255, 255, 0.08);\n  position: relative;\n}\n")
	strings.write_string(out, ".dots { display: flex; gap: 7px; }\n")
	strings.write_string(out, ".dot { width: 11px; height: 11px; border-radius: 50%; display: inline-block; }\n")
	strings.write_string(out, ".dot-red { background: #ff5f56; }\n")
	strings.write_string(out, ".dot-yellow { background: #ffbd2e; }\n")
	strings.write_string(out, ".dot-green { background: #27c93f; }\n")
	strings.write_string(out, ".title {\n  position: absolute;\n  left: 0;\n  right: 0;\n  text-align: center;\n  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;\n  font-size: 13px;\n  font-weight: 600;\n  color: #9499a8;\n  letter-spacing: 0.2px;\n  pointer-events: none;\n}\n")
	strings.write_string(out, ".screen {\n  padding: 12px 16px;\n  font-family: 'FiraCode Nerd Font', 'Fira Code', 'DejaVu Sans Mono', monospace;\n  font-size: 14px;\n  color: #d8dee9;\n}\n")
	strings.write_string(out, ".line {\n  margin: 0;\n  padding: 0;\n  height: 18px;\n  line-height: 18px;\n  white-space: pre;\n  display: block;\n}\n")
	strings.write_string(out, ".line span {\n  display: inline-block;\n  height: 18px;\n  line-height: 18px;\n  vertical-align: top;\n}\n")
	strings.write_string(out, "</style>\n</head>\n<body>\n<div class=\"window\">\n  <div class=\"titlebar\">\n")
	strings.write_string(out, "    <div class=\"dots\">\n      <span class=\"dot dot-red\"></span>\n      <span class=\"dot dot-yellow\"></span>\n      <span class=\"dot dot-green\"></span>\n    </div>\n")
	strings.write_string(out, "    <div class=\"title\">")
	write_html_escaped_string(out, title)
	strings.write_string(out, "</div>\n  </div>\n  <div class=\"screen\">")

	for y: i32 = 0; y < s.height; y += 1 {
		strings.write_string(out, "<div class=\"line\">")
		row_base := int(y * s.width)
		x: i32 = 0
		for x < s.width {
			cell := s.front[row_base + int(x)]
			if cell.width == 0 {
				x += 1
				continue
			}

			eff_fg := cell.fg
			eff_bg := cell.bg
			eff_style := cell.style
			if .Reverse in eff_style {
				eff_fg, eff_bg = eff_bg, eff_fg
			}

			run_len: i32 = 0
			for x + run_len < s.width {
				c2 := s.front[row_base + int(x + run_len)]
				if c2.width == 0 {
					run_len += 1
					continue
				}
				c2_fg := c2.fg
				c2_bg := c2.bg
				c2_style := c2.style
				if .Reverse in c2_style {
					c2_fg, c2_bg = c2_bg, c2_fg
				}
				if !colors_equal(c2_fg, eff_fg) || !colors_equal(c2_bg, eff_bg) || (c2_style - {.Reverse}) != (eff_style - {.Reverse}) {
					break
				}
				run_len += 1
			}

			has_custom_fg := eff_fg.kind != .Default
			has_custom_bg := eff_bg.kind != .Default
			has_styles := (eff_style - {.Reverse}) != {}

			if has_custom_fg || has_custom_bg || has_styles {
				strings.write_string(out, "<span style=\"width: ")
				strings.write_int(out, int(run_len))
				strings.write_string(out, "ch;")
				if has_custom_fg {
					r, g, b := color_to_rgb(eff_fg, false)
					strings.write_string(out, "color: rgb(")
					strings.write_int(out, int(r))
					strings.write_string(out, ", ")
					strings.write_int(out, int(g))
					strings.write_string(out, ", ")
					strings.write_int(out, int(b))
					strings.write_string(out, ");")
				}
				if has_custom_bg {
					r, g, b := color_to_rgb(eff_bg, true)
					strings.write_string(out, "background-color: rgb(")
					strings.write_int(out, int(r))
					strings.write_string(out, ", ")
					strings.write_int(out, int(g))
					strings.write_string(out, ", ")
					strings.write_int(out, int(b))
					strings.write_string(out, ");")
				}
				if .Bold in eff_style {
					strings.write_string(out, "font-weight: bold;")
				}
				if .Dim in eff_style {
					strings.write_string(out, "opacity: 0.65;")
				}
				if .Italic in eff_style {
					strings.write_string(out, "font-style: italic;")
				}
				if .Underline in eff_style {
					strings.write_string(out, "text-decoration: underline;")
				}
				strings.write_string(out, "\">")
			} else {
				strings.write_string(out, "<span style=\"width: ")
				strings.write_int(out, int(run_len))
				strings.write_string(out, "ch;\">")
			}

			for i: i32 = 0; i < run_len; i += 1 {
				rc := s.front[row_base + int(x + i)]
				if rc.width == 0 {
					continue
				}
				ch := rc.ch if rc.ch != 0 else ' '
				write_html_escaped_rune(out, ch)
			}

			strings.write_string(out, "</span>")

			x += run_len
		}
		strings.write_string(out, "</div>")
	}

	strings.write_string(out, "</div>\n</div>\n</body>\n</html>\n")
}

write_color_sgr :: proc(out: ^strings.Builder, c: Color, is_bg: bool) {
	switch c.kind {
	case .Default:
		strings.write_string(out, "49" if is_bg else "39")
	case .ANSI_16:
		idx := int(c.r)
		code := (40 + idx) if is_bg else (30 + idx)
		if idx >= 8 {
			code = (100 + (idx - 8)) if is_bg else (90 + (idx - 8))
		}
		strings.write_int(out, code)
	case .ANSI_256:
		strings.write_string(out, "48;5;" if is_bg else "38;5;")
		strings.write_int(out, int(c.r))
	case .RGB:
		strings.write_string(out, "48;2;" if is_bg else "38;2;")
		strings.write_int(out, int(c.r))
		strings.write_byte(out, ';')
		strings.write_int(out, int(c.g))
		strings.write_byte(out, ';')
		strings.write_int(out, int(c.b))
	}
}
