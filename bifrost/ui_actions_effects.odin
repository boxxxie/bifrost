package bifrost

import "core:mem"
import "core:strings"
import actor "../deps/sleipnir/actor"

Cursor_Shape :: enum u8 {
	Default          = 0,
	Block_Blinking   = 1,
	Block_Steady     = 2,
	Underline_Blink  = 3,
	Underline_Steady = 4,
	Bar_Blinking     = 5,
	Bar_Steady       = 6,
}

UI_Effect_Request_Focus :: struct {
	widget_id:   string,
	widget_hash: u64,
}

UI_Effect_Copy_OSC52 :: struct {
	text_len: int,
	text_buf: [256]u8,
}

UI_Effect_Set_Title :: struct {
	title_len: int,
	title_buf: [128]u8,
}

UI_Effect_Set_Cursor_Shape :: struct {
	shape: Cursor_Shape,
}

UI_Effect_Request_Quit :: struct {}

UI_Side_Effect :: union {
	UI_Effect_Request_Focus,
	UI_Effect_Copy_OSC52,
	UI_Effect_Set_Title,
	UI_Effect_Set_Cursor_Shape,
	UI_Effect_Request_Quit,
}


// =============================================================================
// 6. Quit Filter, Pure Side-Effects & Sleipnir Actor Action Sinks
// =============================================================================

ui_set_quit_filter :: proc(
	coord: ^UI_Coordinator_State,
	filter_fn: UI_Quit_Filter_Fn,
	user_ptr: rawptr = nil,
) {
	if coord == nil {
		return
	}
	coord.quit_filter = filter_fn
	if user_ptr != nil {
		coord.user_ptr = user_ptr
	}
}

// Evaluates any installed Bubble-Tea-style `quit_filter` before setting `quit_requested = true`.
ui_request_quit :: proc(coord: ^UI_Coordinator_State) -> bool {
	if coord == nil {
		return false
	}
	if coord.quit_filter != nil && !coord.quit_filter(coord) {
		coord.dirty = true
		return false
	}
	coord.quit_requested = true
	coord.dirty          = true
	return true
}

ui_push_side_effect :: proc(coord: ^UI_Coordinator_State, effect: UI_Side_Effect) -> bool {
	if coord == nil || coord.side_effect_cnt >= MAX_UI_SIDE_EFFECTS {
		return false
	}
	coord.side_effects[coord.side_effect_cnt] = effect
	coord.side_effect_cnt += 1
	coord.dirty = true
	return true
}

ui_cmd_request_focus :: proc(coord: ^UI_Coordinator_State, widget_id: string) -> bool {
	return ui_push_side_effect(coord, UI_Effect_Request_Focus{
		widget_id   = widget_id,
		widget_hash = hash_id(widget_id),
	})
}

@(private)
copy_string_to_buf :: proc "contextless" (dst: []u8, src: string) -> (int, string) {
	n := min(len(src), len(dst))
	// Back up to a valid UTF-8 codepoint boundary if truncated mid-rune
	for n > 0 && n < len(src) && (src[n] & 0xc0) == 0x80 {
		n -= 1
	}
	if n > 0 {
		copy(dst[:n], transmute([]u8)src[:n])
	}
	return n, string(dst[:n])
}

ui_cmd_copy_osc52 :: proc(coord: ^UI_Coordinator_State, text: string) -> bool {
	eff: UI_Effect_Copy_OSC52
	eff.text_len, _ = copy_string_to_buf(eff.text_buf[:], text)
	return ui_push_side_effect(coord, eff)
}

ui_cmd_set_title :: proc(coord: ^UI_Coordinator_State, title: string) -> bool {
	eff: UI_Effect_Set_Title
	eff.title_len, _ = copy_string_to_buf(eff.title_buf[:], title)
	return ui_push_side_effect(coord, eff)
}

ui_cmd_set_cursor_shape :: proc(coord: ^UI_Coordinator_State, shape: Cursor_Shape) -> bool {
	return ui_push_side_effect(coord, UI_Effect_Set_Cursor_Shape{shape = shape})
}

