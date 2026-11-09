package bifrost

// =============================================================================
// First-Class Declarative Virtualized Table (`ui_table` / `ui_virtual_table`)
// =============================================================================
//
// Features:
//   - Declarative column layout (`Fixed`, `Fill`, `Auto_Content`) up to `MAX_TABLE_COLS` (256)
//     with monotonic high-water-mark width stabilization across frames (`Scroll_Slot.col_max_observed`)
//   - 2D horizontal column virtualization (`start_col ..< end_col`, `ui_table_is_col_visible`)
//   - Frozen left columns (`pinned_cols`) with `║` / `╫` box-drawing freeze divider
//   - Interactive column sorting (`▲` / `▼` header indicators on click or `s` key)
//   - Interactive column drag resizing & `+` / `-` / `0` auto-fit reset
//   - Optional `Table_Selection_Set` multi-row interval selection & `follow_tail` auto-scroll pinning
//   - Bounded `O(span.width)` single-line cell sanitization (`\n`/`\r`/`\t` -> `' '`) + `…` truncation

Table_Cell :: struct {
	text:  string,
	fg:    Color,
	bg:    Color,
	style: Style_Flags,
}

Table_Row_Entry :: struct {
	row_idx: i32,
	cells:   []Table_Cell,
	fg:      Color,
	bg:      Color,
	style:   Style_Flags,
}

Table_Config :: struct {
	title:            string,
	width:            Axis_Size,
	height:           Axis_Size,
	border:           Border_Kind,
	hide_header:      bool, // When false (default), renders sticky column header row
	hide_header_sep:  bool, // When false (default), renders `─┼─` separator line beneath header
	hide_col_sep:     bool, // When false (default), renders `│` vertical dividers between columns
	column_spacing:   i32,  // Cell spacing between columns (0 = 3 when `!hide_col_sep`, 2 when `hide_col_sep`)
	gutter_width:     i32,  // Left selection gutter width (0 = 2 for `"▸ "`, < 0 disables gutter)
	pinned_cols:      i32,  // Number of frozen left columns (`0 ..< pinned_cols`)
	follow_tail:      bool, // Initial auto-scroll tail-pinning state for streaming tables
	sortable:         bool, // Enables header click & `s` key column sort cycling (`▲`/`▼`)
	resizable:        bool, // Enables mouse divider drag & `+`/`-`/`0` column resizing
	show_row_numbers: bool, // Renders 1-based row numbers in the left gutter when `gutter_width >= 4`
	selection:        ^Table_Selection_Set, // Optional multi-row disjoint interval selection set
	fg:               Color,
	bg:               Color,
	border_fg:        Color,
	title_fg:         Color,
	header_fg:        Color,
	header_bg:        Color,
	sep_fg:           Color,
	sel_fg:           Color,
	sel_bg:           Color,
	multi_sel_fg:     Color,
	multi_sel_bg:     Color,
	active_cell_fg:   Color,
	active_cell_bg:   Color,
	style:            Style_Flags,
	title_style:      Style_Flags,
	fill_bg:          bool,
	scroll_step:      i32,
	scroll_padding:   i32,
	fallback_rows:    i32,
	focus_flags:      Focus_Flags,
}

Table_Render_Entry :: struct {
	id_hash:         u64,
	cfg:             Table_Config,
	columns:         []Table_Column_Spec,
	rows:            [dynamic]Table_Row_Entry,
	header_rows:     i32,
	gutter_w:        i32,
	col_spacing:     i32,
	pinned_cols:     i32,
	pinned_area_w:   i32,
	start_col:       i32,
	end_col:         i32,
	sort_col:        i32,
	sort_dir:        Table_Sort_Dir,
	total_rows:      i32,
	start_row:       i32,
	end_row:         i32,
	selected_row:    i32,
	selected_col:    i32,
	scroll_offset:   i32,
	scroll_offset_x: i32,
	max_offset_x:    i32,
	col_x_starts:    [MAX_TABLE_COLS]i16,
	col_x_widths:    [MAX_TABLE_COLS]i16,
	col_user_widths: [MAX_TABLE_COLS]i16,
	col_is_visible:  [MAX_TABLE_COLS]bool,
	is_focused:      bool,
}

