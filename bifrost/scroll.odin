package bifrost

import "core:fmt"

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
	total_cols:     i32, // Optional 2D virtual table column count (> 1 enables h/l column stepping)
	focusable:      bool,
	focus_flags:    Focus_Flags,
}

Virtual_Slice :: struct {
	start_row:       i32, // Inclusive start index into xitdb ArrayList / Filtered View
	end_row:         i32, // Exclusive end index into xitdb ArrayList / Filtered View
	selected_row:    i32, // Currently highlighted row index
	selected_col:    i32, // Currently highlighted column index (0 when total_cols <= 1)
	scroll_offset:   i32, // Clamped top visible row index
	scroll_offset_x: i32, // Clamped horizontal cell scroll offset for scrollable columns
	viewport_rows:   i32, // Number of visible rows in the container
	total_rows:      i32, // Total logical rows in dataset
	total_cols:      i32, // Total logical columns in dataset (max(1, cfg.total_cols))
	pinned_cols:     i32, // Number of left-frozen columns (0 ..< pinned_cols stay anchored)
	start_col:       i32, // Inclusive first visible scrollable column index (>= pinned_cols)
	end_col:         i32, // Exclusive one-past-last visible scrollable column index
	sort_col:        i32, // Active sorted column index (-1 when unsorted)
	sort_dir:        Table_Sort_Dir,
	sort_changed:    bool,
	follow_tail:     bool,
}

// Returns true if `col_idx` is either a pinned left column (`< slice.pinned_cols`)
// or intersects the horizontally visible scrollable column window `[slice.start_col, slice.end_col)`.
// Callers with wide tables (e.g. 190-column CSVs) can use this to skip formatting off-screen cells.
ui_table_is_col_visible :: #force_inline proc "contextless" (slice: Virtual_Slice, col_idx: int) -> bool {
	c := i32(col_idx)
	if c < 0 || c >= slice.total_cols {
		return false
	}
	if c < slice.pinned_cols {
		return true
	}
	if slice.end_col <= slice.start_col {
		return true
	}
	return c >= slice.start_col && c < slice.end_col
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
	slot.header_rows    = 0
	slot.col_spec_count = 0
	slot.total_rows     = max(0, total_rows)
	slot.total_cols     = max(1, cfg.total_cols)
	slot.max_offset     = max(0, slot.total_rows - slot.viewport_rows)
	slot.offset         = clamp(slot.offset, 0, slot.max_offset)
	slot.selected_row   = clamp(slot.selected_row, 0, max(0, slot.total_rows - 1))
	slot.selected_col   = clamp(slot.selected_col, 0, max(0, slot.total_cols - 1))
	slot.scroll_padding = max(0, cfg.scroll_padding)

	start_r := slot.offset
	end_r   := min(slot.total_rows, start_r + slot.viewport_rows)

	if out_slice != nil {
		out_slice^ = Virtual_Slice{
			start_row     = start_r,
			end_row       = end_r,
			selected_row  = slot.selected_row,
			selected_col  = slot.selected_col,
			scroll_offset = slot.offset,
			viewport_rows = slot.viewport_rows,
			total_rows    = slot.total_rows,
			total_cols    = slot.total_cols,
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
		focus_flags        = cfg.focus_flags,
		focusable          = .Disabled not_in cfg.focus_flags,
	}, {0, 0})
	enter_container_node(ctx, idx)
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
	exit_container_node(ctx)
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

DEFAULT_MAX_AUTO_COL_W :: 64

