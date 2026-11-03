package bifrost

// =============================================================================
// Virtualized List & Scrollable Viewport Widget (O(1) Visible Slice for xitdb)
// =============================================================================

Virtual_List_Config :: struct {
	title:          string,
	width:          Axis_Size,
	height:         Axis_Size,
	border:         Border_Kind,
	fg:             Color,
	bg:             Color,
	border_fg:      Color,
	title_fg:       Color,
	scroll_step:    i32,
	scroll_padding: i32,
	fallback_rows:  i32, // Estimated visible rows on Frame 0 before first layout solve
	focusable:      bool,
}

Virtual_Slice :: struct {
	start_row:     i32, // Inclusive start index into xitdb ArrayList / Filtered View
	end_row:       i32, // Exclusive end index into xitdb ArrayList / Filtered View
	selected_row:  i32, // Currently highlighted row index
	scroll_offset: i32, // Clamped top visible row index
	viewport_rows: i32, // Number of visible rows in the container
	total_rows:    i32, // Total logical rows in dataset
}

@(deferred_in = defer_end_virtual_list)
ui_virtual_list :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	total_rows: i32,
	cfg: Virtual_List_Config,
	out_slice: ^Virtual_Slice,
) -> bool {
	id_h := hash_id(id)
	slot := get_scroll_slot(inp, id_h)

	if slot.viewport_rows <= 0 {
		slot.viewport_rows = cfg.fallback_rows if cfg.fallback_rows > 0 else 10
	}
	slot.total_rows     = max(0, total_rows)
	slot.max_offset     = max(0, slot.total_rows - slot.viewport_rows)
	slot.offset         = clamp(slot.offset, 0, slot.max_offset)
	slot.selected_row   = clamp(slot.selected_row, 0, max(0, slot.total_rows - 1))
	slot.scroll_padding = max(0, cfg.scroll_padding)

	start_r := slot.offset
	end_r   := min(slot.total_rows, start_r + slot.viewport_rows)

	if out_slice != nil {
		out_slice^ = Virtual_Slice{
			start_row     = start_r,
			end_row       = end_r,
			selected_row  = slot.selected_row,
			scroll_offset = slot.offset,
			viewport_rows = slot.viewport_rows,
			total_rows    = slot.total_rows,
		}
	}

	w := cfg.width if cfg.width != nil else grow(1)
	h := cfg.height if cfg.height != nil else grow(1)
	step := cfg.scroll_step if cfg.scroll_step > 0 else 3

	s.paints[id_h] = Paint_Spec{
		title       = cfg.title,
		fg          = cfg.fg,
		bg          = cfg.bg,
		border_fg   = cfg.border_fg,
		title_fg    = cfg.title_fg,
		title_style = {.Bold},
		fill_bg     = cfg.bg.kind != .Default,
	}

	idx := push_node(ctx, id, Box_Config{
		dir                = .Column,
		width              = w,
		height             = h,
		border             = cfg.border,
		scrollable         = true,
		scroll_offset      = slot.offset,
		scroll_step        = step,
		virtual_total_rows = max(1, slot.total_rows),
		focusable          = true,
	}, {0, 0})
	append(&ctx.parent_stack, idx)
	return true
}

defer_end_virtual_list :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	total_rows: i32,
	cfg: Virtual_List_Config,
	out_slice: ^Virtual_Slice,
) {
	if len(ctx.parent_stack) > 0 {
		pop(&ctx.parent_stack)
	}
}

// =============================================================================
// 64-Bit Proportional Scrollbar Metrics with Interior-Detent Clamping
// =============================================================================

Scrollbar_Metrics :: struct {
	visible:      bool,
	thumb_offset: i32,
	thumb_height: i32,
	track_height: i32,
}

