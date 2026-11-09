package bifrost

import "core:fmt"
import "core:strings"

// =============================================================================
// Track 19: Turnkey Modal Dialogs, Floating Toasts & Contextual Tooltips
//           (`ui_confirm_dialog`, `ui_alert`, `ui_prompt`, `ui_toast`, `ui_tooltip`)
// =============================================================================

Dialog_Result :: enum u8 {
	Pending   = 0,
	Confirmed = 1,
	Cancelled = 2,
}

Confirm_Dialog_Config :: struct {
	title:           string,
	message:         string,
	confirm_label:   string,
	cancel_label:    string,
	default_confirm: bool,
	width:           Axis_Size,
	height:          Axis_Size,
	border:          Border_Kind,
	border_fg:       Color,
	title_fg:        Color,
	bg:              Color,
	fg:              Color,
}

Alert_Dialog_Config :: struct {
	title:     string,
	message:   string,
	ok_label:  string,
	width:     Axis_Size,
	height:    Axis_Size,
	border:    Border_Kind,
	border_fg: Color,
	title_fg:  Color,
	bg:        Color,
	fg:        Color,
}

Prompt_Dialog_Config :: struct {
	title:        string,
	message:      string,
	placeholder:  string,
	ok_label:     string,
	cancel_label: string,
	width:        Axis_Size,
	height:       Axis_Size,
	border:       Border_Kind,
	border_fg:    Color,
	title_fg:     Color,
	bg:           Color,
	fg:           Color,
}

Toast_Severity :: enum u8 {
	Info    = 0,
	Success = 1,
	Warning = 2,
	Error   = 3,
}

Toast_Anchor :: enum u8 {
	Top_Right    = 0,
	Top_Left     = 1,
	Bottom_Right = 2,
	Bottom_Left  = 3,
}

MAX_TOASTS :: 8

Toast_Item :: struct {
	id:          u64,
	title_buf:   [64]u8,
	title_len:   int,
	msg_buf:     [128]u8,
	msg_len:     int,
	severity:    Toast_Severity,
	ticks_left:  i32,
	total_ticks: i32,
}

toast_item_title :: proc "contextless" (item: ^Toast_Item) -> string {
	if item == nil || item.title_len <= 0 {
		return ""
	}
	return string(item.title_buf[:item.title_len])
}

toast_item_message :: proc "contextless" (item: ^Toast_Item) -> string {
	if item == nil || item.msg_len <= 0 {
		return ""
	}
	return string(item.msg_buf[:item.msg_len])
}

Toast_Manager :: struct {
	items:   [MAX_TOASTS]Toast_Item,
	count:   int,
	next_id: u64,
	anchor:  Toast_Anchor,
}

Tooltip_Config :: struct {
	fg:        Color,
	bg:        Color,
	border:    Border_Kind,
	border_fg: Color,
	style:     Style_Flags,
}

// =============================================================================
// Turnkey Modal Dialogs
// =============================================================================