// Records the display width of a cell in a virtualized table column in `O(max_width)` time.
// Monotonic high-water-mark clamping ensures scrolling through variable-length rows never jitters left,
// while bounded measurement prevents multi-KB biography strings from scanning past `max_width`.
table_column_observe_cell :: proc "contextless" (spec: ^Table_Column_Spec, cell_text: string) {
	cap_w := spec.max_width if spec.max_width > 0 else DEFAULT_MAX_AUTO_COL_W
	w, _ := string_display_width_bounded(cell_text, cap_w)
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
			w = min_w
		}

		out_spans[i] = Table_Column_Span{
			width = w,
			align = spec.align,
		}
	}

	// Pass 2: Distribute remaining space across Fill columns
	min_fill_w: i32 = 0
	for i := 0; i < count; i += 1 {
		if specs[i].kind == .Fill {
			min_fill_w += max(1, specs[i].min_width)
		}
	}

	// If Fixed + Auto_Content columns leave less than `min_fill_w` for Fill columns,
	// proportionally compress Fixed/Auto_Content columns down toward their `min_width`
	// so every column remains visible before horizontal clipping occurs.
	if total_weight > 0 && used_w + min_fill_w > avail_w {
		deficit := (used_w + min_fill_w) - avail_w
		for pass := 0; pass < 4 && deficit > 0; pass += 1 {
			shrinkable := 0
			for i := 0; i < count; i += 1 {
				if specs[i].kind != .Fill {
					min_c := max(1, min(specs[i].min_width, out_spans[i].width))
					if out_spans[i].width > min_c {
						shrinkable += 1
					}
				}
			}
			if shrinkable == 0 {
				break
			}
			step := max(1, deficit / i32(shrinkable))
			for i := 0; i < count && deficit > 0; i += 1 {
				if specs[i].kind != .Fill {
					min_c := max(1, min(specs[i].min_width, out_spans[i].width))
					avail_cut := out_spans[i].width - min_c
					if avail_cut > 0 {
						cut := min(avail_cut, min(step, deficit))
						out_spans[i].width -= cut
						used_w             -= cut
						deficit            -= cut
					}
				}
			}
		}
	}

	rem_w := max(0, avail_w - used_w)
	if total_weight > 0 && rem_w > 0 {
		rem_budget := rem_w
		rem_weight := total_weight
		last_fill_idx := -1
		for i := 0; i < count; i += 1 {
			if specs[i].kind != .Fill {
				continue
			}
			last_fill_idx = i
			raw_weight := specs[i].value if specs[i].value > 0 else specs[i].fill_weight
			weight := max(1, raw_weight)
			share := i32((i64(rem_budget) * i64(weight)) / i64(max(1, rem_weight))) if rem_budget > 0 else 0
			min_w := max(1, specs[i].min_width)
			max_w := specs[i].max_width if specs[i].max_width > 0 else avail_w
			w := clamp(share, min_w, max(min_w, max_w))
			out_spans[i].width = w
			rem_budget = max(0, rem_budget - w)
			rem_weight = max(0, rem_weight - weight)
		}
		if rem_budget > 0 && last_fill_idx >= 0 {
			max_w := specs[last_fill_idx].max_width if specs[last_fill_idx].max_width > 0 else avail_w
			out_spans[last_fill_idx].width = min(out_spans[last_fill_idx].width + rem_budget, max(out_spans[last_fill_idx].width, max_w))
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

// Draws aligned, single-line sanitized cell text inside a resolved table column span at row `y`.
// Bounded to `O(span.width)` work: control characters (`\n`, `\r`, `\t`) render as spaces,
// and strings exceeding `span.width` terminate immediately with a `…` (`U+2026`) ellipsis.
draw_table_cell :: proc(
	s: ^Screen,
	span: Table_Column_Span,
	y: i32,
	clip: Rect,
	text: string,
	fg, bg: Color,
	style: Style_Flags = {},
	truncate_ellipsis: bool = true,
) {
	if span.width <= 0 || len(text) == 0 {
		return
	}
	cell_rect := Rect{x = span.x, y = y, w = span.width, h = 1}
	cell_clip := rect_intersect(clip, cell_rect)
	if cell_clip.w <= 0 || cell_clip.h <= 0 {
		return
	}

	text_w, is_trunc := string_display_width_bounded(text, span.width)
	if !is_trunc {
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
		put_sanitized_text_bounded(s, span.x + offset_x, y, text, span.width, fg, bg, style, cell_clip)
		return
	}

	if !truncate_ellipsis || span.width <= 1 {
		put_sanitized_text_bounded(s, span.x, y, text, span.width, fg, bg, style, cell_clip)
		return
	}

	avail_for_prefix := span.width - 1
	drawn_w := put_sanitized_text_bounded(s, span.x, y, text, avail_for_prefix, fg, bg, style, cell_clip)
	ell_x := span.x + drawn_w
	eff_bg := bg
	if eff_bg.kind == .Default && ell_x >= 0 && ell_x < s.width && y >= 0 && y < s.height {
		eff_bg = s.back[int(y * s.width + ell_x)].bg
	}
	put_cell_clipped(s, ell_x, y, Cell{
		ch    = '…',
		fg    = fg,
		bg    = eff_bg,
		style = style,
		width = 1,
	}, cell_clip)
}

@(private)
put_sanitized_text_bounded :: proc(
	s: ^Screen,
	x, y: i32,
	text: string,
	max_cols: i32,
	fg, bg: Color,
	style: Style_Flags,
	clip: Rect,
) -> i32 {
	if max_cols <= 0 {
		return 0
	}
	cur_x := x
	used_w: i32 = 0
	idx := 0
	for idx < len(text) && used_w < max_cols {
		b := text[idx]
		if b < 0x20 || b == 0x7f {
			if b == '\r' && idx + 1 < len(text) && text[idx + 1] == '\n' {
				idx += 2
			} else {
				idx += 1
			}
			eff_bg := bg
			if eff_bg.kind == .Default && cur_x >= 0 && cur_x < s.width && y >= 0 && y < s.height {
				eff_bg = s.back[int(y * s.width + cur_x)].bg
			}
			put_cell_clipped(s, cur_x, y, Cell{
				ch    = ' ',
				fg    = fg,
				bg    = eff_bg,
				style = style,
				width = 1,
			}, clip)
			cur_x  += 1
			used_w += 1
			continue
		}
		next_idx, cluster_w, lead_r := next_grapheme_cluster(text, idx)
		idx = next_idx
		if cluster_w <= 0 {
			continue
		}
		w := i32(clamp(cluster_w, 1, 2))
		if used_w + w > max_cols {
			break
		}
		eff_bg := bg
		if eff_bg.kind == .Default && cur_x >= 0 && cur_x < s.width && y >= 0 && y < s.height {
			eff_bg = s.back[int(y * s.width + cur_x)].bg
		}
		if w == 2 {
			// Ensure both columns of a 2-cell wide glyph lie inside `clip`; otherwise paint a space on the visible half
			if cur_x < clip.x || cur_x + 1 >= clip.x + clip.w {
				put_cell_clipped(s, cur_x, y, Cell{ch = ' ', fg = fg, bg = eff_bg, style = style, width = 1}, clip)
				put_cell_clipped(s, cur_x + 1, y, Cell{ch = ' ', fg = fg, bg = eff_bg, style = style, width = 1}, clip)
			} else {
				put_cell_clipped(s, cur_x, y, Cell{
					ch    = lead_r,
					fg    = fg,
					bg    = eff_bg,
					style = style,
					width = 2,
				}, clip)
				put_cell_clipped(s, cur_x + 1, y, Cell{
					ch    = 0,
					fg    = fg,
					bg    = eff_bg,
					style = style,
					width = 0,
				}, clip)
			}
		} else {
			put_cell_clipped(s, cur_x, y, Cell{
				ch    = lead_r,
				fg    = fg,
				bg    = eff_bg,
				style = style,
				width = 1,
			}, clip)
		}
		cur_x  += w
		used_w += w
	}
	return used_w
}

// =============================================================================
// Track 20: Interactive Table Column Controls (Sorting & Divider Resizing)
// =============================================================================

Table_Sort_Direction :: enum u8 {
	None = 0,
	Asc  = 1,
	Desc = 2,
}

Table_Sort_State :: struct {
	column:    int,
	direction: Table_Sort_Direction,
}

Table_Header_Config :: struct {
	gutter_width:   i32,
	column_spacing: i32,
	fg:             Color,
	bg:             Color,
	active_fg:      Color,
	border_fg:      Color,
	allow_sort:     bool,
	allow_resize:   bool,
}

ui_table_header :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	specs: []Table_Column_Spec,
	sort_state: ^Table_Sort_State = nil,
	cfg: Table_Header_Config = {},
) -> (sort_changed: bool) {
	hdr_fg := cfg.fg if cfg.fg.kind != .Default else rgb(200, 210, 225)
	hdr_bg := cfg.bg if cfg.bg.kind != .Default else rgb(30, 38, 52)
	act_fg := cfg.active_fg if cfg.active_fg.kind != .Default else rgb(250, 200, 80)
	b_fg   := cfg.border_fg if cfg.border_fg.kind != .Default else rgb(70, 85, 110)

	if s != nil {
		s.paints[hash_id(id)] = Paint_Spec{
			bg      = hdr_bg,
			fill_bg = true,
		}
	}

	if container(ctx, id, Box_Config{
		dir    = .Row,
		width  = grow(1),
		height = fixed(1),
	}) {
		// Gutter spacing on left if any
		if cfg.gutter_width > 0 {
			leaf(ctx, fmt.tprintf("%s_gutter", id), cfg.gutter_width, 1, Box_Config{
				width  = fixed(cfg.gutter_width),
				height = fixed(1),
			})
		}

		for i in 0 ..< len(specs) {
			spec := &specs[i]
			col_id := fmt.tprintf("%s_col_%d", id, i)
			div_id := fmt.tprintf("%s_div_%d", id, i)

			// Resizable column width sync
			base_fixed_w := spec.fixed_width if spec.fixed_width > 0 else (spec.value if spec.value > 0 else 12)
			min_w := spec.min_width if spec.min_width > 0 else 4
			max_w := spec.max_width if spec.max_width > 0 else 120
			if cfg.allow_resize && spec.kind == .Fixed {
				resolved_w := get_split_size(inp, div_id, base_fixed_w, min_w, max_w)
				spec.fixed_width = resolved_w
				if spec.value > 0 {
					spec.value = resolved_w
				}
			}

			// Check sort activation before label construction so new sort indicator appears in the same frame
			if cfg.allow_sort && was_activated(inp, col_id) && sort_state != nil {
				if sort_state.column != i {
					sort_state.column = i
					sort_state.direction = .Asc
				} else {
					switch sort_state.direction {
					case .None: sort_state.direction = .Asc
					case .Asc:  sort_state.direction = .Desc
					case .Desc: sort_state.direction = .None
					}
				}
				sort_changed = true
			}

			is_sorted := sort_state != nil && sort_state.column == i && sort_state.direction != .None
			col_fg := act_fg if is_sorted else hdr_fg

			header_label := spec.header
			if is_sorted {
				arrow := " ▲" if sort_state.direction == .Asc else " ▼"
				header_label = fmt.tprintf("%s%s", spec.header, arrow)
			}

			w_size: Axis_Size
			switch spec.kind {
			case .Fixed:
				w_size = fixed(spec.fixed_width if spec.fixed_width > 0 else base_fixed_w)
			case .Fill:
				fw := spec.fill_weight if spec.fill_weight > 0 else (spec.value if spec.value > 0 else 1)
				w_size = grow(fw)
			case .Auto_Content:
				auto_w := max(string_display_width(header_label), spec.max_observed_w)
				if spec.min_width > 0 {
					auto_w = max(auto_w, spec.min_width)
				}
				if spec.max_width > 0 {
					auto_w = min(auto_w, spec.max_width)
				}
				w_size = fixed(auto_w)
			}

			if cfg.allow_sort {
				ui_button(ctx, s, col_id, Button_Spec{
					label       = header_label,
					width       = w_size,
					height      = fixed(1),
					fg          = col_fg,
					bg          = hdr_bg,
					focus_flags = {.Focusable},
				})
			} else {
				ui_label(ctx, s, col_id, header_label, col_fg, {.Bold}, Box_Config{
					width  = w_size,
					height = fixed(1),
				})
			}

			// Divider between columns
			if i + 1 < len(specs) {
				if cfg.allow_resize && spec.kind == .Fixed {
					ui_splitter(ctx, s, inp, div_id, Splitter_Config{
						dir          = .Row,
						default_size = base_fixed_w,
						min_size     = min_w,
						max_size     = max_w,
						fg           = b_fg,
						active_fg    = act_fg,
					})
					if cfg.column_spacing > 1 {
						leaf(ctx, fmt.tprintf("%s_pad", div_id), cfg.column_spacing - 1, 1, Box_Config{
							width  = fixed(cfg.column_spacing - 1),
							height = fixed(1),
							text   = " ",
						})
					}
				} else if cfg.column_spacing > 0 {
					leaf(ctx, div_id, cfg.column_spacing, 1, Box_Config{
						width  = fixed(cfg.column_spacing),
						height = fixed(1),
						text   = " ",
					})
				}
			}
		}
	}

	return sort_changed
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
	case '┬', '┳', '╦', '╥': return {.East, .West, .South}
	case '┴', '┻', '╩', '╨': return {.East, .West, .North}
	case '┼', '╋', '╬', '╫': return {.North, .East, .South, .West}
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

MAX_TABLE_COLS :: 256

Table_Cell_Span :: struct {
	x: i32,
	w: i32,
}

Scroll_Slot :: struct {
	id_hash:                u64,
	offset:                 i32, // Top visible row index (or cell offset)
	max_offset:             i32, // Clamped maximum scroll offset
	offset_x:               i32, // Left visible column cell offset
	max_offset_x:           i32, // Clamped maximum horizontal scroll offset
	viewport_rows:          i32, // Solved inner_rect.h from previous/current layout pass
	viewport_cols:          i32, // Solved inner_rect.w from previous/current layout pass
	total_rows:             i32, // Total rows in xitdb collection or physical content_span
	prev_total_rows:        i32, // Previous frame total_rows (for follow_tail detection)
	total_content_w:        i32, // Total horizontal content width (`content_span[0]`)
	selected_row:           i32, // Highlighted cursor row index inside virtual lists
	selected_col:           i32, // Highlighted cursor column index inside 2D virtual tables
	total_cols:             i32, // Logical column count (> 1 enables h/l column stepping)
	pinned_cols:            i16, // Number of frozen left columns (`0 ..< pinned_cols`)
	start_col:              i16, // First visible scrollable column index
	end_col:                i16, // One-past-last visible scrollable column index
	sort_col:               i16, // Active sort column index (-1 when unsorted)
	sort_dir:               Table_Sort_Dir,
	sort_changed:           bool,
	sortable:               bool,
	resizable:              bool,
	follow_tail:            bool,
	follow_tail_initialized: bool,
	auto_size_this_frame:   bool,
	dragging_col_idx:       i16, // >= 0 when dragging a column divider
	drag_col_start_x:       i16,
	drag_col_start_w:       i16,
	dragging_v_scrollbar:   bool,
	dragging_h_scrollbar:   bool,
	scroll_padding:         i32, // Lookahead padding rows maintained above/below selected_row
	header_rows:            u8,  // Sticky header rows (0 for lists, 1..2 for `ui_table`)
	col_spec_count:         u16, // Declarative column count registered by `ui_table` (0..256)
	col_gutter_w:           i8,  // Left selection gutter width registered by `ui_table`
	col_spacing:            i8,  // Inter-column spacing registered by `ui_table`
	col_kinds:              [MAX_TABLE_COLS]Column_Width_Kind,
	col_aligns:             [MAX_TABLE_COLS]Column_Align,
	col_req_widths:         [MAX_TABLE_COLS]i16, // Fixed width or Fill weight
	col_min_widths:         [MAX_TABLE_COLS]i16,
	col_max_widths:         [MAX_TABLE_COLS]i16,
	col_header_widths:      [MAX_TABLE_COLS]i16,
	col_max_observed:       [MAX_TABLE_COLS]i16, // Monotonic high-water-mark widths per column
	col_user_widths:        [MAX_TABLE_COLS]i16, // > 0 when user manually resized this column
	col_x_starts:           [MAX_TABLE_COLS]i16, // Screen x start (for visible columns) or logical x
	col_x_widths:           [MAX_TABLE_COLS]i16, // Cell width of each column
	col_is_visible:         [MAX_TABLE_COLS]bool,
	col_span_count:         u16,                 // Number of registered table column spans
	col_spans_screen_space: bool,                // True when col_x_starts are in screen-space coordinates
	pinned_area_w:          i16,                 // Width occupied by gutter + pinned columns + freeze divider
	last_layout_gen:        u64,                 // Last Layout_Context generation where this slot was mounted
}


// =============================================================================
// Scroll Slot Management & Z-Aware Scroll Bubbling
// =============================================================================

get_scroll_slot :: proc "contextless" (inp: ^Input_State, id_hash: u64) -> ^Scroll_Slot {
	empty_idx := -1
	lru_idx   := 0
	lru_gen   := max(u64)
	for i := 0; i < MAX_SCROLL_SLOTS; i += 1 {
		if inp.scroll_slots[i].id_hash == id_hash {
			return &inp.scroll_slots[i]
		}
		if empty_idx == -1 && inp.scroll_slots[i].id_hash == 0 {
			empty_idx = i
		}
		if inp.scroll_slots[i].last_layout_gen < lru_gen {
			lru_gen = inp.scroll_slots[i].last_layout_gen
			lru_idx = i
		}
	}
	idx := empty_idx if empty_idx >= 0 else lru_idx
	inp.scroll_slots[idx] = Scroll_Slot{
		id_hash       = id_hash,
		viewport_rows = 0,
	}
	return &inp.scroll_slots[idx]
}

get_scroll_offset :: proc(inp: ^Input_State, id: string) -> i32 {
	slot := get_scroll_slot(inp, hash_id(id))
	return slot.offset
}

get_scroll_offset_x :: proc(inp: ^Input_State, id: string) -> i32 {
	slot := get_scroll_slot(inp, hash_id(id))
	return slot.offset_x
}

get_selected_row :: proc(inp: ^Input_State, id: string) -> i32 {
	slot := get_scroll_slot(inp, hash_id(id))
	return slot.selected_row
}

get_selected_col :: proc(inp: ^Input_State, id: string) -> i32 {
	slot := get_scroll_slot(inp, hash_id(id))
	return slot.selected_col
}

// Registers horizontal column cell spans (relative to the virtual list's `inner_rect.x`)
// so mouse clicks inside `ui_virtual_list` automatically update `slot.selected_col`.
register_virtual_table_col_spans_cells :: proc(inp: ^Input_State, list_id: string, spans: []Table_Cell_Span) {
	slot := get_scroll_slot(inp, hash_id(list_id))
	cnt := min(len(spans), MAX_TABLE_COLS)
	slot.col_span_count = u16(cnt)
	slot.col_spans_screen_space = false
	if cnt > 0 && slot.total_cols < i32(cnt) {
		slot.total_cols = i32(cnt)
	}
	for i := 0; i < cnt; i += 1 {
		slot.col_x_starts[i]   = i16(clamp(spans[i].x, 0, 32767))
		slot.col_x_widths[i]   = i16(clamp(spans[i].w, 1, 32767))
		slot.col_is_visible[i] = true
	}
}

register_virtual_table_col_spans_columns :: proc(inp: ^Input_State, list_id: string, spans: []Table_Column_Span) {
	slot := get_scroll_slot(inp, hash_id(list_id))
	cnt := min(len(spans), MAX_TABLE_COLS)
	slot.col_span_count = u16(cnt)
	slot.col_spans_screen_space = true
	if cnt > 0 && slot.total_cols < i32(cnt) {
		slot.total_cols = i32(cnt)
	}
	for i := 0; i < cnt; i += 1 {
		slot.col_x_starts[i]   = i16(clamp(spans[i].x, 0, 32767))
		slot.col_x_widths[i]   = i16(clamp(spans[i].width, 1, 32767))
		slot.col_is_visible[i] = true
	}
}

register_virtual_table_col_spans :: proc {
	register_virtual_table_col_spans_cells,
	register_virtual_table_col_spans_columns,
}

// Returns the available inner rect for table columns, reserving 1 column on the right for
// a vertical scrollbar when the table is borderless (`border == .None`).
table_avail_inner_rect :: #force_inline proc "contextless" (
	inner: Rect,
	border: Border_Kind,
	total_rows: i32,
	viewport_rows: i32,
) -> Rect {
	avail := inner
	if total_rows > max(1, viewport_rows) && border == .None && avail.w > 2 {
		avail.w -= 1
	}
	return avail
}

// Computes the screen-space x-coordinate of the vertical divider (`│` or `║`) following a column.
table_col_divider_x :: #force_inline proc "contextless" (col_x, col_w, col_spacing: i32) -> i32 {
	return col_x + col_w + (max(0, col_spacing) / 2)
}