// Computes proportional scrollbar thumb height and position using 64-bit integer math
// with interior-detent clamping:
// - thumb_offset == 0 iff scroll_offset <= 0
// - thumb_offset == track_avail iff scroll_offset >= max_scroll
// - 1 <= thumb_offset <= track_avail - 1 for all intermediate offsets when track_avail >= 2
compute_scrollbar_metrics :: proc "contextless" (
	track_h: i32,
	total_content: i32,
	scroll_offset: i32,
) -> Scrollbar_Metrics {
	if track_h <= 0 || total_content <= track_h {
		return Scrollbar_Metrics{
			visible      = false,
			thumb_offset = 0,
			thumb_height = max(0, track_h),
			track_height = max(0, track_h),
		}
	}

	max_scroll := max(1, total_content - track_h)
	clamped_off := clamp(scroll_offset, 0, max_scroll)

	thumb_num := i64(track_h) * i64(track_h) + i64(total_content) / 2
	raw_thumb_h := i32(thumb_num / i64(total_content))
	max_thumb_h := max(1, track_h - 1)
	thumb_h := clamp(raw_thumb_h, 1, max_thumb_h)
	track_avail := track_h - thumb_h

	thumb_offset: i32 = 0
	if track_avail > 0 {
		if clamped_off <= 0 {
			thumb_offset = 0
		} else if clamped_off >= max_scroll {
			thumb_offset = track_avail
		} else if track_avail == 1 {
			thumb_offset = 1 if i64(clamped_off) * 2 >= i64(max_scroll) else 0
		} else {
			pos_num := i64(clamped_off) * i64(track_avail) + i64(max_scroll) / 2
			raw_off := i32(pos_num / i64(max_scroll))
			thumb_offset = clamp(raw_off, 1, track_avail - 1)
		}
	}

	return Scrollbar_Metrics{
		visible      = true,
		thumb_offset = thumb_offset,
		thumb_height = thumb_h,
		track_height = track_h,
	}
}

// =============================================================================
// Jitter-Free Virtual Table Column Solver (Ratatui Constraint Solver + High-Water Mark)
// =============================================================================

Column_Align :: enum u8 {
	Left = 0,
	Center,
	Right,
}

Column_Width_Kind :: enum u8 {
	Fixed = 0,     // Exact width in cells (value or fixed_width)
	Fill,          // Proportional share of remaining space (value or fill_weight)
	Auto_Content,  // Monotonic high-water-mark max(header_w, observed_visible_cell_w)
}

Table_Column_Spec :: struct {
	header:         string,
	kind:           Column_Width_Kind,
	value:          i32, // Fixed width or Fill weight
	fixed_width:    i32,
	fill_weight:    i32,
	min_width:      i32,
	max_width:      i32,
	max_observed_w: i32, // Monotonically non-decreasing across frames during virtual scrolling
	align:          Column_Align,
}

Table_Column_Span :: struct {
	x:     i32,
	width: i32,
	align: Column_Align,
}

// Records the display width of a cell in a virtualized table column.
// Monotonic high-water-mark clamping ensures scrolling through variable-length rows never jitters left.
table_column_observe_cell :: proc "contextless" (spec: ^Table_Column_Spec, cell_text: string) {
	w := string_display_width(cell_text)
	if w > spec.max_observed_w {
		spec.max_observed_w = w
	}
}

// Resolves horizontal x-positions and widths for a slice of table columns inside `inner_rect`,
// reserving `gutter_width` on the left and `column_spacing` cells between adjacent columns.
resolve_table_columns :: proc "contextless" (
	specs: []Table_Column_Spec,
	out_spans: []Table_Column_Span,
	inner_rect: Rect,
	gutter_width: i32 = 0,
	column_spacing: i32 = 1,
) -> i32 {
	count := min(len(specs), len(out_spans))
	if count == 0 {
		return 0
	}

	gutter := max(0, gutter_width)
	total_gaps := i32(max(0, count - 1)) * max(0, column_spacing)
	avail_w := max(0, inner_rect.w - gutter - total_gaps)

	used_w: i32 = 0
	total_weight: i32 = 0

	// Pass 1: Resolve Fixed and Auto_Content columns
	for i := 0; i < count; i += 1 {
		spec := &specs[i]
		header_w := string_display_width(spec.header)
		if header_w > spec.max_observed_w {
			spec.max_observed_w = header_w
		}

		min_w := max(1, spec.min_width)
		max_w := spec.max_width if spec.max_width > 0 else avail_w

		w: i32 = 0
		switch spec.kind {
		case .Fixed:
			fw := spec.value if spec.value > 0 else spec.fixed_width
			w = clamp(fw, min_w, max(min_w, max_w))
			used_w += w
		case .Auto_Content:
			w = clamp(spec.max_observed_w, min_w, max(min_w, max_w))
			used_w += w
		case .Fill:
			weight := spec.value if spec.value > 0 else spec.fill_weight
			total_weight += max(1, weight)
		}

		out_spans[i] = Table_Column_Span{
			width = w,
			align = spec.align,
		}
	}

	// Pass 2: Distribute remaining space across Fill columns
	rem_w := max(0, avail_w - used_w)
	if total_weight > 0 && rem_w > 0 {
		distributed: i32 = 0
		last_fill_idx := -1
		for i := 0; i < count; i += 1 {
			if specs[i].kind != .Fill {
				continue
			}
			last_fill_idx = i
			raw_weight := specs[i].value if specs[i].value > 0 else specs[i].fill_weight
			weight := max(1, raw_weight)
			share := i32((i64(rem_w) * i64(weight)) / i64(total_weight))
			min_w := max(1, specs[i].min_width)
			max_w := specs[i].max_width if specs[i].max_width > 0 else avail_w
			w := clamp(share, min_w, max(min_w, max_w))
			out_spans[i].width = w
			distributed += w
		}
		leftover := rem_w - distributed
		if leftover > 0 && last_fill_idx >= 0 {
			max_w := specs[last_fill_idx].max_width if specs[last_fill_idx].max_width > 0 else avail_w
			out_spans[last_fill_idx].width = min(out_spans[last_fill_idx].width + leftover, max(out_spans[last_fill_idx].width, max_w))
		}
	}

	// Pass 3: Assign x-coordinates and clamp against inner_rect right edge
	cur_x := inner_rect.x + gutter
	right_limit := inner_rect.x + inner_rect.w
	for i := 0; i < count; i += 1 {
		out_spans[i].x = cur_x
		if cur_x + out_spans[i].width > right_limit {
			out_spans[i].width = max(0, right_limit - cur_x)
		}
		cur_x += out_spans[i].width + max(0, column_spacing)
	}

	return i32(count)
}