ui_confirm_dialog :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	cfg: Confirm_Dialog_Config,
) -> Dialog_Result {
	confirm_id := fmt.tprintf("%s_btn_confirm", id)
	cancel_id  := fmt.tprintf("%s_btn_cancel", id)

	w := cfg.width if cfg.width != nil else fit(min = 36)
	h := cfg.height if cfg.height != nil else fit(min = 7)

	conf_lbl := cfg.confirm_label if len(cfg.confirm_label) > 0 else "Confirm"
	canc_lbl := cfg.cancel_label if len(cfg.cancel_label) > 0 else "Cancel"

	b_fg := cfg.border_fg if cfg.border_fg.kind != .Default else rgb(120, 180, 240)
	t_fg := cfg.title_fg if cfg.title_fg.kind != .Default else rgb(140, 200, 255)
	p_bg := cfg.bg if cfg.bg.kind != .Default else rgb(24, 30, 42)
	p_fg := cfg.fg if cfg.fg.kind != .Default else rgb(220, 225, 235)

	if ui_modal(ctx, s, id, Modal_Spec{
		title       = cfg.title,
		border      = cfg.border if cfg.border != .None else .Double,
		border_fg   = b_fg,
		title_fg    = t_fg,
		bg          = p_bg,
		fg          = p_fg,
		width       = w,
		height      = h,
		padding     = pad_xy(2, 1),
		gap         = 1,
		z_layer     = 20,
	}) {
		// 1. Message label
		ui_label(ctx, s, fmt.tprintf("%s_msg", id), cfg.message, p_fg)

		// 2. Button row
		if container(ctx, fmt.tprintf("%s_btn_row", id), Box_Config{
			dir        = .Row,
			width      = grow(1),
			height     = fixed(1),
			gap        = 2,
			main_align = .Center,
		}) {
			conf_flags: Focus_Flags = {.Focusable}
			canc_flags: Focus_Flags = {.Focusable}
			if cfg.default_confirm {
				conf_flags += {.Default_Focus}
			} else {
				canc_flags += {.Default_Focus}
			}

			ui_button(ctx, s, confirm_id, Button_Spec{
				label       = conf_lbl,
				fg          = rgb(255, 255, 255),
				bg          = rgb(40, 120, 200),
				focus_flags = conf_flags,
			})
			ui_button(ctx, s, cancel_id, Button_Spec{
				label       = canc_lbl,
				fg          = rgb(200, 210, 220),
				bg          = rgb(60, 70, 85),
				focus_flags = canc_flags,
			})
		}
	}

	// Interaction check
	if was_activated(inp, confirm_id) {
		return .Confirmed
	}
	if was_activated(inp, cancel_id) || was_modal_dismissed(inp, id) {
		return .Cancelled
	}
	return .Pending
}

ui_alert :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	cfg: Alert_Dialog_Config,
) -> bool {
	ok_id := fmt.tprintf("%s_btn_ok", id)

	w := cfg.width if cfg.width != nil else fit(min = 32)
	h := cfg.height if cfg.height != nil else fit(min = 6)
	ok_lbl := cfg.ok_label if len(cfg.ok_label) > 0 else "OK"

	b_fg := cfg.border_fg if cfg.border_fg.kind != .Default else rgb(120, 180, 240)
	t_fg := cfg.title_fg if cfg.title_fg.kind != .Default else rgb(140, 200, 255)
	p_bg := cfg.bg if cfg.bg.kind != .Default else rgb(24, 30, 42)
	p_fg := cfg.fg if cfg.fg.kind != .Default else rgb(220, 225, 235)

	if ui_modal(ctx, s, id, Modal_Spec{
		title     = cfg.title,
		border    = cfg.border if cfg.border != .None else .Double,
		border_fg = b_fg,
		title_fg  = t_fg,
		bg        = p_bg,
		fg        = p_fg,
		width     = w,
		height    = h,
		padding   = pad_xy(2, 1),
		gap       = 1,
		z_layer   = 20,
	}) {
		ui_label(ctx, s, fmt.tprintf("%s_msg", id), cfg.message, p_fg)
		if container(ctx, fmt.tprintf("%s_btn_row", id), Box_Config{
			dir        = .Row,
			width      = grow(1),
			height     = fixed(1),
			main_align = .Center,
		}) {
			ui_button(ctx, s, ok_id, Button_Spec{
				label       = ok_lbl,
				fg          = rgb(255, 255, 255),
				bg          = rgb(40, 120, 200),
				focus_flags = {.Focusable, .Default_Focus},
			})
		}
	}

	if was_activated(inp, ok_id) || was_modal_dismissed(inp, id) {
		return true
	}
	return false
}