// Unpacks `columns` into `slot` arrays for `resolve_slot_table_columns`.
populate_slot_column_specs :: proc "contextless" (
	slot: ^Scroll_Slot,
	columns: []Table_Column_Spec,
	sort_col: i32,
	sort_dir: Table_Sort_Dir,
	reset_auto_size: bool = false,
) {
	col_cnt := min(len(columns), MAX_TABLE_COLS)
	slot.col_spec_count = u16(col_cnt)
	for i := 0; i < col_cnt; i += 1 {
		spec := columns[i]
		hdr_w := string_display_width(spec.header)
		if sort_dir != .None && i32(i) == sort_col {
			hdr_w += 2
		}
		seed_obs := i32(0) if reset_auto_size else spec.max_observed_w
		obs_w := max(hdr_w, max(seed_obs, i32(slot.col_max_observed[i])))
		req_val := spec.value if spec.value > 0 else (spec.fixed_width if spec.kind == .Fixed else spec.fill_weight)
		slot.col_kinds[i]         = spec.kind
		slot.col_aligns[i]        = spec.align
		slot.col_req_widths[i]    = i16(clamp(req_val, 0, 32767))
		slot.col_min_widths[i]    = i16(clamp(max(1, spec.min_width), 1, 32767))
		slot.col_max_widths[i]    = i16(clamp(spec.max_width, 0, 32767))
		slot.col_header_widths[i] = i16(clamp(hdr_w, 1, 32767))
		slot.col_max_observed[i]  = i16(clamp(obs_w, 0, 32767))
	}
}