ui_cmd_request_quit :: proc(coord: ^UI_Coordinator_State) -> bool {
	return ui_push_side_effect(coord, UI_Effect_Request_Quit{})
}

@(private)
write_base64_rfc4648 :: proc(out: ^strings.Builder, src: []u8) {
	alphabet := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	i := 0
	for i + 3 <= len(src) {
		b0 := u32(src[i])
		b1 := u32(src[i + 1])
		b2 := u32(src[i + 2])
		v := (b0 << 16) | (b1 << 8) | b2
		strings.write_byte(out, alphabet[(v >> 18) & 0x3F])
		strings.write_byte(out, alphabet[(v >> 12) & 0x3F])
		strings.write_byte(out, alphabet[(v >> 6) & 0x3F])
		strings.write_byte(out, alphabet[v & 0x3F])
		i += 3
	}
	rem := len(src) - i
	if rem == 1 {
		v := u32(src[i]) << 16
		strings.write_byte(out, alphabet[(v >> 18) & 0x3F])
		strings.write_byte(out, alphabet[(v >> 12) & 0x3F])
		strings.write_byte(out, '=')
		strings.write_byte(out, '=')
	} else if rem == 2 {
		v := (u32(src[i]) << 16) | (u32(src[i + 1]) << 8)
		strings.write_byte(out, alphabet[(v >> 18) & 0x3F])
		strings.write_byte(out, alphabet[(v >> 12) & 0x3F])
		strings.write_byte(out, alphabet[(v >> 6) & 0x3F])
		strings.write_byte(out, '=')
	}
}

// If `inp.osc52_pending` is set, encodes `inp.clipboard_buf[:inp.clipboard_len]` as an OSC 52
// clipboard escape sequence (`\x1b]52;c;<base64>\x07`) into `escape_out` and clears `inp.osc52_pending`.
flush_osc52_clipboard :: proc(inp: ^Input_State, escape_out: ^strings.Builder) -> bool {
	if inp == nil || !inp.osc52_pending {
		return false
	}
	inp.osc52_pending = false
	if escape_out == nil || inp.clipboard_len <= 0 {
		return false
	}
	strings.write_string(escape_out, "\x1b]52;c;")
	write_base64_rfc4648(escape_out, inp.clipboard_buf[:inp.clipboard_len])
	strings.write_byte(escape_out, '\x07')
	return true
}

@(private)
ui_drain_side_effects :: proc(state: ^UI_Coordinator_State, escape_out: ^strings.Builder) -> (focus_requested: bool) {
	if state.side_effect_cnt == 0 {
		return false
	}
	count := state.side_effect_cnt
	state.side_effect_cnt = 0
	for i := 0; i < count; i += 1 {
		eff := state.side_effects[i]
		switch e in eff {
		case UI_Effect_Request_Focus:
			if e.widget_hash != 0 {
				state.input.wants_focus_id = e.widget_hash
				focus_requested = true
			}
		case UI_Effect_Copy_OSC52:
			if escape_out != nil {
				local_buf := e.text_buf
				strings.write_string(escape_out, "\x1b]52;c;")
				write_base64_rfc4648(escape_out, local_buf[:e.text_len])
				strings.write_byte(escape_out, '\x07')
			}
		case UI_Effect_Set_Title:
			if escape_out != nil {
				strings.write_string(escape_out, "\x1b]2;")
				for b_idx := 0; b_idx < e.title_len; b_idx += 1 {
					ch := e.title_buf[b_idx]
					if ch >= 32 && ch != 0x7f {
						strings.write_byte(escape_out, ch)
					}
				}
				strings.write_byte(escape_out, '\x07')
			}
		case UI_Effect_Set_Cursor_Shape:
			if escape_out != nil {
				strings.write_string(escape_out, "\x1b[")
				strings.write_int(escape_out, int(e.shape))
				strings.write_string(escape_out, " q")
			}
		case UI_Effect_Request_Quit:
			_ = ui_request_quit(state)
		}
	}
	return focus_requested
}

@(private)
free_owned_sink_box :: proc(ptr: rawptr, alloc: mem.Allocator) {
	if ptr != nil {
		free(ptr, alloc)
	}
}