ui_prompt :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	out_text: ^string,
	cfg: Prompt_Dialog_Config,
) -> Dialog_Result {
	input_id := fmt.tprintf("%s_input", id)
	ok_id    := fmt.tprintf("%s_btn_ok", id)
	canc_id  := fmt.tprintf("%s_btn_cancel", id)

	w := cfg.width if cfg.width != nil else fit(min = 40)
	h := cfg.height if cfg.height != nil else fit(min = 8)
	ok_lbl := cfg.ok_label if len(cfg.ok_label) > 0 else "OK"
	canc_lbl := cfg.cancel_label if len(cfg.cancel_label) > 0 else "Cancel"

	b_fg := cfg.border_fg if cfg.border_fg.kind != .Default else rgb(120, 180, 240)
	t_fg := cfg.title_fg if cfg.title_fg.kind != .Default else rgb(140, 200, 255)
	p_bg := cfg.bg if cfg.bg.kind != .Default else rgb(24, 30, 42)
	p_fg := cfg.fg if cfg.fg.kind != .Default else rgb(220, 225, 235)

	if ui_modal(ctx, s, id, Modal_Spec{
		title     = cfg.title,
		border    = cfg.border if cfg.border != .None else .Double,
		border_fg = b_fg,
		title_fg  = t_fg,
		bg        = p_bg,
		fg        = p_fg,
		width     = w,
		height    = h,
		padding   = pad_xy(2, 1),
		gap       = 1,
		z_layer   = 20,
	}) {
		ui_label(ctx, s, fmt.tprintf("%s_msg", id), cfg.message, p_fg)
		ui_text_input(ctx, s, inp, input_id, Text_Input_Config{
			placeholder = cfg.placeholder,
			width       = grow(1),
			height      = fixed(1),
			fg          = p_fg,
			bg          = rgb(35, 42, 56),
			focus_flags = {.Focusable, .Default_Focus},
		})
		if container(ctx, fmt.tprintf("%s_btn_row", id), Box_Config{
			dir        = .Row,
			width      = grow(1),
			height     = fixed(1),
			gap        = 2,
			main_align = .Center,
		}) {
			ui_button(ctx, s, ok_id, Button_Spec{
				label       = ok_lbl,
				fg          = rgb(255, 255, 255),
				bg          = rgb(40, 120, 200),
				focus_flags = {.Focusable},
			})
			ui_button(ctx, s, canc_id, Button_Spec{
				label       = canc_lbl,
				fg          = rgb(200, 210, 220),
				bg          = rgb(60, 70, 85),
				focus_flags = {.Focusable},
			})
		}
	}

	if was_activated(inp, canc_id) || was_modal_dismissed(inp, id) {
		set_text(inp, input_id, "")
		return .Cancelled
	}
	if was_activated(inp, ok_id) || was_activated(inp, input_id) || (is_focused(inp, input_id) && was_action_triggered(inp, "input.commit")) {
		if out_text != nil {
			out_text^ = strings.clone(get_text(inp, input_id), context.temp_allocator)
		}
		set_text(inp, input_id, "")
		return .Confirmed
	}
	return .Pending
}

// =============================================================================
// Floating Toast Notification System
// =============================================================================

toast_push :: proc(
	tm: ^Toast_Manager,
	title: string,
	message: string,
	severity: Toast_Severity = .Info,
	duration_ticks: i32 = 60,
) -> u64 {
	if tm == nil {
		return 0
	}
	tm.next_id += 1
	item := Toast_Item{
		id          = tm.next_id,
		severity    = severity,
		ticks_left  = duration_ticks,
		total_ticks = duration_ticks,
	}
	item.title_len, _ = copy_string_to_buf(item.title_buf[:], title)
	item.msg_len,   _ = copy_string_to_buf(item.msg_buf[:], message)
	if tm.count < MAX_TOASTS {
		tm.items[tm.count] = item
		tm.count += 1
	} else {
		for i := 0; i < MAX_TOASTS - 1; i += 1 {
			tm.items[i] = tm.items[i + 1]
		}
		tm.items[MAX_TOASTS - 1] = item
	}
	return tm.next_id
}

toast_update :: proc(tm: ^Toast_Manager, tick_delta: i32 = 1) {
	if tm == nil {
		return
	}
	write_idx := 0
	for i := 0; i < tm.count; i += 1 {
		tm.items[i].ticks_left -= tick_delta
		if tm.items[i].ticks_left > 0 {
			if write_idx != i {
				tm.items[write_idx] = tm.items[i]
			}
			write_idx += 1
		}
	}
	tm.count = write_idx
}

toast_dismiss :: proc(tm: ^Toast_Manager, id: u64) -> bool {
	if tm == nil {
		return false
	}
	for i := 0; i < tm.count; i += 1 {
		if tm.items[i].id == id {
			for j := i; j < tm.count - 1; j += 1 {
				tm.items[j] = tm.items[j + 1]
			}
			tm.count -= 1
			return true
		}
	}
	return false
}