// Solves 2D table column widths and screen-space coordinates for `Scroll_Slot`,
// supporting up to 256 columns, frozen left columns (`0 ..< pinned_cols`),
// user manual width overrides (`col_user_widths`), and horizontal scroll offset (`offset_x`).
resolve_slot_table_columns :: proc "contextless" (slot: ^Scroll_Slot, avail_rect: Rect) -> i32 {
	cnt := int(min(slot.col_spec_count, MAX_TABLE_COLS))
	if cnt <= 0 || avail_rect.w <= 0 {
		slot.col_span_count = 0
		slot.start_col      = 0
		slot.end_col        = 0
		slot.pinned_area_w  = 0
		return 0
	}

	gutter := max(0, i32(slot.col_gutter_w))
	col_sp := max(0, i32(slot.col_spacing))
	total_gaps := i32(max(0, cnt - 1)) * col_sp
	avail_w := max(0, avail_rect.w - gutter - total_gaps)

	used_w: i32 = 0
	total_weight: i32 = 0

	// Pass 1: Resolve Fixed, Auto_Content, and user-resized columns
	for i := 0; i < cnt; i += 1 {
		min_w := max(1, i32(slot.col_min_widths[i]))
		max_w := i32(slot.col_max_widths[i]) if slot.col_max_widths[i] > 0 else max(min_w, avail_rect.w)
		obs_w := max(i32(slot.col_header_widths[i]), i32(slot.col_max_observed[i]))

		w: i32 = 0
		if slot.col_user_widths[i] > 0 {
			w = max(min_w, i32(slot.col_user_widths[i]))
			used_w += w
		} else {
			switch slot.col_kinds[i] {
			case .Fixed:
				fw := max(1, i32(slot.col_req_widths[i]))
				w = clamp(fw, min_w, max(min_w, max_w))
				used_w += w
			case .Auto_Content:
				w = clamp(obs_w, min_w, max(min_w, max_w))
				used_w += w
			case .Fill:
				weight := max(1, i32(slot.col_req_widths[i]))
				total_weight += weight
				w = max(min_w, i32(slot.col_header_widths[i]))
			}
		}
		slot.col_x_widths[i] = i16(clamp(w, 1, 32767))
	}

	// Pass 2: Distribute remaining viewport width across non-resized Fill columns when content fits
	rem_w := max(0, avail_w - used_w)
	if total_weight > 0 && rem_w > 0 {
		rem_budget := rem_w
		rem_weight := total_weight
		last_fill_idx := -1
		for i := 0; i < cnt; i += 1 {
			if slot.col_user_widths[i] > 0 || slot.col_kinds[i] != .Fill {
				continue
			}
			last_fill_idx = i
			weight := max(1, i32(slot.col_req_widths[i]))
			share := i32((i64(rem_budget) * i64(weight)) / i64(max(1, rem_weight))) if rem_budget > 0 else 0
			min_w := max(1, max(i32(slot.col_min_widths[i]), i32(slot.col_header_widths[i])))
			max_w := i32(slot.col_max_widths[i]) if slot.col_max_widths[i] > 0 else max(min_w, avail_rect.w)
			w := clamp(share, min_w, max(min_w, max_w))
			slot.col_x_widths[i] = i16(clamp(w, 1, 32767))
			rem_budget = max(0, rem_budget - w)
			rem_weight = max(0, rem_weight - weight)
		}
		if rem_budget > 0 && last_fill_idx >= 0 {
			cur_w := i32(slot.col_x_widths[last_fill_idx])
			max_w := i32(slot.col_max_widths[last_fill_idx]) if slot.col_max_widths[last_fill_idx] > 0 else max(cur_w + rem_budget, avail_rect.w)
			slot.col_x_widths[last_fill_idx] = i16(clamp(min(cur_w + rem_budget, max(cur_w, max_w)), 1, 32767))
		}
	}

	// Pass 3: Partition into Pinned Left Quadrant (`0 ..< pinned`) and Scrollable Right Quadrant (`pinned ..< cnt`)
	pinned := int(clamp(i32(slot.pinned_cols), 0, max(0, i32(cnt) - 1)))
	cur_x := avail_rect.x + gutter
	for i := 0; i < pinned; i += 1 {
		slot.col_x_starts[i]   = i16(clamp(cur_x, -32768, 32767))
		slot.col_is_visible[i] = cur_x < avail_rect.x + avail_rect.w
		cur_x += i32(slot.col_x_widths[i])
		if i + 1 < cnt {
			cur_x += col_sp
		}
	}

	pinned_area_w := cur_x - avail_rect.x
	// Guard against pinned columns consuming 100% of a tiny viewport
	if pinned > 0 && pinned_area_w >= avail_rect.w - 4 {
		pinned = 0
		pinned_area_w = gutter
		cur_x = avail_rect.x + gutter
	}
	slot.pinned_area_w = i16(clamp(pinned_area_w, 0, 32767))

	scroll_vp_x := avail_rect.x + pinned_area_w
	scroll_vp_w := max(1, avail_rect.w - pinned_area_w)

	scrollable_total_w: i32 = 0
	for i := pinned; i < cnt; i += 1 {
		scrollable_total_w += i32(slot.col_x_widths[i])
		if i + 1 < cnt {
			scrollable_total_w += col_sp
		}
	}

	slot.total_content_w = pinned_area_w + scrollable_total_w
	slot.viewport_cols   = avail_rect.w
	slot.max_offset_x    = max(0, scrollable_total_w - scroll_vp_w)
	slot.offset_x        = clamp(slot.offset_x, 0, slot.max_offset_x)

	// Pass 4: Compute screen-space x starts and visible `[start_col, end_col)` window for scrollable columns
	first_vis := cnt
	last_vis  := pinned
	rel_x: i32 = 0
	for i := pinned; i < cnt; i += 1 {
		cw := i32(slot.col_x_widths[i])
		screen_x := scroll_vp_x + rel_x - slot.offset_x
		slot.col_x_starts[i] = i16(clamp(screen_x, -32768, 32767))
		vis := (screen_x + cw + col_sp > scroll_vp_x) && (screen_x < scroll_vp_x + scroll_vp_w)
		slot.col_is_visible[i] = vis
		if vis {
			if i < first_vis {
				first_vis = i
			}
			if i + 1 > last_vis {
				last_vis = i + 1
			}
		}
		rel_x += cw
		if i + 1 < cnt {
			rel_x += col_sp
		}
	}

	if first_vis > last_vis {
		first_vis = pinned
		last_vis  = pinned
	}
	slot.start_col              = i16(first_vis)
	slot.end_col                = i16(last_vis)
	slot.col_span_count         = u16(cnt)
	slot.col_spans_screen_space = true
	return i32(cnt)
}

// Ensures that when `slot.selected_col` is in the scrollable column range (`>= pinned_cols`),
// `slot.offset_x` automatically scrolls horizontally so `selected_col` is fully visible inside the right viewport.
ensure_virtual_col_visible :: proc "contextless" (slot: ^Scroll_Slot, avail_w: i32 = 0) {
	cnt := int(min(slot.col_spec_count, MAX_TABLE_COLS))
	if cnt <= 1 {
		return
	}
	sel := int(clamp(slot.selected_col, 0, i32(cnt - 1)))
	pinned := int(clamp(i32(slot.pinned_cols), 0, max(0, i32(cnt) - 1)))
	if sel < pinned {
		return
	}

	vp_total_w := avail_w if avail_w > 0 else slot.viewport_cols
	if vp_total_w <= 0 {
		return
	}
	pinned_w := i32(slot.pinned_area_w)
	if pinned == 0 && pinned_w == 0 {
		pinned_w = max(0, i32(slot.col_gutter_w))
	}
	scroll_vp_w := max(1, vp_total_w - pinned_w)
	col_sp := max(0, i32(slot.col_spacing))

	target_rel_x: i32 = 0
	target_w: i32     = max(1, i32(slot.col_x_widths[sel]))
	scrollable_total_w: i32 = 0
	for i := pinned; i < cnt; i += 1 {
		cw := max(1, i32(slot.col_x_widths[i]))
		if i == sel {
			target_rel_x = scrollable_total_w
			target_w     = cw
		}
		scrollable_total_w += cw
		if i + 1 < cnt {
			scrollable_total_w += col_sp
		}
	}

	slot.max_offset_x = max(0, scrollable_total_w - scroll_vp_w)
	if target_rel_x < slot.offset_x {
		slot.offset_x = target_rel_x
	} else if target_rel_x + target_w > slot.offset_x + scroll_vp_w {
		slot.offset_x = target_rel_x + target_w - scroll_vp_w
	}
	slot.offset_x = clamp(slot.offset_x, 0, slot.max_offset_x)
}

