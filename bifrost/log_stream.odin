package bifrost

import "core:fmt"
import "core:strings"

// =============================================================================
// Track 20: Auto-Scrolling Log Stream Viewer (`ui_log_viewer`)
// =============================================================================

Log_Level :: enum u8 {
	Trace = 0,
	Debug = 1,
	Info  = 2,
	Warn  = 3,
	Error = 4,
	Fatal = 5,
}

Log_Entry :: struct {
	timestamp: string,
	level:     Log_Level,
	target:    string,
	message:   string,
}

Log_Viewer_State :: struct {
	is_following:      bool, // "tail -f" auto-scroll pinned to bottom
	selected_row:      i32,
	scroll_offset:     i32,
	last_seen_total:   i32,
	new_unread_count:  i32,
	filter_level:      Log_Level,
	last_filter_level: Log_Level,
}

Log_Viewer_Config :: struct {
	title:             string,
	width:             Axis_Size,
	height:            Axis_Size,
	border:            Border_Kind,
	border_fg:         Color,
	title_fg:          Color,
	bg:                Color,
	fg:                Color,
	show_line_numbers: bool,
	show_timestamps:   bool,
	show_targets:      bool,
	show_badge:        bool,
	fallback_rows:     i32,
}

log_level_colors :: proc "contextless" (level: Log_Level) -> (fg, bg: Color, name: string) {
	switch level {
	case .Trace:
		return rgb(140, 145, 155), rgb(20, 24, 32), "TRACE"
	case .Debug:
		return rgb(100, 180, 240), rgb(20, 28, 40), "DEBUG"
	case .Info:
		return rgb(120, 220, 140), rgb(20, 36, 28), "INFO "
	case .Warn:
		return rgb(250, 190, 60), rgb(42, 34, 16), "WARN "
	case .Error:
		return rgb(255, 90, 90), rgb(45, 20, 24), "ERROR"
	case .Fatal:
		return rgb(255, 255, 255), rgb(160, 20, 30), "FATAL"
	}
	return rgb(200, 200, 200), rgb(20, 20, 20), "INFO "
}