table_effective_gutter_w :: #force_inline proc "contextless" (cfg: Table_Config) -> i32 {
	if cfg.gutter_width < 0 {
		return 0
	}
	if cfg.gutter_width > 0 {
		return cfg.gutter_width
	}
	return 2
}

table_effective_col_spacing :: #force_inline proc "contextless" (cfg: Table_Config) -> i32 {
	if cfg.column_spacing > 0 {
		return cfg.column_spacing
	}
	return 2 if cfg.hide_col_sep else 3
}

table_effective_header_rows :: #force_inline proc "contextless" (cfg: Table_Config, col_count: int) -> i32 {
	if cfg.hide_header || col_count <= 0 {
		return 0
	}
	return 1 if cfg.hide_header_sep else 2
}

// Mounts a focusable, virtualized 2D table container and computes the visible `[start_row, end_row)`
// and `[start_col, end_col)` slices for this frame. Inside the `if ui_table(...)` block, emit visible rows via `ui_table_row(...)`.
@(deferred_in = defer_end_table)
ui_table :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	columns: []Table_Column_Spec,
	total_rows: i32,
	cfg: Table_Config = {},
	out_slice: ^Virtual_Slice = nil,
) -> bool {
	id_h := hash_id(id)
	col_cnt := min(len(columns), MAX_TABLE_COLS)
	hdr_rows := table_effective_header_rows(cfg, col_cnt)
	gutter_w := table_effective_gutter_w(cfg)
	col_sp   := table_effective_col_spacing(cfg)
	pinned   := clamp(cfg.pinned_cols, 0, max(0, i32(col_cnt) - 1))

	slot := get_scroll_slot(inp, id_h)
	slot.header_rows    = u8(clamp(hdr_rows, 0, 15))
	slot.total_rows     = max(0, total_rows)
	slot.total_cols     = max(1, i32(col_cnt))
	slot.pinned_cols    = i16(pinned)
	slot.col_spec_count = u16(col_cnt)
	slot.col_gutter_w   = i8(clamp(gutter_w, 0, 64))
	slot.col_spacing    = i8(clamp(col_sp, 0, 32))
	slot.sortable       = cfg.sortable
	slot.resizable      = cfg.resizable
	if cfg.scroll_padding >= 0 {
		slot.scroll_padding = cfg.scroll_padding
	}

	if !slot.follow_tail_initialized {
		slot.follow_tail             = cfg.follow_tail
		slot.follow_tail_initialized = true
		slot.sort_col                = -1
	}

	fallback := cfg.fallback_rows if cfg.fallback_rows > 0 else 10
	v_rows := slot.viewport_rows if slot.viewport_rows > 0 else fallback
	v_rows = max(1, v_rows)

	max_off := max(0, slot.total_rows - v_rows)
	slot.max_offset = max_off

	if slot.follow_tail && slot.prev_total_rows > 0 && slot.total_rows > slot.prev_total_rows {
		slot.offset       = max_off
		slot.selected_row = max(0, slot.total_rows - 1)
	}

	slot.offset       = clamp(slot.offset, 0, max_off)
	slot.selected_row = clamp(slot.selected_row, 0, max(0, slot.total_rows - 1))
	slot.selected_col = clamp(slot.selected_col, 0, max(0, slot.total_cols - 1))

	reset_auto_size := slot.auto_size_this_frame
	if reset_auto_size {
		for i := 0; i < col_cnt; i += 1 {
			slot.col_max_observed[i] = 0
			slot.col_user_widths[i]  = 0
		}
		slot.auto_size_this_frame = false
	}

	temp_alloc := ctx.allocator if ctx.allocator.procedure != nil else context.temp_allocator
	cols_copy := make([]Table_Column_Spec, col_cnt, temp_alloc)
	populate_slot_column_specs(slot, columns[:col_cnt], i32(slot.sort_col), slot.sort_dir, reset_auto_size)
	for i := 0; i < col_cnt; i += 1 {
		spec := columns[i]
		spec.max_observed_w = i32(slot.col_max_observed[i])
		cols_copy[i]        = spec
	}

	// Pre-solve horizontal column spans using the best known viewport width so `out_slice.start_col ..< end_col`
	// is immediately accurate on this frame before `ui_table_row` cells are formatted.
	est_w := slot.viewport_cols if slot.viewport_cols > 0 else (ctx.screen_size[0] if ctx.screen_size[0] > 0 else 120)
	_ = resolve_slot_table_columns(slot, Rect{x = 0, y = 0, w = max(1, est_w), h = v_rows})

	start_r := clamp(slot.offset, 0, slot.total_rows)
	end_r   := clamp(start_r + v_rows, start_r, slot.total_rows)

	sort_changed := slot.sort_changed
	slot.sort_changed = false

	if out_slice != nil {
		out_slice^ = Virtual_Slice{
			start_row       = start_r,
			end_row         = end_r,
			selected_row    = slot.selected_row,
			selected_col    = slot.selected_col,
			scroll_offset   = slot.offset,
			scroll_offset_x = slot.offset_x,
			viewport_rows   = v_rows,
			total_rows      = slot.total_rows,
			total_cols      = slot.total_cols,
			pinned_cols     = pinned,
			start_col       = i32(slot.start_col),
			end_col         = i32(slot.end_col),
			sort_col        = i32(slot.sort_col),
			sort_dir        = slot.sort_dir,
			sort_changed    = sort_changed,
			follow_tail     = slot.follow_tail,
		}
	}

	if s != nil {
		s.paints[id_h] = Paint_Spec{
			title       = cfg.title,
			fg          = cfg.fg,
			bg          = cfg.bg,
			border_fg   = cfg.border_fg,
			title_fg    = cfg.title_fg,
			style       = cfg.style,
			title_style = cfg.title_style if cfg.title_style != {} else {.Bold},
			fill_bg     = cfg.fill_bg || cfg.bg.kind != .Default,
		}
		rows_dyn := make([dynamic]Table_Row_Entry, 0, int(max(1, end_r - start_r)), temp_alloc)
		s.table_entries[id_h] = Table_Render_Entry{
			id_hash         = id_h,
			cfg             = cfg,
			columns         = cols_copy,
			rows            = rows_dyn,
			header_rows     = hdr_rows,
			gutter_w        = gutter_w,
			col_spacing     = col_sp,
			pinned_cols     = pinned,
			pinned_area_w   = i32(slot.pinned_area_w),
			start_col       = i32(slot.start_col),
			end_col         = i32(slot.end_col),
			sort_col        = i32(slot.sort_col),
			sort_dir        = slot.sort_dir,
			total_rows      = slot.total_rows,
			start_row       = start_r,
			end_row         = end_r,
			selected_row    = slot.selected_row,
			selected_col    = slot.selected_col,
			scroll_offset   = slot.offset,
			scroll_offset_x = slot.offset_x,
			max_offset_x    = slot.max_offset_x,
			col_x_starts    = slot.col_x_starts,
			col_x_widths    = slot.col_x_widths,
			col_user_widths = slot.col_user_widths,
			col_is_visible  = slot.col_is_visible,
			is_focused      = inp.focused_id == id_h,
		}
		s.active_table_id = id_h
	}

	flags := cfg.focus_flags
	if flags == {} {
		flags = {.Focusable}
	}
	w := cfg.width if cfg.width != nil else grow(1)
	h := cfg.height if cfg.height != nil else grow(1)

	idx := push_node(ctx, id, Box_Config{
		dir                = .Column,
		width              = w,
		height             = h,
		border             = cfg.border,
		scrollable         = true,
		scroll_offset      = slot.offset,
		scroll_offset_x    = slot.offset_x,
		scroll_step        = cfg.scroll_step if cfg.scroll_step > 0 else 3,
		virtual_total_rows = max(1, slot.total_rows),
		focus_flags        = flags,
		focusable          = (.Focusable in flags) && (.Disabled not_in flags),
		clickable          = .Disabled not_in flags,
		hoverable          = .Disabled not_in flags,
	}, {0, 0})
	enter_container_node(ctx, idx)
	return true
}