select_virtual_col_at_x :: proc "contextless" (slot: ^Scroll_Slot, inner_rect: Rect, mx: i32) {
	cols := max(1, slot.total_cols)
	if cols <= 1 || inner_rect.w <= 0 {
		return
	}
	if slot.col_spec_count > 0 && slot.col_spans_screen_space {
		cnt := int(min(slot.col_span_count, MAX_TABLE_COLS))
		pinned := int(clamp(i32(slot.pinned_cols), 0, max(0, i32(cnt) - 1)))
		pinned_right := inner_rect.x + i32(slot.pinned_area_w)
		if pinned > 0 && mx < pinned_right {
			for i := 0; i < pinned; i += 1 {
				cx := i32(slot.col_x_starts[i])
				cw := i32(slot.col_x_widths[i])
				if mx >= cx && mx < cx + cw {
					slot.selected_col = i32(i)
					return
				}
			}
			return
		}
		if pinned == 0 && mx < inner_rect.x + max(0, i32(slot.col_gutter_w)) {
			return
		}
		for i := pinned; i < cnt; i += 1 {
			if !slot.col_is_visible[i] {
				continue
			}
			cx := i32(slot.col_x_starts[i])
			cw := i32(slot.col_x_widths[i])
			if mx >= cx && mx < cx + cw {
				slot.selected_col = i32(i)
				ensure_virtual_col_visible(slot, inner_rect.w)
				return
			}
		}
		return
	}
	rel_x := mx - inner_rect.x + slot.offset_x
	if slot.col_span_count > 0 {
		probe_x := (mx + slot.offset_x) if slot.col_spans_screen_space else rel_x
		for i := 0; i < int(slot.col_span_count); i += 1 {
			cx := i32(slot.col_x_starts[i])
			cw := i32(slot.col_x_widths[i])
			if probe_x >= cx && probe_x < cx + cw {
				slot.selected_col = clamp(i32(i), 0, cols - 1)
				return
			}
		}
	}
	// Uniform fallback when explicit spans are not registered
	col_w := max(1, inner_rect.w / cols)
	slot.selected_col = clamp(rel_x / col_w, 0, cols - 1)
}


// =============================================================================
// Same-Frame `scroll_node_into_view` & Unified Sibling / Viewport Paging
// =============================================================================

compute_axis_scroll_delta :: proc "contextless" (
	target_min, target_size: i32,
	view_min, view_size: i32,
	padding: i32,
) -> i32 {
	if view_size <= 0 || target_size <= 0 {
		return 0
	}
	pad := clamp(padding, 0, max(0, (view_size - target_size) / 2))
	vis_min := view_min + pad
	vis_max := view_min + view_size - pad
	if target_size >= vis_max - vis_min {
		return target_min - vis_min
	}
	if target_min < vis_min {
		return target_min - vis_min
	}
	if target_min + target_size > vis_max {
		return (target_min + target_size) - vis_max
	}
	return 0
}

// Walks upward from `target_idx`'s parent through enclosing materialized scroll containers
// and shifts descendant `rect` and `node_clip`/`inner_clip` on the exact same frame (`0` frame lag).
scroll_node_into_view :: proc "contextless" (inp: ^Input_State, ctx: ^Layout_Context, target_idx: i32) {
	if target_idx < 0 || int(target_idx) >= len(ctx.nodes) {
		return
	}
	curr := ctx.nodes[target_idx].parent_idx
	for curr >= 0 && int(curr) < len(ctx.nodes) {
		sc_node := ctx.nodes[curr]
		if sc_node.config.scrollable && sc_node.config.virtual_total_rows == 0 {
			slot := get_scroll_slot(inp, sc_node.id_hash)
			t_rect := ctx.nodes[target_idx].rect
			delta_y := compute_axis_scroll_delta(
				t_rect.y,
				t_rect.h,
				sc_node.inner_rect.y,
				sc_node.inner_rect.h,
				slot.scroll_padding,
			)
			if delta_y != 0 {
				apply_scroll_delta(inp, ctx, curr, delta_y, false)
			}
			t_rect = ctx.nodes[target_idx].rect
			delta_x := compute_axis_scroll_delta(
				t_rect.x,
				t_rect.w,
				sc_node.inner_rect.x,
				sc_node.inner_rect.w,
				slot.scroll_padding,
			)
			if delta_x != 0 {
				apply_scroll_delta_x(inp, ctx, curr, delta_x)
			}
		}
		if sc_node.out_of_flow {
			break
		}
		curr = sc_node.parent_idx
	}
}


sync_scroll_viewports :: proc "contextless" (inp: ^Input_State, ctx: ^Layout_Context) {
	for i := 0; i < len(ctx.nodes); i += 1 {
		node := &ctx.nodes[i]
		if node.config.slider {
			sl_slot := get_slider_slot(inp, node.id_hash)
			if node.inner_rect.w > 0 {
				sl_slot.solved_w = node.inner_rect.w
			}
		}
		if !node.config.scrollable {
			continue
		}
		slot := get_scroll_slot(inp, node.id_hash)
		hdr_h := i32(slot.header_rows)
		slot.viewport_rows   = max(1, node.inner_rect.h - hdr_h)
		slot.viewport_cols   = max(1, node.inner_rect.w)
		slot.total_rows      = node.content_span[1]
		slot.total_content_w = node.content_span[0]
		slot.max_offset      = max(0, slot.total_rows - slot.viewport_rows)
		slot.max_offset_x    = max(0, slot.total_content_w - slot.viewport_cols)

		if slot.col_spec_count > 0 && node.inner_rect.w > 0 {
			avail_rect := table_avail_inner_rect(node.inner_rect, node.config.border, slot.total_rows, slot.viewport_rows)
			_ = resolve_slot_table_columns(slot, avail_rect)
			if node.config.border == .None && slot.max_offset_x > 0 && node.inner_rect.h > hdr_h + 2 {
				slot.viewport_rows = max(1, node.inner_rect.h - hdr_h - 1)
				slot.max_offset    = max(0, slot.total_rows - slot.viewport_rows)
				next_avail := table_avail_inner_rect(node.inner_rect, node.config.border, slot.total_rows, slot.viewport_rows)
				if next_avail.w != avail_rect.w {
					avail_rect = next_avail
					_ = resolve_slot_table_columns(slot, avail_rect)
				}
			}
			// Expose total horizontal content width to `render_layout` so the horizontal scrollbar
			// renders whenever scrollable columns overflow the right quadrant (`max_offset_x > 0`).
			node.content_span[0] = node.inner_rect.w + slot.max_offset_x
		} else if node.config.border == .None && slot.max_offset_x > 0 && node.inner_rect.h > hdr_h + 2 {
			slot.viewport_rows = max(1, node.inner_rect.h - hdr_h - 1)
			slot.max_offset    = max(0, slot.total_rows - slot.viewport_rows)
		}

		if node.config.virtual_total_rows == 0 {
			was_consecutive := slot.last_layout_gen > 0 && ctx.layout_gen >= slot.last_layout_gen
			desired_offset := node.config.scroll_offset
			if desired_offset == 0 && node.applied_scroll_offset == 0 && was_consecutive {
				desired_offset = slot.offset
			}
			new_offset := clamp(desired_offset, 0, slot.max_offset)
			delta_unapplied := new_offset - node.applied_scroll_offset
			slot.offset                = new_offset
			node.config.scroll_offset  = new_offset
			node.applied_scroll_offset = new_offset
			if delta_unapplied != 0 {
				shift_descendants_y(ctx, i32(i), -delta_unapplied, node.inner_clip)
			}

			desired_offset_x := node.config.scroll_offset_x
			if desired_offset_x == 0 && node.applied_scroll_offset_x == 0 && was_consecutive {
				desired_offset_x = slot.offset_x
			}
			new_offset_x := clamp(desired_offset_x, 0, slot.max_offset_x)
			delta_unapplied_x := new_offset_x - node.applied_scroll_offset_x
			slot.offset_x                = new_offset_x
			node.config.scroll_offset_x  = new_offset_x
			node.applied_scroll_offset_x = new_offset_x
			if delta_unapplied_x != 0 {
				shift_descendants_x(ctx, i32(i), -delta_unapplied_x, node.inner_clip)
			}
		} else {
			if slot.follow_tail && ((slot.prev_total_rows > 0 && slot.total_rows > slot.prev_total_rows) || slot.selected_row >= max(0, slot.total_rows - 1)) {
				slot.offset       = slot.max_offset
				slot.selected_row = max(0, slot.total_rows - 1)
			}
			slot.prev_total_rows        = slot.total_rows
			slot.offset                 = clamp(slot.offset, 0, slot.max_offset)
			slot.offset_x               = clamp(slot.offset_x, 0, slot.max_offset_x)
			node.config.scroll_offset   = slot.offset
			node.config.scroll_offset_x = slot.offset_x
		}
		slot.selected_row    = clamp(slot.selected_row, 0, max(0, slot.total_rows - 1))
		slot.selected_col    = clamp(slot.selected_col, 0, max(0, max(1, slot.total_cols) - 1))
		slot.last_layout_gen = ctx.layout_gen
	}
}