// Draws aligned cell text inside a resolved table column span at row `y`.
draw_table_cell :: proc(
	s: ^Screen,
	span: Table_Column_Span,
	y: i32,
	clip: Rect,
	text: string,
	fg, bg: Color,
	style: Style_Flags = {},
) {
	if span.width <= 0 {
		return
	}
	cell_rect := Rect{x = span.x, y = y, w = span.width, h = 1}
	cell_clip := rect_intersect(clip, cell_rect)
	if cell_clip.w <= 0 || cell_clip.h <= 0 {
		return
	}

	text_w := string_display_width(text)
	offset_x: i32 = 0
	switch span.align {
	case .Left:
		offset_x = 0
	case .Center:
		if span.width > text_w {
			offset_x = (span.width - text_w) / 2
		}
	case .Right:
		if span.width > text_w {
			offset_x = span.width - text_w
		}
	}
	put_text_clipped(s, span.x + offset_x, y, text, fg, bg, style, cell_clip)
}

// =============================================================================
// Box-Drawing Border Presets & 4-Bit Direction Mask Junction Merging
// =============================================================================

Border_Spec :: struct {
	top, bottom, left, right:                         rune,
	top_left, top_right, bottom_left, bottom_right:   rune,
	middle_left, middle_right, middle_top, middle_bottom, middle: rune,
}

NORMAL_BORDER :: Border_Spec{
	top = '─', bottom = '─', left = '│', right = '│',
	top_left = '┌', top_right = '┐', bottom_left = '└', bottom_right = '┘',
	middle_left = '├', middle_right = '┤', middle_top = '┬', middle_bottom = '┴', middle = '┼',
}

ROUNDED_BORDER :: Border_Spec{
	top = '─', bottom = '─', left = '│', right = '│',
	top_left = '╭', top_right = '╮', bottom_left = '╰', bottom_right = '╯',
	middle_left = '├', middle_right = '┤', middle_top = '┬', middle_bottom = '┴', middle = '┼',
}

THICK_BORDER :: Border_Spec{
	top = '━', bottom = '━', left = '┃', right = '┃',
	top_left = '┏', top_right = '┓', bottom_left = '┗', bottom_right = '┛',
	middle_left = '┣', middle_right = '┫', middle_top = '┳', middle_bottom = '┻', middle = '╋',
}

DOUBLE_BORDER :: Border_Spec{
	top = '═', bottom = '═', left = '║', right = '║',
	top_left = '╔', top_right = '╗', bottom_left = '╚', bottom_right = '╝',
	middle_left = '╠', middle_right = '╣', middle_top = '╦', middle_bottom = '╩', middle = '╬',
}

Box_Dir :: enum u8 {
	North = 0,
	East  = 1,
	South = 2,
	West  = 3,
}

Box_Dirs :: bit_set[Box_Dir; u8]