ui_virtual_table :: ui_table

defer_end_table :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	columns: []Table_Column_Spec,
	total_rows: i32,
	cfg: Table_Config = {},
	out_slice: ^Virtual_Slice = nil,
) {
	_ = columns
	_ = total_rows
	_ = cfg
	_ = out_slice
	if s != nil {
		id_h := hash_id(id)
		if entry, ok := &s.table_entries[id_h]; ok && inp != nil {
			slot := get_scroll_slot(inp, id_h)
			cnt := min(len(entry.columns), MAX_TABLE_COLS)
			for i := 0; i < cnt; i += 1 {
				obs := entry.columns[i].max_observed_w
				if obs > i32(slot.col_max_observed[i]) {
					slot.col_max_observed[i] = i16(clamp(obs, 0, 32767))
				}
				entry.columns[i].max_observed_w = i32(slot.col_max_observed[i])
			}
		}
		if s.active_table_id == id_h {
			s.active_table_id = 0
		}
	}
	exit_container_node(ctx)
}

// Appends a styled `Table_Cell` row into the currently open `ui_table` block and observes each
// cell's display width into the column solver's high-water mark.
ui_table_row_cells :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	row_idx: i32,
	cells: []Table_Cell,
	fg: Color = {},
	bg: Color = {},
	style: Style_Flags = {},
) {
	if s == nil || s.active_table_id == 0 {
		return
	}
	entry, ok := &s.table_entries[s.active_table_id]
	if !ok {
		return
	}
	temp_alloc := ctx.allocator if (ctx != nil && ctx.allocator.procedure != nil) else context.temp_allocator
	cells_copy := make([]Table_Cell, len(cells), temp_alloc)
	copy(cells_copy, cells)

	col_cnt := min(len(cells_copy), len(entry.columns))
	for i := 0; i < col_cnt; i += 1 {
		if len(cells_copy[i].text) > 0 {
			table_column_observe_cell(&entry.columns[i], cells_copy[i].text)
		}
	}

	append(&entry.rows, Table_Row_Entry{
		row_idx = row_idx,
		cells   = cells_copy,
		fg      = fg,
		bg      = bg,
		style   = style,
	})
}