// Walks ctx.z_order front-to-back to find the topmost visible node at (mx, my),
// then bubbles up parent_idx to find the nearest enclosing scrollable container.
hit_test_scrollable :: proc "contextless" (ctx: ^Layout_Context, capture_idx: i32, mx, my: i32) -> i32 {
	if mx < 0 || mx >= ctx.screen_size[0] || my < 0 || my >= ctx.screen_size[1] {
		return -1
	}

	min_allowed_z := compute_active_shield_z(ctx)
	if capture_idx >= 0 {
		min_allowed_z = max(min_allowed_z, ctx.nodes[capture_idx].effective_z)
	}

	for i := len(ctx.z_order) - 1; i >= 0; i -= 1 {
		idx := ctx.z_order[i]
		node := ctx.nodes[idx]

		if node.effective_z < min_allowed_z {
			break
		}
		if !is_node_allowed(ctx, idx, capture_idx) || (.Disabled in node.focus_flags) {
			continue
		}
		if !point_in_rect(mx, my, node.node_clip) || !point_in_rect(mx, my, node.rect) {
			continue
		}

		// Bubble up from the hit node to its nearest scrollable ancestor
		// without crossing out-of-flow overlay boundaries.
		curr := idx
		for curr >= 0 {
			curr_node := ctx.nodes[curr]
			if !is_node_allowed(ctx, curr, capture_idx) {
				break
			}
			if curr_node.config.scrollable || curr_node.config.text_area {
				return curr
			}
			if curr_node.out_of_flow || curr_node.config.capture_input {
				break
			}
			curr = curr_node.parent_idx
		}

		// Stop if we hit a non-scrollable floating overlay or modal so wheel events never punch through
		if node.out_of_flow || node.config.capture_input {
			return -1
		}
	}
	return -1
}

handle_mouse_scroll :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	mx, my: i32,
	dir: i32, // -1 for Scroll_Up, +1 for Scroll_Down
) -> bool {
	scroll_idx := hit_test_scrollable(ctx, capture_idx, mx, my)
	if scroll_idx < 0 {
		return false
	}

	node := &ctx.nodes[scroll_idx]
	step := node.config.scroll_step if node.config.scroll_step > 0 else 3
	if node.config.text_area {
		ta_slot := get_text_area_slot(inp, node.id_hash)
		viewport_h := max(1, node.inner_rect.h)
		max_scroll := max(0, i32(ta_slot.line_count) - viewport_h)
		ta_slot.scroll_row = clamp(ta_slot.scroll_row + dir * step, 0, max_scroll)
		inp.scrolled_id    = node.id_hash
		return true
	}
	if node.config.virtual_total_rows == 0 && node.content_span[1] <= node.inner_rect.h && node.content_span[0] > node.inner_rect.w {
		apply_scroll_delta_x(inp, ctx, scroll_idx, dir * step)
		return true
	}
	apply_scroll_delta(inp, ctx, scroll_idx, dir * step, false)
	return true
}

handle_mouse_scroll_x :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	mx, my: i32,
	dir: i32, // -1 for Scroll_Left, +1 for Scroll_Right
) -> bool {
	scroll_idx := hit_test_scrollable(ctx, capture_idx, mx, my)
	if scroll_idx < 0 {
		return false
	}

	node := &ctx.nodes[scroll_idx]
	step := node.config.scroll_step if node.config.scroll_step > 0 else 4
	if node.config.text_area {
		ta_slot := get_text_area_slot(inp, node.id_hash)
		ta_slot.scroll_col = max(0, ta_slot.scroll_col + dir * step)
		inp.scrolled_id    = node.id_hash
		return true
	}
	apply_scroll_delta_x(inp, ctx, scroll_idx, dir * step)
	return true
}

handle_key_scroll :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	capture_idx: i32,
	code: Key_Code,
) -> bool {
	if inp.focused_id == 0 {
		return false
	}
	focus_idx, exists := ctx.id_map[inp.focused_id]
	if !exists || !is_node_allowed(ctx, focus_idx, capture_idx) {
		return false
	}

	scroll_idx := i32(-1)
	curr := focus_idx
	for curr >= 0 {
		if ctx.nodes[curr].config.scrollable && is_node_allowed(ctx, curr, capture_idx) {
			scroll_idx = curr
			break
		}
		if ctx.nodes[curr].out_of_flow {
			break
		}
		curr = ctx.nodes[curr].parent_idx
	}

	if scroll_idx < 0 {
		return false
	}

	node := &ctx.nodes[scroll_idx]
	slot := get_scroll_slot(inp, node.id_hash)
	page := max(1, slot.viewport_rows - 1)
	is_virtual := node.config.virtual_total_rows > 0

	#partial switch code {
	case .Up:
		if is_virtual {
			move_virtual_selection(slot, -1)
			sync_tree_selection_from_scroll(inp, node.id_hash, slot.selected_row)
			node.config.scroll_offset = slot.offset
			inp.scrolled_id = node.id_hash
		} else {
			apply_scroll_delta(inp, ctx, scroll_idx, -1, false)
		}
		return true
	case .Down:
		if is_virtual {
			move_virtual_selection(slot, +1)
			sync_tree_selection_from_scroll(inp, node.id_hash, slot.selected_row)
			node.config.scroll_offset = slot.offset
			inp.scrolled_id = node.id_hash
		} else {
			apply_scroll_delta(inp, ctx, scroll_idx, +1, false)
		}
		return true
	case .Page_Up:
		if is_virtual {
			move_virtual_selection(slot, -page)
			sync_tree_selection_from_scroll(inp, node.id_hash, slot.selected_row)
			node.config.scroll_offset = slot.offset
			inp.scrolled_id = node.id_hash
		} else {
			apply_scroll_delta(inp, ctx, scroll_idx, -page, false)
		}
		return true
	case .Page_Down:
		if is_virtual {
			move_virtual_selection(slot, +page)
			sync_tree_selection_from_scroll(inp, node.id_hash, slot.selected_row)
			node.config.scroll_offset = slot.offset
			inp.scrolled_id = node.id_hash
		} else {
			apply_scroll_delta(inp, ctx, scroll_idx, +page, false)
		}
		return true
	case .Home:
		if is_virtual {
			slot.selected_row = 0
			slot.follow_tail  = false
			sync_tree_selection_from_scroll(inp, node.id_hash, slot.selected_row)
		}
		apply_scroll_delta(inp, ctx, scroll_idx, -slot.max_offset - 1, false)
		return true
	case .End:
		if is_virtual {
			slot.selected_row = max(0, slot.total_rows - 1)
			slot.follow_tail  = true
			sync_tree_selection_from_scroll(inp, node.id_hash, slot.selected_row)
		}
		apply_scroll_delta(inp, ctx, scroll_idx, slot.max_offset + 1, false)
		return true
	}
	return false
}

move_virtual_selection :: proc "contextless" (slot: ^Scroll_Slot, delta: i32) {
	if slot.total_rows <= 0 {
		return
	}
	if delta < 0 {
		slot.follow_tail = false
	} else if delta > 0 && slot.selected_row + delta >= slot.total_rows - 1 {
		slot.follow_tail = true
	}
	slot.selected_row = clamp(slot.selected_row + delta, 0, slot.total_rows - 1)
	v_rows := max(1, slot.viewport_rows)
	pad := clamp(slot.scroll_padding, 0, max(0, (v_rows - 1) / 2))
	if slot.selected_row < slot.offset + pad {
		slot.offset = slot.selected_row - pad
	} else if slot.selected_row >= slot.offset + v_rows - pad {
		slot.offset = slot.selected_row - v_rows + 1 + pad
	}
	slot.offset = clamp(slot.offset, 0, slot.max_offset)
}