box_rune_dirs :: proc "contextless" (r: rune) -> Box_Dirs {
	switch r {
	case '─', '━', '═': return {.East, .West}
	case '│', '┃', '║': return {.North, .South}
	case '┌', '╭', '┏', '╔': return {.South, .East}
	case '┐', '╮', '┓', '╗': return {.South, .West}
	case '└', '╰', '┗', '╚': return {.North, .East}
	case '┘', '╯', '┛', '╝': return {.North, .West}
	case '├', '┣', '╠': return {.North, .South, .East}
	case '┤', '┫', '╣': return {.North, .South, .West}
	case '┬', '┳', '╦': return {.East, .West, .South}
	case '┴', '┻', '╩': return {.East, .West, .North}
	case '┼', '╋', '╬': return {.North, .East, .South, .West}
	}
	return {}
}

dirs_to_box_rune :: proc "contextless" (dirs: Box_Dirs, spec: Border_Spec = NORMAL_BORDER) -> rune {
	switch dirs {
	case {.East, .West}:                 return spec.top
	case {.North, .South}:               return spec.left
	case {.South, .East}:                return spec.top_left
	case {.South, .West}:                return spec.top_right
	case {.North, .East}:                return spec.bottom_left
	case {.North, .West}:                return spec.bottom_right
	case {.North, .South, .East}:        return spec.middle_left
	case {.North, .South, .West}:        return spec.middle_right
	case {.East, .West, .South}:         return spec.middle_top
	case {.East, .West, .North}:         return spec.middle_bottom
	case {.North, .East, .South, .West}: return spec.middle
	}
	return ' '
}

// Writes a box-drawing rune into `(x, y)` and automatically unions its 4-bit direction mask
// with any existing box-drawing glyph at that cell (e.g. `'─' + '│' -> '┼'`, `'─' + '│'` at top edge -> `'┬'`).
surface_merge_box_cell :: proc(
	s: ^Screen,
	x, y: i32,
	new_rune: rune,
	spec: Border_Spec = NORMAL_BORDER,
	fg: Color = {},
	bg: Color = {},
	style: Style_Flags = {},
	clip: Rect = {},
) {
	screen_bounds := Rect{x = 0, y = 0, w = s.width, h = s.height}
	eff_clip := rect_intersect(clip, screen_bounds) if clip.w > 0 && clip.h > 0 else screen_bounds
	if !point_in_rect(x, y, eff_clip) {
		return
	}
	idx := int(y * s.width + x)
	existing_dirs := box_rune_dirs(s.back[idx].ch)
	new_dirs := box_rune_dirs(new_rune)

	if existing_dirs == {.East, .West} && new_dirs == {.North, .South} {
		has_north := false
		has_south := false
		for yy: i32 = 0; yy < y; yy += 1 {
			if box_rune_dirs(s.back[int(yy * s.width + x)].ch) != {} {
				has_north = true
				break
			}
		}
		for yy: i32 = y + 1; yy < s.height; yy += 1 {
			if box_rune_dirs(s.back[int(yy * s.width + x)].ch) != {} {
				has_south = true
				break
			}
		}
		if has_south && !has_north {
			new_dirs = {.South}
		} else if has_north && !has_south {
			new_dirs = {.North}
		}
	} else if existing_dirs == {.North, .South} && new_dirs == {.East, .West} {
		has_west := false
		has_east := false
		for xx: i32 = 0; xx < x; xx += 1 {
			if box_rune_dirs(s.back[int(y * s.width + xx)].ch) != {} {
				has_west = true
				break
			}
		}
		for xx: i32 = x + 1; xx < s.width; xx += 1 {
			if box_rune_dirs(s.back[int(y * s.width + xx)].ch) != {} {
				has_east = true
				break
			}
		}
		if has_east && !has_west {
			new_dirs = {.East}
		} else if has_west && !has_east {
			new_dirs = {.West}
		}
	}

	merged_dirs := existing_dirs | new_dirs
	final_rune := dirs_to_box_rune(merged_dirs, spec) if merged_dirs != {} else new_rune

	eff_fg := fg if fg.kind != .Default else s.back[idx].fg
	eff_bg := bg if bg.kind != .Default else s.back[idx].bg
	put_cell_clipped(s, x, y, Cell{
		ch    = final_rune,
		fg    = eff_fg,
		bg    = eff_bg,
		style = style,
		width = 1,
	}, eff_clip)
}