// Convenience overload accepting plain `[]string` cell values.
ui_table_row_strings :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	row_idx: i32,
	cells: []string,
	fg: Color = {},
	bg: Color = {},
	style: Style_Flags = {},
) {
	if s == nil || s.active_table_id == 0 {
		return
	}
	temp_alloc := ctx.allocator if (ctx != nil && ctx.allocator.procedure != nil) else context.temp_allocator
	styled := make([]Table_Cell, len(cells), temp_alloc)
	for txt, i in cells {
		styled[i] = Table_Cell{text = txt}
	}
	ui_table_row_cells(ctx, s, row_idx, styled, fg, bg, style)
}

ui_table_row :: proc {
	ui_table_row_cells,
	ui_table_row_strings,
}

// Synchronizes post-input `selected_row`, `selected_col`, `scroll_offset`, `scroll_offset_x`,
// resolved column spans, and focus state from `Input_State` into `s.table_entries` during `apply_input_highlights`.
@(private)
sync_table_highlights :: proc(s: ^Screen, inp: ^Input_State) {
	if s == nil || inp == nil {
		return
	}
	for id_h, &entry in s.table_entries {
		slot := get_scroll_slot(inp, id_h)
		entry.selected_row    = slot.selected_row
		entry.selected_col    = slot.selected_col
		entry.scroll_offset   = slot.offset
		entry.scroll_offset_x = slot.offset_x
		entry.max_offset_x    = slot.max_offset_x
		entry.pinned_area_w   = i32(slot.pinned_area_w)
		entry.start_col       = i32(slot.start_col)
		entry.end_col         = i32(slot.end_col)
		entry.sort_col        = i32(slot.sort_col)
		entry.sort_dir        = slot.sort_dir
		entry.col_x_starts    = slot.col_x_starts
		entry.col_x_widths    = slot.col_x_widths
		entry.col_user_widths = slot.col_user_widths
		entry.col_is_visible  = slot.col_is_visible
		entry.is_focused      = inp.focused_id == id_h
		if slot.auto_size_this_frame {
			cnt := min(len(entry.columns), MAX_TABLE_COLS)
			for i := 0; i < cnt; i += 1 {
				entry.columns[i].max_observed_w = i32(slot.col_max_observed[i])
			}
		}
	}
}