apply_scroll_delta :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	scroll_idx: i32,
	delta: i32,
	move_selection: bool,
) {
	node := &ctx.nodes[scroll_idx]
	slot := get_scroll_slot(inp, node.id_hash)
	old_offset := slot.offset
	new_offset := clamp(old_offset + delta, 0, slot.max_offset)
	actual_delta := new_offset - old_offset

	if delta < 0 && new_offset < slot.max_offset {
		slot.follow_tail = false
	} else if delta > 0 && new_offset >= slot.max_offset {
		slot.follow_tail = true
	}

	slot.offset                = new_offset
	node.config.scroll_offset  = new_offset
	node.applied_scroll_offset = new_offset
	inp.scrolled_id            = node.id_hash

	if move_selection && node.config.virtual_total_rows > 0 {
		slot.selected_row = clamp(slot.selected_row + delta, 0, max(0, slot.total_rows - 1))
		sync_tree_selection_from_scroll(inp, node.id_hash, slot.selected_row)
	}

	if actual_delta != 0 && node.config.virtual_total_rows == 0 {
		shift_descendants_y(ctx, scroll_idx, -actual_delta, node.inner_clip)
	}
}

shift_descendants_y :: proc "contextless" (ctx: ^Layout_Context, parent_idx: i32, dy: i32, clip_root: Rect) {
	for c := ctx.nodes[parent_idx].first_child; c != -1; c = ctx.nodes[c].next_sibling {
		child := &ctx.nodes[c]
		if child.out_of_flow {
			continue
		}
		child.rect.y       += dy
		child.inner_rect.y += dy
		child.node_clip     = rect_intersect(clip_root, child.rect)
		child.inner_clip    = rect_intersect(child.node_clip, child.inner_rect)
		if child.child_count > 0 {
			shift_descendants_y(ctx, c, dy, child.inner_clip)
		}
	}
}

apply_scroll_delta_x :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	scroll_idx: i32,
	delta_x: i32,
) {
	node := &ctx.nodes[scroll_idx]
	slot := get_scroll_slot(inp, node.id_hash)
	old_offset_x := slot.offset_x
	new_offset_x := clamp(old_offset_x + delta_x, 0, slot.max_offset_x)
	actual_dx := new_offset_x - old_offset_x

	slot.offset_x                = new_offset_x
	node.config.scroll_offset_x  = new_offset_x
	node.applied_scroll_offset_x = new_offset_x
	inp.scrolled_id              = node.id_hash

	if actual_dx != 0 && node.config.virtual_total_rows == 0 {
		shift_descendants_x(ctx, scroll_idx, -actual_dx, node.inner_clip)
	}
}

shift_descendants_x :: proc "contextless" (ctx: ^Layout_Context, parent_idx: i32, dx: i32, clip_root: Rect) {
	for c := ctx.nodes[parent_idx].first_child; c != -1; c = ctx.nodes[c].next_sibling {
		child := &ctx.nodes[c]
		if child.out_of_flow {
			continue
		}
		child.rect.x       += dx
		child.inner_rect.x += dx
		child.node_clip     = rect_intersect(clip_root, child.rect)
		child.inner_clip    = rect_intersect(child.node_clip, child.inner_rect)
		if child.child_count > 0 {
			shift_descendants_x(ctx, c, dx, child.inner_clip)
		}
	}
}

// =============================================================================
// Interactive `ui_table` Keyboard Shortcuts, Header Sort, Divider Resize & Scrollbar Scrubbing
// =============================================================================

cycle_table_sort_dir :: proc "contextless" (slot: ^Scroll_Slot, col_idx: i32) {
	if slot.sort_col == i16(col_idx) {
		switch slot.sort_dir {
		case .None: slot.sort_dir = .Asc
		case .Asc:  slot.sort_dir = .Desc
		case .Desc:
			slot.sort_dir = .None
			slot.sort_col = -1
		}
	} else {
		slot.sort_col = i16(col_idx)
		slot.sort_dir = .Asc
	}
	slot.sort_changed = true
}

handle_table_key_shortcut :: proc "contextless" (
	inp: ^Input_State,
	node: ^Layout_Node,
	slot: ^Scroll_Slot,
	ch: rune,
) -> bool {
	cnt := int(min(slot.col_spec_count, MAX_TABLE_COLS))
	if cnt <= 0 {
		return false
	}
	sel := int(clamp(slot.selected_col, 0, i32(cnt - 1)))
	avail_rect := table_avail_inner_rect(node.inner_rect, node.config.border, slot.total_rows, slot.viewport_rows)

	switch ch {
	case 's', 'S':
		if !slot.sortable {
			return false
		}
		_ = consume_repeat_count(inp)
		cycle_table_sort_dir(slot, i32(sel))
		_ = resolve_slot_table_columns(slot, avail_rect)
		return true

	case '+', '=':
		if !slot.resizable {
			return false
		}
		step := 2 * max(1, consume_repeat_count(inp))
		cur_w := max(1, i32(slot.col_x_widths[sel]))
		min_w := max(1, i32(slot.col_min_widths[sel]))
		slot.col_user_widths[sel] = i16(clamp(max(min_w, cur_w + step), 1, 512))
		_ = resolve_slot_table_columns(slot, avail_rect)
		ensure_virtual_col_visible(slot, avail_rect.w)
		node.config.scroll_offset_x = slot.offset_x
		node.content_span[0]        = node.inner_rect.w + slot.max_offset_x
		inp.scrolled_id             = node.id_hash
		return true

	case '-':
		if !slot.resizable {
			return false
		}
		step := 2 * max(1, consume_repeat_count(inp))
		cur_w := max(1, i32(slot.col_x_widths[sel]))
		min_w := max(1, i32(slot.col_min_widths[sel]))
		slot.col_user_widths[sel] = i16(clamp(max(min_w, cur_w - step), 1, 512))
		_ = resolve_slot_table_columns(slot, avail_rect)
		ensure_virtual_col_visible(slot, avail_rect.w)
		node.config.scroll_offset_x = slot.offset_x
		node.content_span[0]        = node.inner_rect.w + slot.max_offset_x
		inp.scrolled_id             = node.id_hash
		return true

	case '0':
		if !slot.resizable {
			return false
		}
		if inp.repeat_count == 0 && inp.suffix_count == 0 {
			for i := 0; i < cnt; i += 1 {
				slot.col_user_widths[i]  = 0
				slot.col_max_observed[i] = slot.col_header_widths[i]
			}
			slot.auto_size_this_frame = true
			_ = resolve_slot_table_columns(slot, avail_rect)
			ensure_virtual_col_visible(slot, avail_rect.w)
			node.config.scroll_offset_x = slot.offset_x
			node.content_span[0]        = node.inner_rect.w + slot.max_offset_x
			inp.scrolled_id             = node.id_hash
			return true
		}

	case '^':
		_ = consume_repeat_count(inp)
		slot.selected_col = 0
		slot.offset_x     = 0
		_ = resolve_slot_table_columns(slot, avail_rect)
		node.config.scroll_offset_x = slot.offset_x
		node.content_span[0]        = node.inner_rect.w + slot.max_offset_x
		inp.scrolled_id             = node.id_hash
		return true

	case '$':
		_ = consume_repeat_count(inp)
		slot.selected_col = i32(cnt - 1)
		ensure_virtual_col_visible(slot, avail_rect.w)
		_ = resolve_slot_table_columns(slot, avail_rect)
		node.config.scroll_offset_x = slot.offset_x
		node.content_span[0]        = node.inner_rect.w + slot.max_offset_x
		inp.scrolled_id             = node.id_hash
		return true
	}
	return false
}

scrub_vertical_scrollbar :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	scroll_idx: i32,
	slot: ^Scroll_Slot,
	my: i32,
) {
	node := &ctx.nodes[scroll_idx]
	hdr_h := i32(slot.header_rows)
	track_y := node.inner_rect.y + hdr_h
	track_h := max(1, node.inner_rect.h - hdr_h)
	rel_y := clamp(my - track_y, 0, max(0, track_h - 1))
	target_off: i32 = 0
	if track_h > 1 && slot.max_offset > 0 {
		target_off = i32((i64(rel_y) * i64(slot.max_offset) + i64(track_h - 1) / 2) / i64(track_h - 1))
	}
	target_off = clamp(target_off, 0, slot.max_offset)
	delta := target_off - slot.offset
	if node.config.virtual_total_rows > 0 {
		slot.offset               = target_off
		slot.follow_tail          = target_off >= slot.max_offset
		node.config.scroll_offset = target_off
		if slot.selected_row < target_off {
			slot.selected_row = target_off
		} else if slot.selected_row >= target_off + slot.viewport_rows {
			slot.selected_row = clamp(target_off + slot.viewport_rows - 1, 0, max(0, slot.total_rows - 1))
		}
		sync_tree_selection_from_scroll(inp, node.id_hash, slot.selected_row)
		inp.scrolled_id = node.id_hash
	} else if delta != 0 {
		apply_scroll_delta(inp, ctx, scroll_idx, delta, false)
	}
}