@(private)
register_action_sink_internal :: proc(
	coord: ^UI_Coordinator_State,
	action_name: string,
	dispatch_fn: UI_Action_Callback_Fn,
	userdata: rawptr = nil,
	owned_ptr: rawptr = nil,
	free_fn: proc(ptr: rawptr, alloc: mem.Allocator) = nil,
) -> bool {
	coord.action_sinks[coord.action_sink_cnt] = UI_Action_Sink{
		action_id   = hash_id(action_name),
		action_name = action_name,
		dispatch_fn = dispatch_fn,
		userdata    = userdata,
		owned_ptr   = owned_ptr,
		free_fn     = free_fn,
	}
	coord.action_sink_cnt += 1
	return true
}

// Registers a local UI callback invoked automatically whenever `action_name` fires.
on_ui_action :: proc(
	coord: ^UI_Coordinator_State,
	action_name: string,
	callback: UI_Action_Callback_Fn,
	userdata: rawptr = nil,
) -> bool {
	if coord == nil || len(action_name) == 0 || callback == nil || coord.action_sink_cnt >= MAX_UI_ACTION_SINKS {
		return false
	}
	return register_action_sink_internal(coord, action_name, callback, userdata)
}

// Maps activation (`Enter` / `Space` / Left-Click) of `widget_id` directly to `action_name`.
bind_button_action :: proc(
	coord: ^UI_Coordinator_State,
	widget_id: string,
	action_name: string,
) -> bool {
	if coord == nil || len(widget_id) == 0 || len(action_name) == 0 || coord.button_bind_cnt >= MAX_UI_BUTTON_BINDS {
		return false
	}
	w_hash := hash_id(widget_id)
	a_hash := hash_id(action_name)
	for i := 0; i < coord.button_bind_cnt; i += 1 {
		if coord.button_binds[i].widget_hash == w_hash {
			coord.button_binds[i].action_id   = a_hash
			coord.button_binds[i].action_name = action_name
			return true
		}
	}
	coord.button_binds[coord.button_bind_cnt] = UI_Button_Action_Binding{
		widget_hash = w_hash,
		action_id   = a_hash,
		action_name = action_name,
	}
	coord.button_bind_cnt += 1
	return true
}

@(private)
Actor_Static_Sink_Box :: struct($Msg: typeid) {
	pid:     actor.PID(Msg),
	payload: Msg,
}

@(private)
Actor_Batch_Static_Sink_Box :: struct($Msg: typeid) {
	pid:      actor.PID(Msg),
	payloads: []Msg,
}

@(private)
Actor_Dynamic_Sink_Box :: struct($Msg: typeid) {
	pid:        actor.PID(Msg),
	builder_fn: proc(coord: ^UI_Coordinator_State, userdata: rawptr) -> (Msg, bool),
	userdata:   rawptr,
}

@(private)
Actor_Batch_Dynamic_Sink_Box :: struct($Msg: typeid) {
	pid:        actor.PID(Msg),
	builder_fn: proc(coord: ^UI_Coordinator_State, userdata: rawptr, alloc: mem.Allocator) -> []Msg,
	userdata:   rawptr,
}

bind_actor_action :: proc {
	bind_actor_action_static,
	bind_actor_action_batch_static,
	bind_actor_action_dynamic,
	bind_actor_action_batch_dynamic,
}

bind_actor_action_static :: proc(
	coord: ^UI_Coordinator_State,
	action_name: string,
	target_pid: actor.PID($Msg),
	payload: Msg,
) -> bool {
	if coord == nil || len(action_name) == 0 || coord.action_sink_cnt >= MAX_UI_ACTION_SINKS {
		return false
	}
	box, err := new(Actor_Static_Sink_Box(Msg), coord.allocator)
	if err != nil {
		return false
	}
	box.pid     = target_pid
	box.payload = payload
	return register_action_sink_internal(
		coord,
		action_name,
		proc(_: ^UI_Coordinator_State, _: string, ud: rawptr) {
			b := (^Actor_Static_Sink_Box(Msg))(ud)
			if b != nil && b.pid.ref != nil {
				actor.send(b.pid, b.payload)
			}
		},
		box,
		box,
		free_owned_sink_box,
	)
}