@(private)
format_row_number_buf :: proc "contextless" (buf: []u8, num: i32, width: i32) -> string {
	w := int(clamp(width, 1, i32(len(buf))))
	for i := 0; i < w; i += 1 {
		buf[i] = ' '
	}
	v := max(0, num)
	pos := w - 1
	if v == 0 && pos >= 0 {
		buf[pos] = '0'
		return string(buf[:w])
	}
	for v > 0 && pos >= 0 {
		buf[pos] = u8('0' + (v % 10))
		v /= 10
		pos -= 1
	}
	return string(buf[:w])
}

@(private)
render_table_header_cell :: proc(
	s: ^Screen,
	span: Table_Column_Span,
	y: i32,
	clip: Rect,
	header_text: string,
	sort_dir: Table_Sort_Dir,
	is_sorted_col: bool,
	fg, bg: Color,
	style: Style_Flags,
) {
	if span.width <= 0 {
		return
	}
	if !is_sorted_col || sort_dir == .None || span.width < 2 {
		draw_table_cell(s, span, y, clip, header_text, fg, bg, style)
		return
	}
	arrow: rune = '▲' if sort_dir == .Asc else '▼'
	text_span := Table_Column_Span{
		x     = span.x,
		width = max(0, span.width - 2),
		align = span.align,
	}
	if text_span.width > 0 {
		draw_table_cell(s, text_span, y, clip, header_text, fg, bg, style)
	}
	arrow_x := span.x + span.width - 1
	put_cell_clipped(s, arrow_x, y, Cell{
		ch    = arrow,
		fg    = fg,
		bg    = bg,
		style = style + {.Bold},
		width = 1,
	}, clip)
}

@(private)
draw_table_col_divider :: #force_inline proc(
	s: ^Screen,
	col_x, col_w, col_spacing: i32,
	y: i32,
	c_idx, pinned: int,
	normal_ch, freeze_ch: rune,
	fg, bg: Color,
	full_clip, quadrant_clip: Rect,
) {
	div_x         := table_col_divider_x(col_x, col_w, col_spacing)
	is_freeze_div := pinned > 0 && c_idx == pinned - 1
	div_ch        := freeze_ch if is_freeze_div else normal_ch
	div_clip      := full_clip if is_freeze_div else quadrant_clip
	put_cell_clipped(s, div_x, y, Cell{
		ch    = div_ch,
		fg    = fg,
		bg    = bg,
		width = 1,
	}, div_clip)
}