scrub_horizontal_scrollbar :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	scroll_idx: i32,
	slot: ^Scroll_Slot,
	mx: i32,
) {
	node := &ctx.nodes[scroll_idx]
	track_x := node.inner_rect.x
	track_w := max(1, node.inner_rect.w)
	rel_x := clamp(mx - track_x, 0, max(0, track_w - 1))
	target_off_x: i32 = 0
	if track_w > 1 && slot.max_offset_x > 0 {
		target_off_x = i32((i64(rel_x) * i64(slot.max_offset_x) + i64(track_w - 1) / 2) / i64(track_w - 1))
	}
	target_off_x = clamp(target_off_x, 0, slot.max_offset_x)
	delta_x := target_off_x - slot.offset_x
	if node.config.virtual_total_rows > 0 {
		slot.offset_x               = target_off_x
		node.config.scroll_offset_x = target_off_x
		if slot.col_spec_count > 0 {
			avail_rect := table_avail_inner_rect(node.inner_rect, node.config.border, slot.total_rows, slot.viewport_rows)
			_ = resolve_slot_table_columns(slot, avail_rect)
		}
		inp.scrolled_id = node.id_hash
	} else if delta_x != 0 {
		apply_scroll_delta_x(inp, ctx, scroll_idx, delta_x)
	}
}

handle_scroll_or_table_mouse_press :: proc(
	inp: ^Input_State,
	ctx: ^Layout_Context,
	scroll_idx: i32,
	capture_idx: i32,
	mx, my: i32,
) -> bool {
	if scroll_idx < 0 || int(scroll_idx) >= len(ctx.nodes) {
		return false
	}
	node := &ctx.nodes[scroll_idx]
	slot := get_scroll_slot(inp, node.id_hash)
	slot.dragging_col_idx     = -1
	slot.dragging_v_scrollbar = false
	slot.dragging_h_scrollbar = false

	hdr_h := i32(slot.header_rows)
	v_track_y := node.inner_rect.y + hdr_h
	v_track_h := max(0, node.inner_rect.h - hdr_h)
	sb_x := (node.rect.x + node.rect.w - 1) if node.rect.w > node.inner_rect.w else (node.inner_rect.x + node.inner_rect.w - 1)
	if slot.max_offset > 0 && v_track_h > 0 && mx == sb_x && my >= v_track_y && my < v_track_y + v_track_h {
		slot.dragging_v_scrollbar = true
		scrub_vertical_scrollbar(inp, ctx, scroll_idx, slot, my)
		return true
	}

	h_sb_active := slot.max_offset_x > 0 && node.inner_rect.w > 0 && (node.rect.h > node.inner_rect.h || node.inner_rect.h > hdr_h + 2)
	sb_y := (node.rect.y + node.rect.h - 1) if node.rect.h > node.inner_rect.h else (node.inner_rect.y + node.inner_rect.h - 1)
	if h_sb_active && my == sb_y && mx >= node.inner_rect.x && mx < node.inner_rect.x + node.inner_rect.w {
		slot.dragging_h_scrollbar = true
		scrub_horizontal_scrollbar(inp, ctx, scroll_idx, slot, mx)
		return true
	}

	if node.config.virtual_total_rows <= 0 {
		return false
	}

	if handle_tree_mouse_click(inp, ctx, scroll_idx, capture_idx, my) {
		return true
	}

	// Check for column divider press (`│` / `║`) to start interactive column resize drag
	if slot.resizable && slot.col_spec_count > 1 &&
	   mx >= node.inner_rect.x && mx < node.inner_rect.x + node.inner_rect.w &&
	   my >= node.inner_rect.y && my < node.inner_rect.y + node.inner_rect.h {
		cnt := int(min(slot.col_spec_count, MAX_TABLE_COLS))
		pinned := int(clamp(i32(slot.pinned_cols), 0, max(0, i32(cnt) - 1)))
		pinned_right := node.inner_rect.x + i32(slot.pinned_area_w)
		col_sp := max(1, i32(slot.col_spacing))
		for c := 0; c + 1 < cnt; c += 1 {
			if c >= pinned && !slot.col_is_visible[c] {
				continue
			}
			div_x := table_col_divider_x(i32(slot.col_x_starts[c]), i32(slot.col_x_widths[c]), col_sp)
			if c >= pinned && div_x < pinned_right {
				continue
			}
			if mx == div_x {
				slot.dragging_col_idx = i16(c)
				slot.drag_col_start_x = i16(clamp(mx, -32768, 32767))
				slot.drag_col_start_w = slot.col_x_widths[c]
				return true
			}
		}
	}

	// Check for sticky header click (`my == node.inner_rect.y` when `hdr_h > 0`) to select column & cycle sort
	if hdr_h > 0 && my == node.inner_rect.y && mx >= node.inner_rect.x && mx < node.inner_rect.x + node.inner_rect.w {
		select_virtual_col_at_x(slot, node.inner_rect, mx)
		if slot.sortable {
			cycle_table_sort_dir(slot, slot.selected_col)
		}
		avail_rect := table_avail_inner_rect(node.inner_rect, node.config.border, slot.total_rows, slot.viewport_rows)
		_ = resolve_slot_table_columns(slot, avail_rect)
		node.config.scroll_offset_x = slot.offset_x
		node.content_span[0]        = node.inner_rect.w + slot.max_offset_x
		return true
	}

	if mx >= node.inner_rect.x && mx < node.inner_rect.x + node.inner_rect.w &&
	   my >= node.inner_rect.y && my < node.inner_rect.y + node.inner_rect.h {
		rel_y := my - node.inner_rect.y - hdr_h
		data_h := max(0, node.inner_rect.h - hdr_h - (1 if (node.config.border == .None && h_sb_active) else 0))
		if rel_y >= 0 && rel_y < data_h {
			slot.selected_row = clamp(slot.offset + rel_y, 0, max(0, slot.total_rows - 1))
			slot.follow_tail  = slot.selected_row >= slot.total_rows - 1
		}
		select_virtual_col_at_x(slot, node.inner_rect, mx)
		if slot.col_spec_count > 0 {
			avail_rect := table_avail_inner_rect(node.inner_rect, node.config.border, slot.total_rows, slot.viewport_rows)
			_ = resolve_slot_table_columns(slot, avail_rect)
			node.config.scroll_offset_x = slot.offset_x
			node.content_span[0]        = node.inner_rect.w + slot.max_offset_x
		}
	}
	return true
}

handle_scroll_or_table_mouse_drag :: proc "contextless" (
	inp: ^Input_State,
	ctx: ^Layout_Context,
	scroll_idx: i32,
	mx, my: i32,
) -> bool {
	if scroll_idx < 0 || int(scroll_idx) >= len(ctx.nodes) {
		return false
	}
	node := &ctx.nodes[scroll_idx]
	slot := get_scroll_slot(inp, node.id_hash)
	if slot.dragging_v_scrollbar {
		scrub_vertical_scrollbar(inp, ctx, scroll_idx, slot, my)
		return true
	}
	if slot.dragging_h_scrollbar {
		scrub_horizontal_scrollbar(inp, ctx, scroll_idx, slot, mx)
		return true
	}
	if slot.dragging_col_idx >= 0 && int(slot.dragging_col_idx) < int(slot.col_spec_count) {
		c := int(slot.dragging_col_idx)
		dx := mx - i32(slot.drag_col_start_x)
		min_w := max(1, i32(slot.col_min_widths[c]))
		new_w := clamp(i32(slot.drag_col_start_w) + dx, min_w, 512)
		slot.col_user_widths[c] = i16(new_w)
		avail_rect := table_avail_inner_rect(node.inner_rect, node.config.border, slot.total_rows, slot.viewport_rows)
		_ = resolve_slot_table_columns(slot, avail_rect)
		node.config.scroll_offset_x = slot.offset_x
		node.content_span[0]        = node.inner_rect.w + slot.max_offset_x
		inp.scrolled_id             = node.id_hash
		return true
	}
	return false
}