bind_actor_action_batch_static :: proc(
	coord: ^UI_Coordinator_State,
	action_name: string,
	target_pid: actor.PID($Msg),
	payloads: []Msg,
) -> bool {
	if coord == nil || len(action_name) == 0 || len(payloads) == 0 || coord.action_sink_cnt >= MAX_UI_ACTION_SINKS {
		return false
	}
	cloned, c_err := make([]Msg, len(payloads), coord.allocator)
	if c_err != nil {
		return false
	}
	copy(cloned, payloads)

	box, b_err := new(Actor_Batch_Static_Sink_Box(Msg), coord.allocator)
	if b_err != nil {
		delete(cloned, coord.allocator)
		return false
	}
	box.pid      = target_pid
	box.payloads = cloned
	return register_action_sink_internal(
		coord,
		action_name,
		proc(_: ^UI_Coordinator_State, _: string, ud: rawptr) {
			b := (^Actor_Batch_Static_Sink_Box(Msg))(ud)
			if b != nil && b.pid.ref != nil && len(b.payloads) > 0 {
				actor.send(b.pid, b.payloads)
			}
		},
		box,
		box,
		proc(ptr: rawptr, alloc: mem.Allocator) {
			if ptr != nil {
				b := (^Actor_Batch_Static_Sink_Box(Msg))(ptr)
				delete(b.payloads, alloc)
				free(b, alloc)
			}
		},
	)
}

bind_actor_action_dynamic :: proc(
	coord: ^UI_Coordinator_State,
	action_name: string,
	target_pid: actor.PID($Msg),
	builder_fn: proc(coord: ^UI_Coordinator_State, userdata: rawptr) -> (Msg, bool),
	userdata: rawptr = nil,
) -> bool {
	if coord == nil || len(action_name) == 0 || builder_fn == nil || coord.action_sink_cnt >= MAX_UI_ACTION_SINKS {
		return false
	}
	box, err := new(Actor_Dynamic_Sink_Box(Msg), coord.allocator)
	if err != nil {
		return false
	}
	box.pid        = target_pid
	box.builder_fn = builder_fn
	box.userdata   = userdata
	return register_action_sink_internal(
		coord,
		action_name,
		proc(c: ^UI_Coordinator_State, _: string, ud: rawptr) {
			b := (^Actor_Dynamic_Sink_Box(Msg))(ud)
			if b != nil && b.pid.ref != nil && b.builder_fn != nil {
				if msg, ok := b.builder_fn(c, b.userdata); ok {
					actor.send(b.pid, msg)
				}
			}
		},
		box,
		box,
		free_owned_sink_box,
	)
}

bind_actor_action_batch_dynamic :: proc(
	coord: ^UI_Coordinator_State,
	action_name: string,
	target_pid: actor.PID($Msg),
	builder_fn: proc(coord: ^UI_Coordinator_State, userdata: rawptr, alloc: mem.Allocator) -> []Msg,
	userdata: rawptr = nil,
) -> bool {
	if coord == nil || len(action_name) == 0 || builder_fn == nil || coord.action_sink_cnt >= MAX_UI_ACTION_SINKS {
		return false
	}
	box, err := new(Actor_Batch_Dynamic_Sink_Box(Msg), coord.allocator)
	if err != nil {
		return false
	}
	box.pid        = target_pid
	box.builder_fn = builder_fn
	box.userdata   = userdata
	return register_action_sink_internal(
		coord,
		action_name,
		proc(c: ^UI_Coordinator_State, _: string, ud: rawptr) {
			b := (^Actor_Batch_Dynamic_Sink_Box(Msg))(ud)
			if b != nil && b.pid.ref != nil && b.builder_fn != nil {
				msgs := b.builder_fn(c, b.userdata, context.temp_allocator)
				if len(msgs) > 0 {
					actor.send(b.pid, msgs)
				}
			}
		},
		box,
		box,
		free_owned_sink_box,
	)
}