@(private)
render_table_entry :: proc(
	s: ^Screen,
	node: Layout_Node,
	paint: Paint_Spec,
	entry: Table_Render_Entry,
) {
	inner := node.inner_rect
	clip  := node.inner_clip
	if inner.w <= 0 || inner.h <= 0 || clip.w <= 0 || clip.h <= 0 {
		return
	}

	col_cnt := min(len(entry.columns), MAX_TABLE_COLS)
	if col_cnt <= 0 {
		return
	}

	h_sb_reserved   := i32(1) if (node.config.border == .None && entry.max_offset_x > 0 && inner.h > entry.header_rows + 2) else 0
	data_viewport_h := max(1, inner.h - entry.header_rows - h_sb_reserved)
	avail_inner     := table_avail_inner_rect(inner, node.config.border, entry.total_rows, data_viewport_h)

	// Build temporary `Scroll_Slot` view from `entry` + live `entry.columns` so freshly observed
	// widths from `ui_table_row` calls on this frame are immediately reflected.
	temp_slot := Scroll_Slot{
		pinned_cols     = i16(clamp(entry.pinned_cols, 0, i32(col_cnt - 1))),
		col_spec_count  = u16(col_cnt),
		col_gutter_w    = i8(clamp(entry.gutter_w, 0, 64)),
		col_spacing     = i8(clamp(entry.col_spacing, 0, 32)),
		offset_x        = entry.scroll_offset_x,
		col_user_widths = entry.col_user_widths,
	}
	populate_slot_column_specs(&temp_slot, entry.columns[:col_cnt], entry.sort_col, entry.sort_dir, false)
	resolved_cnt := int(resolve_slot_table_columns(&temp_slot, avail_inner))
	pinned       := int(clamp(i32(temp_slot.pinned_cols), 0, max(0, i32(resolved_cnt) - 1)))
	pinned_w     := i32(temp_slot.pinned_area_w)
	if pinned > 0 && pinned_w >= avail_inner.w - 4 {
		pinned   = 0
		pinned_w = entry.gutter_w
	}

	left_clip  := rect_intersect(clip, Rect{x = avail_inner.x, y = inner.y, w = max(0, pinned_w), h = inner.h})
	right_clip := rect_intersect(clip, Rect{
		x = avail_inner.x + (pinned_w if pinned > 0 else 0),
		y = inner.y,
		w = max(0, avail_inner.w - (pinned_w if pinned > 0 else 0)),
		h = inner.h,
	})

	cfg := entry.cfg
	base_fg := cfg.fg if cfg.fg.kind != .Default else (paint.fg if paint.fg.kind != .Default else rgb(215, 225, 235))
	base_bg := cfg.bg if cfg.bg.kind != .Default else paint.bg
	sep_fg  := cfg.sep_fg if cfg.sep_fg.kind != .Default else (cfg.border_fg if cfg.border_fg.kind != .Default else (paint.border_fg if paint.border_fg.kind != .Default else rgb(75, 95, 125)))
	hdr_fg  := cfg.header_fg if cfg.header_fg.kind != .Default else (cfg.title_fg if cfg.title_fg.kind != .Default else rgb(125, 205, 255))
	hdr_bg  := cfg.header_bg if cfg.header_bg.kind != .Default else base_bg

	sel_fg       := cfg.sel_fg if cfg.sel_fg.kind != .Default else rgb(255, 245, 165)
	sel_bg       := cfg.sel_bg if cfg.sel_bg.kind != .Default else (rgb(42, 62, 92) if entry.is_focused else rgb(34, 46, 68))
	multi_sel_fg := cfg.multi_sel_fg if cfg.multi_sel_fg.kind != .Default else rgb(195, 235, 255)
	multi_sel_bg := cfg.multi_sel_bg if cfg.multi_sel_bg.kind != .Default else rgb(28, 52, 76)
	cell_fg      := cfg.active_cell_fg if cfg.active_cell_fg.kind != .Default else rgb(255, 255, 215)
	cell_bg      := cfg.active_cell_bg if cfg.active_cell_bg.kind != .Default else (rgb(62, 92, 136) if entry.is_focused else sel_bg)

	cur_y := inner.y
	data_end_y := inner.y + inner.h - h_sb_reserved

	// 1. Sticky Header Row
	if !cfg.hide_header && cur_y < data_end_y {
		row_rect := Rect{x = inner.x, y = cur_y, w = inner.w, h = 1}
		if hdr_bg.kind != .Default {
			fill_rect(s, row_rect, clip, ' ', hdr_fg, hdr_bg, {.Bold})
		}
		for c_idx := 0; c_idx < resolved_cnt; c_idx += 1 {
			if c_idx >= pinned && !temp_slot.col_is_visible[c_idx] {
				continue
			}
			c_clip := left_clip if c_idx < pinned else right_clip
			span := Table_Column_Span{
				x     = i32(temp_slot.col_x_starts[c_idx]),
				width = i32(temp_slot.col_x_widths[c_idx]),
				align = temp_slot.col_aligns[c_idx],
			}
			is_sel_col := entry.is_focused && resolved_cnt > 1 && i32(c_idx) == entry.selected_col
			col_hdr_style := Style_Flags{.Bold, .Underline} if is_sel_col else Style_Flags{.Bold}
			render_table_header_cell(
				s,
				span,
				cur_y,
				c_clip,
				entry.columns[c_idx].header,
				entry.sort_dir,
				i32(c_idx) == entry.sort_col,
				hdr_fg,
				hdr_bg,
				col_hdr_style,
			)
			if !cfg.hide_col_sep && c_idx + 1 < resolved_cnt {
				draw_table_col_divider(s, span.x, span.width, entry.col_spacing, cur_y, c_idx, pinned, '│', '║', sep_fg, hdr_bg, clip, c_clip)
			}
		}
		cur_y += 1
	}

	// 2. Sticky Header Horizontal Separator (`───┼───` / `───╫───`) with Border Junction Merging (`├`, `┤`)
	if !cfg.hide_header && !cfg.hide_header_sep && cur_y < data_end_y {
		for sx := inner.x; sx < inner.x + inner.w; sx += 1 {
			put_cell_clipped(s, sx, cur_y, Cell{
				ch    = '─',
				fg    = sep_fg,
				bg    = base_bg,
				width = 1,
			}, clip)
		}
		if !cfg.hide_col_sep {
			for c_idx := 0; c_idx + 1 < resolved_cnt; c_idx += 1 {
				if c_idx >= pinned && !temp_slot.col_is_visible[c_idx] {
					continue
				}
				span_x := i32(temp_slot.col_x_starts[c_idx])
				span_w := i32(temp_slot.col_x_widths[c_idx])
				q_clip := left_clip if c_idx < pinned else right_clip
				draw_table_col_divider(s, span_x, span_w, entry.col_spacing, cur_y, c_idx, pinned, '┼', '╫', sep_fg, base_bg, clip, q_clip)
			}
		}
		if node.config.border != .None && cur_y >= node.node_clip.y && cur_y < node.node_clip.y + node.node_clip.h {
			b_fg := paint.border_fg if paint.border_fg.kind != .Default else sep_fg
			b_spec := DOUBLE_BORDER if node.config.border == .Double else (ROUNDED_BORDER if node.config.border == .Rounded else NORMAL_BORDER)
			if node.rect.x >= node.node_clip.x && node.rect.x < node.node_clip.x + node.node_clip.w {
				put_cell_clipped(s, node.rect.x, cur_y, Cell{
					ch    = b_spec.middle_left,
					fg    = b_fg,
					bg    = paint.bg,
					style = paint.style,
					width = 1,
				}, node.node_clip)
			}
			right_x := node.rect.x + node.rect.w - 1
			if right_x > node.rect.x && right_x >= node.node_clip.x && right_x < node.node_clip.x + node.node_clip.w {
				put_cell_clipped(s, right_x, cur_y, Cell{
					ch    = b_spec.middle_right,
					fg    = b_fg,
					bg    = paint.bg,
					style = paint.style,
					width = 1,
				}, node.node_clip)
			}
		}
		cur_y += 1
	}

	// 3. Visible Data Rows
	data_start_y := cur_y
	base_row_idx := entry.scroll_offset
	for row_pos := 0; row_pos < len(entry.rows); row_pos += 1 {
		row := entry.rows[row_pos]
		rel_y := (row.row_idx - base_row_idx) if row.row_idx >= base_row_idx else i32(row_pos)
		ry := data_start_y + rel_y
		if ry < data_start_y || ry >= data_end_y {
			continue
		}

		is_sel_row   := row.row_idx == entry.selected_row && entry.total_rows > 0
		is_multi_sel := cfg.selection != nil && table_selection_contains(cfg.selection, row.row_idx)

		row_fg := sel_fg if is_sel_row else (multi_sel_fg if is_multi_sel else (row.fg if row.fg.kind != .Default else base_fg))
		row_bg := sel_bg if is_sel_row else (multi_sel_bg if is_multi_sel else (row.bg if row.bg.kind != .Default else base_bg))
		row_style := (row.style + {.Bold}) if is_sel_row else row.style

		row_rect := Rect{x = inner.x, y = ry, w = inner.w, h = 1}
		if is_sel_row || is_multi_sel || row_bg.kind != .Default {
			fill_rect(s, row_rect, clip, ' ', row_fg, row_bg, row_style)
		}

		if entry.gutter_w > 0 {
			if cfg.show_row_numbers && entry.gutter_w >= 4 {
				num_buf: [16]u8
				num_str := format_row_number_buf(num_buf[:], row.row_idx + 1, entry.gutter_w - 1)
				put_text_clipped(s, inner.x, ry, num_str, sel_fg if is_sel_row else sep_fg, row_bg, row_style, clip)
			} else {
				gutter_str := "▸" if is_sel_row else ("•" if is_multi_sel else " ")
				put_text_clipped(s, inner.x, ry, gutter_str, sel_fg if is_sel_row else row_fg, row_bg, row_style, clip)
			}
		}

		for c_idx := 0; c_idx < resolved_cnt; c_idx += 1 {
			if c_idx >= pinned && !temp_slot.col_is_visible[c_idx] {
				continue
			}
			c_clip := left_clip if c_idx < pinned else right_clip
			span := Table_Column_Span{
				x     = i32(temp_slot.col_x_starts[c_idx]),
				width = i32(temp_slot.col_x_widths[c_idx]),
				align = temp_slot.col_aligns[c_idx],
			}
			cell := row.cells[c_idx] if c_idx < len(row.cells) else Table_Cell{}
			is_active_cell := is_sel_row && entry.is_focused && resolved_cnt > 1 && i32(c_idx) == entry.selected_col

			c_fg := cell_fg if is_active_cell else (sel_fg if (is_sel_row && cell.fg.kind == .Default) else (cell.fg if cell.fg.kind != .Default else row_fg))
			c_bg := cell_bg if is_active_cell else (cell.bg if (cell.bg.kind != .Default && !is_sel_row && !is_multi_sel) else row_bg)
			c_style := (row_style + cell.style + ({.Bold, .Underline} if is_active_cell else {}))

			if (is_active_cell || c_bg != row_bg) && span.width > 0 {
				fill_rect(s, Rect{x = span.x, y = ry, w = span.width, h = 1}, c_clip, ' ', c_fg, c_bg, c_style)
			}

			draw_table_cell(
				s,
				span,
				ry,
				c_clip,
				cell.text,
				c_fg,
				c_bg,
				c_style,
			)

			if !cfg.hide_col_sep && c_idx + 1 < resolved_cnt {
				draw_table_col_divider(s, span.x, span.width, entry.col_spacing, ry, c_idx, pinned, '│', '║', sep_fg, row_bg, clip, c_clip)
			}
		}
	}
}