ui_log_viewer :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	entries: []Log_Entry,
	state: ^Log_Viewer_State,
	cfg: Log_Viewer_Config = {},
) -> bool {
	id_h := hash_id(id)
	slot := get_scroll_slot(inp, id_h)

	filtered := entries
	if state.filter_level > .Trace {
		f_list := make([dynamic]Log_Entry, 0, len(entries), context.temp_allocator)
		for e in entries {
			if e.level >= state.filter_level {
				append(&f_list, e)
			}
		}
		filtered = f_list[:]
	}
	total_entries := i32(len(filtered))

	if slot.viewport_rows <= 0 {
		if fixed_h, is_fixed := cfg.height.(Fixed); is_fixed && i32(fixed_h) > 0 {
			bdr_h: i32 = 2 if cfg.border != .None else 0
			slot.viewport_rows = max(1, i32(fixed_h) - bdr_h)
		} else if cfg.fallback_rows > 0 {
			slot.viewport_rows = cfg.fallback_rows
		} else {
			slot.viewport_rows = 10
		}
	}

	// Initial mount initialization or filter change reconciliation
	filter_changed := state.last_filter_level != state.filter_level
	state.last_filter_level = state.filter_level

	max_offset := max(0, total_entries - slot.viewport_rows)
	if state.last_seen_total == 0 || filter_changed || total_entries < state.last_seen_total {
		state.last_seen_total = total_entries
		if state.is_following {
			slot.selected_row = max(0, total_entries - 1)
			slot.offset = max_offset
		}
	} else {
		if state.is_following {
			user_moved_row_up := slot.selected_row < state.selected_row
			user_scrolled_up  := slot.offset < state.scroll_offset && slot.offset < max_offset
			if user_moved_row_up || user_scrolled_up {
				state.is_following = false
			}
		} else {
			row_reached_bottom    := slot.selected_row > state.selected_row && slot.selected_row >= total_entries - 1
			scroll_reached_bottom := slot.offset > state.scroll_offset && slot.offset >= max_offset
			if total_entries > 0 && (row_reached_bottom || scroll_reached_bottom) {
				state.is_following = true
				state.new_unread_count = 0
				slot.selected_row = total_entries - 1
			}
		}

		if !state.is_following && total_entries > state.last_seen_total {
			state.new_unread_count += total_entries - state.last_seen_total
		}
	}

	badge_id := fmt.tprintf("%s_badge", id)

	// Check if badge clicked or follow key triggered
	if was_activated(inp, badge_id) || was_clicked(inp, badge_id) {
		state.is_following = true
		state.new_unread_count = 0
		request_focus(inp, id)
	}

	// If following, lock to bottom
	if state.is_following {
		state.new_unread_count = 0
		slot.offset = max(0, total_entries - slot.viewport_rows)
		slot.selected_row = max(0, total_entries - 1)
	}

	state.last_seen_total = total_entries
	state.scroll_offset   = slot.offset
	state.selected_row    = slot.selected_row

	// Render virtual list
	slice: Virtual_Slice
	v_cfg := Virtual_List_Config{
		title         = cfg.title,
		width         = cfg.width,
		height        = cfg.height,
		border        = cfg.border,
		border_fg     = cfg.border_fg,
		title_fg      = cfg.title_fg,
		bg            = cfg.bg,
		fg            = cfg.fg,
		fallback_rows = cfg.fallback_rows if cfg.fallback_rows > 0 else 10,
		focusable     = true,
		focus_flags   = {.Focusable, .Default_Focus},
	}

	if ui_virtual_list(ctx, s, inp, id, total_entries, v_cfg, &slice) {
		for r := slice.start_row; r < slice.end_row; r += 1 {
			if r < 0 || r >= total_entries {
				continue
			}
			e := filtered[r]

			row_id := fmt.tprintf("%s_row_%d", id, r)

			// Construct formatted row text and styled spans
			line_buf: strings.Builder
			strings.builder_init(&line_buf, context.temp_allocator)
			spans := make([dynamic]Styled_Span, 0, 5, context.temp_allocator)

			msg_fg := cfg.fg if cfg.fg.kind != .Default else rgb(220, 225, 235)
			if e.level == .Error || e.level == .Fatal {
				msg_fg = rgb(255, 100, 100)
			} else if e.level == .Warn {
				msg_fg = rgb(250, 190, 60)
			}

			if cfg.show_line_numbers {
				ln_str := fmt.tprintf("%4d ", r + 1)
				strings.write_string(&line_buf, ln_str)
				append(&spans, Styled_Span{text = ln_str, fg = rgb(130, 145, 165), bg = cfg.bg})
			}
			if cfg.show_timestamps && len(e.timestamp) > 0 {
				ts_str := fmt.tprintf("%s ", e.timestamp)
				strings.write_string(&line_buf, ts_str)
				append(&spans, Styled_Span{text = ts_str, fg = rgb(140, 155, 175), bg = cfg.bg})
			}
			lvl_fg, lvl_bg, lvl_name := log_level_colors(e.level)
			lvl_badge := fmt.tprintf("[%s]", lvl_name)
			strings.write_string(&line_buf, lvl_badge)
			strings.write_byte(&line_buf, ' ')
			append(&spans, Styled_Span{text = lvl_badge, fg = lvl_fg, bg = lvl_bg, style = {.Bold}})
			append(&spans, Styled_Span{text = " ", fg = msg_fg, bg = cfg.bg})

			if cfg.show_targets && len(e.target) > 0 {
				tgt_str := fmt.tprintf("%s: ", e.target)
				strings.write_string(&line_buf, tgt_str)
				append(&spans, Styled_Span{text = tgt_str, fg = rgb(160, 195, 235), bg = cfg.bg})
			}
			strings.write_string(&line_buf, e.message)
			append(&spans, Styled_Span{text = e.message, fg = msg_fg, bg = cfg.bg})

			row_text := strings.to_string(line_buf)

			if s != nil {
				s.paints[hash_id(row_id)] = Paint_Spec{
					text    = row_text,
					spans   = spans[:],
					fg      = msg_fg,
					bg      = cfg.bg,
					fill_bg = true,
				}
			}

			leaf(ctx, row_id, string_display_width(row_text), 1, Box_Config{
				width  = grow(1),
				height = fixed(1),
				text   = row_text,
			})
		}
	}

	// 6. Floating "Jump to Latest" pill badge when unpinned
	if !state.is_following && (cfg.show_badge || state.new_unread_count > 0) {
		badge_text: string
		if state.new_unread_count > 0 {
			badge_text = fmt.tprintf(" ▾ Follow ( %d new ) ", state.new_unread_count)
		} else {
			badge_text = " ▾ Follow / Latest "
		}

		b_w := string_display_width(badge_text)
		b_fg := rgb(255, 255, 255)
		b_bg := rgb(40, 120, 200) if state.new_unread_count > 0 else rgb(50, 65, 85)

		if s != nil {
			s.paints[hash_id(badge_id)] = Paint_Spec{
				text    = badge_text,
				fg      = b_fg,
				bg      = b_bg,
				style   = {.Bold},
				fill_bg = true,
			}
		}

		leaf(ctx, badge_id, b_w, 1, Box_Config{
			width            = fixed(b_w),
			height           = fixed(1),
			floating         = true,
			anchor           = .Parent,
			anchor_parent_id = id,
			parent_anchor    = .Bottom_Right,
			element_anchor   = .Bottom_Right,
			offset           = {-2, -1},
			z_layer          = 15,
			focusable        = true,
			clickable        = true,
			hoverable        = true,
			text             = badge_text,
		})
	}

	return true
}