ui_toast_stack :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	tm: ^Toast_Manager,
) {
	_ = inp
	if tm == nil || tm.count == 0 {
		return
	}

	toast_h: i32 = 3

	for i := 0; i < tm.count; i += 1 {
		item := &tm.items[i]
		title_str := toast_item_title(item)
		msg_str   := toast_item_message(item)
		toast_w   := clamp(max(string_display_width(title_str) + 6, string_display_width(msg_str) + 4), 32, 52)
		t_id := fmt.tprintf("toast_%d", item.id)
		id_h := hash_id(t_id)

		border_col: Color
		title_col: Color
		switch item.severity {
		case .Info:
			border_col = rgb(80, 180, 240)
			title_col  = rgb(120, 200, 255)
		case .Success:
			border_col = rgb(80, 220, 120)
			title_col  = rgb(120, 240, 160)
		case .Warning:
			border_col = rgb(255, 200, 40)
			title_col  = rgb(255, 220, 80)
		case .Error:
			border_col = rgb(255, 80, 80)
			title_col  = rgb(255, 120, 120)
		}

		// Calculate screen offset based on anchor and stacking index
		ox: i32 = -2
		oy: i32 = 1 + i32(i) * 4
		p_align: [2]Alignment = {.End, .Start}

		switch tm.anchor {
		case .Top_Right:
			p_align = {.End, .Start}
			ox = -2
			oy = 1 + i32(i) * 4
		case .Top_Left:
			p_align = {.Start, .Start}
			ox = 2
			oy = 1 + i32(i) * 4
		case .Bottom_Right:
			p_align = {.End, .End}
			ox = -2
			oy = -1 - i32(i) * 4
		case .Bottom_Left:
			p_align = {.Start, .End}
			ox = 2
			oy = -1 - i32(i) * 4
		}

		if s != nil {
			s.paints[id_h] = Paint_Spec{
				title       = title_str,
				text        = msg_str,
				fg          = rgb(220, 225, 235),
				bg          = rgb(26, 32, 44),
				border_fg   = border_col,
				title_fg    = title_col,
				title_style = {.Bold},
				fill_bg     = true,
			}
		}

		leaf(ctx, t_id, toast_w, toast_h, Box_Config{
			width       = fixed(toast_w),
			height      = fixed(toast_h),
			border      = .Rounded,
			floating    = true,
			anchor      = .Screen,
			self_align  = p_align,
			offset      = {ox, oy},
			z_layer     = 30,
			text        = msg_str,
			padding     = pad_xy(1, 0),
		})
	}
}

// =============================================================================
// Contextual Hover Tooltips
// =============================================================================

ui_tooltip :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	target_id: string,
	text: string,
	cfg: Tooltip_Config = {},
) -> bool {
	if !is_hovered(inp, target_id) || len(text) == 0 {
		return false
	}

	t_id := fmt.tprintf("%s_tooltip", target_id)
	id_h := hash_id(t_id)

	w := string_display_width(text) + 2
	h: i32 = 1
	if cfg.border != .None {
		w += 2
		h += 2
	}

	p_anchor: Anchor_Point = .Bottom_Left
	e_anchor: Anchor_Point = .Top_Left
	offset_y: i32 = 1

	if s != nil {
		eff_bg := cfg.bg if cfg.bg.kind != .Default else rgb(30, 36, 48)
		eff_fg := cfg.fg if cfg.fg.kind != .Default else rgb(240, 245, 255)
		eff_border_fg := cfg.border_fg if cfg.border_fg.kind != .Default else rgb(100, 120, 150)
		s.paints[id_h] = Paint_Spec{
			text      = text,
			fg        = eff_fg,
			bg        = eff_bg,
			border_fg = eff_border_fg,
			style     = cfg.style,
			fill_bg   = true,
		}
	}

	leaf(ctx, t_id, w, h, Box_Config{
		width            = fixed(w),
		height           = fixed(h),
		padding          = pad_xy(1, 0),
		border           = cfg.border,
		floating         = true,
		anchor           = .Parent,
		anchor_parent_id = target_id,
		parent_anchor    = p_anchor,
		element_anchor   = e_anchor,
		offset           = {0, offset_y},
		clamp_to_screen  = true,
		z_layer          = 25,
		text             = text,
	})
	return true
}
