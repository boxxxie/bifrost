package bifrost

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import actor "../deps/sleipnir/actor"
import xitdb "../deps/xitdb/xitdb"

// =============================================================================
// 1. Actor Runtime Alias & Frame-Pacing Constants
// =============================================================================

Actor_System :: actor.Scheduler

DEFAULT_FRAME_INTERVAL     :: 16 * time.Millisecond
DEFAULT_MIN_FRAME_DURATION :: 4 * time.Millisecond
DEFAULT_MAX_COALESCE_BATCH :: 2048
DEFAULT_SCROLL_OVERSCAN    :: 4

is_plausible_window_size :: #force_inline proc "contextless" (cols, rows: int) -> bool {
	return cols >= 2 && cols <= 1024 && rows >= 2 && rows <= 512
}

// =============================================================================
// 2. Typed UI & Worker Actor Messages (Elm / Bubble Tea Architecture)
// =============================================================================

UI_Cmd :: #type proc(alloc: mem.Allocator) -> (msg: UI_Msg, has_msg: bool)

UI_Msg_Key :: struct {
	code:      Key_Code,
	ch:        rune,
	ctrl:      bool,
	alt:       bool,
	shift:     bool,
	super_mod: bool,
	is_repeat: bool,
}

UI_Msg_Mouse :: struct {
	x:      i32,
	y:      i32,
	button: u8,
	action: Mouse_Action,
	ctrl:   bool,
	alt:    bool,
	shift:  bool,
}

UI_Msg_Input :: struct {
	event: Input_Event,
}

UI_Msg_Resize :: struct {
	cols: u16,
	rows: u16,
}

// Sent by background `sleipnir` worker actors after committing an `xitdb` transaction.
UI_Msg_Commit_Notification :: struct {
	moment_idx: i64,
	slot_ptr:   i64,
	tx_id:      i64,
	tag_name:   string,
}

UI_Msg_State_Committed :: UI_Msg_Commit_Notification

UI_Msg_Select_Moment :: struct {
	moment_idx: i64,
	pin:        bool,
}

UI_Msg_Scroll_Viewport :: struct {
	delta_rows:  int,
	page_scroll: bool,
}

UI_Msg_Search_Input :: struct {
	query: string,
}

UI_Msg_Palette_Toggle :: struct {
	open: bool,
}

UI_Msg_Datalog_Ready :: struct {
	row_count:   int,
	col_count:   int,
	summary:     string,
	summary_buf: [128]u8,
	summary_len: int,
}

UI_Msg_Diff_Ready :: struct {
	from_moment: i64,
	to_moment:   i64,
	added:       int,
	modified:    int,
	removed:     int,
}

UI_Msg_Batch :: struct {
	msgs: []UI_Msg,
}

UI_Msg_Sequence :: struct {
	cmds: []UI_Cmd,
}

UI_Msg_Frame_Tick :: struct {
	tick_ns: i64,
}

UI_Msg_Quit :: struct {}

UI_Msg :: union {
	UI_Msg_Key,
	UI_Msg_Mouse,
	UI_Msg_Input,
	UI_Msg_Resize,
	UI_Msg_Commit_Notification,
	UI_Msg_Select_Moment,
	UI_Msg_Scroll_Viewport,
	UI_Msg_Search_Input,
	UI_Msg_Palette_Toggle,
	UI_Msg_Datalog_Ready,
	UI_Msg_Diff_Ready,
	UI_Msg_Batch,
	UI_Msg_Sequence,
	UI_Msg_Frame_Tick,
	UI_Msg_Quit,
}

ui_batch_cmds :: proc(
	ui_pid: actor.PID(UI_Msg),
	cmds: []UI_Cmd,
	alloc := context.temp_allocator,
) {
	if len(cmds) == 0 {
		return
	}
	msgs := make([dynamic]UI_Msg, 0, len(cmds), alloc)
	for cmd in cmds {
		if cmd == nil {
			continue
		}
		if msg, ok := cmd(alloc); ok {
			append(&msgs, msg)
		}
	}
	if len(msgs) == 1 {
		actor.send(ui_pid, msgs[0])
	} else if len(msgs) > 1 {
		actor.send(ui_pid, UI_Msg(UI_Msg_Batch{msgs = msgs[:]}))
	}
}

// =============================================================================
// 3. Background xitdb Worker Actor (`Xitdb_Worker_State` & `Xitdb_Worker_Msg`)
// =============================================================================

Xitdb_Shared_Handle :: struct {
	rw_lock: sync.RW_Mutex,
	db:      ^xitdb.Database,
}

Worker_Msg_Transact_Script :: struct {
	script:   string,
	tag_name: string,
}

Worker_Msg_Commit_Batch :: struct {
	map_name:   string,
	key_prefix: string,
	start_id:   int,
	count:      int,
	sorted:     bool,
	tag_name:   string,
}

Worker_Msg_Run_Datalog :: struct {
	query_source: string,
}

Worker_Msg_Diff_Moments :: struct {
	moment_a: i64,
	moment_b: i64,
}

Worker_Msg_Ping_Count :: struct {}

Xitdb_Worker_Msg :: union {
	Worker_Msg_Transact_Script,
	Worker_Msg_Commit_Batch,
	Worker_Msg_Run_Datalog,
	Worker_Msg_Diff_Moments,
	Worker_Msg_Ping_Count,
}

Xitdb_Worker_State :: struct {
	shared:        ^Xitdb_Shared_Handle,
	ui_pid:        actor.PID(UI_Msg),
	commits_done:  int,
	queries_done:  int,
	diffs_done:    int,
	last_error_ok: bool,
}

xitdb_worker_receive :: proc(
	ctx: ^actor.Context,
	self: ^actor.Actor(Xitdb_Worker_State, Xitdb_Worker_Msg),
	msg: ^Xitdb_Worker_Msg,
) {
	state := &self.state
	if state.shared == nil || state.shared.db == nil || msg == nil {
		return
	}

	switch m in msg^ {
	case Worker_Msg_Transact_Script:
		sync.rw_mutex_lock(&state.shared.rw_lock)
		report, t_err := xitdb.transact_script(state.shared.db, m.script, context.temp_allocator)
		latest_idx := report.moment_index
		slot_val: i64 = 0
		if t_err == nil {
			if slot, s_err := xitdb.cursor_slot(report.after.cursor); s_err == nil {
				slot_val = slot.value
			}
		}
		sync.rw_mutex_unlock(&state.shared.rw_lock)

		if t_err == nil {
			state.commits_done += 1
			state.last_error_ok = true
			if state.ui_pid.ref != nil {
				actor.send(
					ctx,
					state.ui_pid,
					UI_Msg(UI_Msg_Commit_Notification{
						moment_idx = latest_idx,
						slot_ptr   = slot_val,
						tx_id      = latest_idx + 1,
						tag_name   = m.tag_name,
					}),
				)
			}
		}

	case Worker_Msg_Commit_Batch:
		sync.rw_mutex_lock(&state.shared.rw_lock)
		tx := xitdb.tx_init(state.shared.db, -1, false, context.temp_allocator)
		if len(m.tag_name) > 0 {
			xitdb.tx_doc(&tx, m.tag_name)
		}
		use_sorted := m.sorted || strings.has_prefix(m.map_name, "$")
		use_counted := strings.has_prefix(m.map_name, "#")
		clean_map := strings.trim_left(m.map_name, ".#$")
		if len(clean_map) == 0 {
			clean_map = "records"
		}
		map_step := xitdb.hm(clean_map)

		for i := 0; i < m.count; i += 1 {
			id := m.start_id + i
			k_str := fmt.aprintf("%s:%06d", m.key_prefix, id, allocator = context.temp_allocator)
			v_str := fmt.aprintf("val_%d", id, allocator = context.temp_allocator)
			key_step := xitdb.hm(k_str)
			if use_sorted {
				key_step = xitdb.sm(k_str)
			} else if use_counted {
				key_step = xitdb.chm(k_str)
			}
			steps := [2]xitdb.Path_Step{map_step, key_step}
			xitdb.tx_put_steps(&tx, steps[:], v_str)
		}
		report, c_err := xitdb.tx_commit(&tx)
		latest_idx := report.moment_index
		slot_val: i64 = 0
		if c_err == nil {
			if slot, s_err := xitdb.cursor_slot(report.after.cursor); s_err == nil {
				slot_val = slot.value
			}
		}
		sync.rw_mutex_unlock(&state.shared.rw_lock)

		if c_err == nil {
			state.commits_done += 1
			state.last_error_ok = true
			if state.ui_pid.ref != nil {
				actor.send(
					ctx,
					state.ui_pid,
					UI_Msg(UI_Msg_Commit_Notification{
						moment_idx = latest_idx,
						slot_ptr   = slot_val,
						tx_id      = latest_idx + 1,
						tag_name   = m.tag_name,
					}),
				)
			}
		}

	case Worker_Msg_Run_Datalog:
		sync.rw_mutex_shared_lock(&state.shared.rw_lock)
		res, q_err := xitdb.query_datalog(
			state.shared.db,
			m.query_source,
			-1,
			context.temp_allocator,
		)
		row_count := len(res.rows)
		col_count := len(res.vars)
		sync.rw_mutex_shared_unlock(&state.shared.rw_lock)

		if q_err == nil {
			state.queries_done += 1
			ready := UI_Msg_Datalog_Ready{
				row_count = row_count,
				col_count = col_count,
			}
			formatted := fmt.bprintf(ready.summary_buf[:], "datalog rows=%d cols=%d", row_count, col_count)
			ready.summary_len = len(formatted)
			if state.ui_pid.ref != nil {
				actor.send(ctx, state.ui_pid, UI_Msg(ready))
			}
		}

	case Worker_Msg_Diff_Moments:
		sync.rw_mutex_shared_lock(&state.shared.rw_lock)
		entries, d_err := xitdb.diff_moments(
			state.shared.db,
			m.moment_a,
			m.moment_b,
			false,
			context.temp_allocator,
		)
		added, modified, removed := 0, 0, 0
		if d_err == nil {
			for e in entries {
				#partial switch e.op {
				case .Remove:
					removed += 1
				case .Put, .Append, .Insert:
					if e.old_slot.tag == .None {
						added += 1
					} else {
						modified += 1
					}
				case .Slice:
					modified += 1
				}
			}
		}
		sync.rw_mutex_shared_unlock(&state.shared.rw_lock)

		if d_err == nil {
			state.diffs_done += 1
			if state.ui_pid.ref != nil {
				actor.send(
					ctx,
					state.ui_pid,
					UI_Msg(UI_Msg_Diff_Ready{
						from_moment = m.moment_a,
						to_moment   = m.moment_b,
						added       = added,
						modified    = modified,
						removed     = removed,
					}),
				)
			}
		}

	case Worker_Msg_Ping_Count:
		sync.rw_mutex_shared_lock(&state.shared.rw_lock)
		rc := xitdb.database_root_cursor(state.shared.db)
		cnt, _ := xitdb.cursor_count(rc.read_cursor)
		sync.rw_mutex_shared_unlock(&state.shared.rw_lock)
		actor.reply(ctx, cnt)
	}
}

// =============================================================================
// 4. Zero-Copy xitdb Viewport Slicing (O(log_16 N) B+Tree / Hash / Array Seek)
// =============================================================================

Xitdb_Row_View :: struct {
	logical_index: i64,
	key_text:      string,
	val_text:      string,
	tag:           xitdb.Tag,
	slot_offset:   i64,
}

Xitdb_Viewport_Slice :: struct {
	moment_idx:     i64,
	collection_key: string,
	total_rows:     i64,
	start_row:      i64,
	rows:           []Xitdb_Row_View,
}

UI_Virtual_List :: struct {
	scroll_offset: int,
	selected_row:  int,
	viewport_rows: int,
	overscan:      int,
	total_rows:    int,
}

ui_virtual_list_clamp :: proc(v: ^UI_Virtual_List) {
	if v.viewport_rows < 1 {
		v.viewport_rows = 1
	}
	if v.total_rows <= 0 {
		v.selected_row = 0
		v.scroll_offset = 0
		return
	}
	v.selected_row = clamp(v.selected_row, 0, v.total_rows - 1)
	if v.selected_row < v.scroll_offset {
		v.scroll_offset = v.selected_row
	} else if v.selected_row >= v.scroll_offset + v.viewport_rows {
		v.scroll_offset = v.selected_row - v.viewport_rows + 1
	}
	max_scroll := max(0, v.total_rows - v.viewport_rows)
	v.scroll_offset = clamp(v.scroll_offset, 0, max_scroll)
}

ui_virtual_list_move :: proc(v: ^UI_Virtual_List, delta: int) {
	v.selected_row += delta
	ui_virtual_list_clamp(v)
}

// Resolve a moment cursor at `moment_idx` (-1 = latest, >= 0 = pinned historical index).
xitdb_open_moment_cursor :: proc(
	db: ^xitdb.Database,
	moment_idx: i64,
) -> (
	moment_cur: xitdb.Read_Cursor,
	resolved_idx: i64,
	err: xitdb.Error,
) {
	rc := xitdb.database_root_cursor(db).read_cursor
	history := xitdb.read_array_list_init(rc) or_return
	total_moments := xitdb.array_list_count(history) or_return
	if total_moments <= 0 {
		return {}, 0, .Key_Not_Found
	}
	idx := moment_idx
	if idx < 0 || idx >= total_moments {
		idx = total_moments - 1
	}
	mc_maybe := xitdb.array_list_get_cursor(history, idx) or_return
	mc, ok := mc_maybe.?
	if !ok {
		return {}, idx, .Key_Not_Found
	}
	return mc, idx, nil
}

@(private = "file")
resolve_collection_cursor :: proc(
	moment_cur: xitdb.Read_Cursor,
	collection_name: string,
) -> (
	coll_cur: xitdb.Read_Cursor,
	err: xitdb.Error,
) {
	if len(collection_name) == 0 {
		return moment_cur, nil
	}
	// First check if a bare top-level key (stripping leading '.', '$', '#') exists in the moment Hash_Map
	clean_top := strings.trim_left(collection_name, ".#$")
	if len(clean_top) > 0 && !strings.contains_any(clean_top, ".#$[") {
		hm := xitdb.read_hash_map_init(moment_cur) or_return
		c_maybe := xitdb.hash_map_get_cursor(hm, clean_top) or_return
		if c, ok := c_maybe.?; ok {
			return c, nil
		}
	}
	if collection_name[0] == '.' || collection_name[0] == '$' || collection_name[0] == '#' || collection_name[0] == '[' {
		steps := xitdb.parse_steps(collection_name, context.temp_allocator) or_return
		c_maybe := xitdb.read_steps_cursor(moment_cur, steps) or_return
		if c, ok := c_maybe.?; ok {
			return c, nil
		}
		return {}, .Key_Not_Found
	}
	hm := xitdb.read_hash_map_init(moment_cur) or_return
	c_maybe := xitdb.hash_map_get_cursor(hm, collection_name) or_return
	if c, ok := c_maybe.?; ok {
		return c, nil
	}
	return {}, .Key_Not_Found
}

// Read collection count at a moment in O(1) header time (or fallback scan for uncounted Hash_Map).
xitdb_read_collection_count :: proc(
	db: ^xitdb.Database,
	moment_idx: i64,
	collection_name: string,
) -> (
	count: i64,
	err: xitdb.Error,
) {
	moment_cur, _, m_err := xitdb_open_moment_cursor(db, moment_idx)
	if m_err != nil {
		return 0, m_err
	}
	coll_cur := resolve_collection_cursor(moment_cur, collection_name) or_return
	slot := xitdb.cursor_slot(coll_cur) or_return
	if slot.tag == .Hash_Map || slot.tag == .Hash_Set {
		it := xitdb.cursor_iterator(coll_cur) or_return
		n: i64 = 0
		key_buf: [256]u8
		for {
			c_maybe := xitdb.cursor_iterator_next(&it) or_return
			c, has_c := c_maybe.?
			if !has_c {
				break
			}
			if len(collection_name) == 0 {
				kv, kv_err := xitdb.cursor_read_kv_pair(c, context.temp_allocator)
				if kv_err == nil {
					b_res, _ := xitdb.cursor_read_bytes_buf(kv.key_cursor, key_buf[:])
					if string(b_res.value) == "__tx" {
						continue
					}
				}
			}
			n += 1
		}
		return n, nil
	}
	return xitdb.cursor_count(coll_cur)
}

// Format a preview string for any `xitdb.Read_Cursor` onto `alloc` (default `context.temp_allocator`).
xitdb_format_cursor_preview :: proc(
	cur: xitdb.Read_Cursor,
	alloc := context.temp_allocator,
) -> string {
	slot, s_err := xitdb.cursor_slot(cur)
	if s_err != nil {
		return "<err>"
	}
	#partial switch slot.tag {
	case .None:
		return "nil"
	case .Bytes, .Short_Bytes:
		stack_buf: [256]u8
		raw, err := xitdb.cursor_read_bytes_buf(cur, stack_buf[:])
		if err != nil {
			return "<bytes:err>"
		}
		return strings.clone(string(raw.value), alloc)
	case .Uint:
		v, _ := xitdb.cursor_read_uint(cur)
		return fmt.aprintf("%d", v, allocator = alloc)
	case .Int:
		v, _ := xitdb.cursor_read_int(cur)
		return fmt.aprintf("%d", v, allocator = alloc)
	case .Float:
		v, _ := xitdb.cursor_read_float(cur)
		return fmt.aprintf("%.4f", v, allocator = alloc)
	case .Array_List, .Linked_Array_List:
		cnt, _ := xitdb.cursor_count(cur)
		return fmt.aprintf("[%d items]", cnt, allocator = alloc)
	case .Hash_Map:
		return "{map}"
	case .Counted_Hash_Map, .Sorted_Map:
		cnt, _ := xitdb.cursor_count(cur)
		return fmt.aprintf("{%d entries}", cnt, allocator = alloc)
	case .Hash_Set:
		return "#{set}"
	case .Counted_Hash_Set, .Sorted_Set:
		cnt, _ := xitdb.cursor_count(cur)
		return fmt.aprintf("#{%d members}", cnt, allocator = alloc)
	}
	return "<slot>"
}

// Zero-copy O(log_16 N) viewport slicer: only materializes rows in `[start_row ..< start_row + visible_rows]`.
xitdb_slice_viewport :: proc(
	db: ^xitdb.Database,
	moment_idx: i64,
	collection_name: string,
	start_row: i64,
	visible_rows: i64,
	filter: Xitdb_Filter = {},
	alloc := context.temp_allocator,
) -> (
	slice: Xitdb_Viewport_Slice,
	err: xitdb.Error,
) {
	moment_cur, resolved_idx, m_err := xitdb_open_moment_cursor(db, moment_idx)
	if m_err != nil {
		return {}, m_err
	}

	target_cur := resolve_collection_cursor(moment_cur, collection_name) or_return
	target_slot := xitdb.cursor_slot(target_cur) or_return
	coll_tag := target_slot.tag

	total_count: i64 = 0
	if coll_tag != .Hash_Map && coll_tag != .Hash_Set {
		total_count = xitdb.cursor_count(target_cur) or_return
	}
	clamped_start := max(i64(0), start_row)
	if total_count > 0 && clamped_start > total_count {
		clamped_start = total_count
	}
	max_fetch := max(i64(0), visible_rows)

	rows := make([dynamic]Xitdb_Row_View, 0, int(max_fetch), alloc)

	#partial switch coll_tag {
	case .Array_List:
		it := xitdb.cursor_iterator_array_list_from_index(target_cur, clamped_start) or_return
		row_idx := clamped_start
		for i: i64 = 0; i < max_fetch; {
			item_maybe := xitdb.cursor_iterator_next(&it) or_return
			item_cur, has_item := item_maybe.?
			if !has_item {
				break
			}
			item_slot, _ := xitdb.cursor_slot(item_cur)
			val_str := xitdb_format_cursor_preview(item_cur, alloc)
			key_str := fmt.aprintf("[%d]", row_idx, allocator = alloc)
			if filter.kind == .Substring && len(filter.needle) > 0 {
				if !strings.contains(val_str, filter.needle) && !strings.contains(key_str, filter.needle) {
					row_idx += 1
					continue
				}
			}
			append(&rows, Xitdb_Row_View{
				logical_index = row_idx,
				key_text      = key_str,
				val_text      = val_str,
				tag           = item_slot.tag,
				slot_offset   = item_slot.value,
			})
			row_idx += 1
			i += 1
		}

	case .Linked_Array_List:
		it := xitdb.cursor_iterator_linked_array_list_from_index(target_cur, clamped_start) or_return
		row_idx := clamped_start
		for i: i64 = 0; i < max_fetch; {
			item_maybe := xitdb.cursor_iterator_next(&it) or_return
			item_cur, has_item := item_maybe.?
			if !has_item {
				break
			}
			item_slot, _ := xitdb.cursor_slot(item_cur)
			val_str := xitdb_format_cursor_preview(item_cur, alloc)
			key_str := fmt.aprintf("[%d]", row_idx, allocator = alloc)
			if filter.kind == .Substring && len(filter.needle) > 0 {
				if !strings.contains(val_str, filter.needle) && !strings.contains(key_str, filter.needle) {
					row_idx += 1
					continue
				}
			}
			append(&rows, Xitdb_Row_View{
				logical_index = row_idx,
				key_text      = key_str,
				val_text      = val_str,
				tag           = item_slot.tag,
				slot_offset   = item_slot.value,
			})
			row_idx += 1
			i += 1
		}

	case .Sorted_Map, .Sorted_Set:
		it: xitdb.Cursor_Iterator
		row_idx := clamped_start
		if filter.kind == .Key_Prefix && len(filter.prefix) > 0 {
			it = xitdb.cursor_iterator_sorted_from_key(target_cur, transmute([]u8)filter.prefix) or_return
			row_idx = it.index + clamped_start
			for skip: i64 = 0; skip < clamped_start; skip += 1 {
				step_maybe := xitdb.cursor_iterator_next(&it) or_return
				if _, ok := step_maybe.?; !ok {
					break
				}
			}
		} else if filter.kind == .Key_Range && len(filter.lower_key) > 0 {
			it = xitdb.cursor_iterator_sorted_from_key(target_cur, transmute([]u8)filter.lower_key) or_return
			row_idx = it.index + clamped_start
			for skip: i64 = 0; skip < clamped_start; skip += 1 {
				step_maybe := xitdb.cursor_iterator_next(&it) or_return
				if _, ok := step_maybe.?; !ok {
					break
				}
			}
		} else {
			it = xitdb.cursor_iterator_sorted_from_index(target_cur, clamped_start) or_return
		}

		key_buf: [256]u8
		for i: i64 = 0; i < max_fetch; {
			kv_maybe := xitdb.cursor_iterator_next(&it) or_return
			kv_cur, has_kv := kv_maybe.?
			if !has_kv {
				break
			}
			kv_pair, kv_err := xitdb.cursor_read_kv_pair(kv_cur, context.temp_allocator)
			if kv_err != nil {
				row_idx += 1
				continue
			}
			k_raw, _ := xitdb.cursor_read_bytes_buf(kv_pair.key_cursor, key_buf[:])
			k_str := string(k_raw.value)

			if filter.hide_tx && (k_str == "_tx" || k_str == "__tx") {
				row_idx += 1
				continue
			}
			if filter.kind == .Key_Prefix && len(filter.prefix) > 0 {
				if !strings.has_prefix(k_str, filter.prefix) {
					break
				}
			}
			if filter.kind == .Key_Range && len(filter.upper_key) > 0 {
				if k_str > filter.upper_key {
					break
				}
			}

			val_str := xitdb_format_cursor_preview(kv_pair.value_cursor, alloc)
			if filter.kind == .Substring && len(filter.needle) > 0 {
				if !strings.contains(k_str, filter.needle) && !strings.contains(val_str, filter.needle) {
					row_idx += 1
					continue
				}
			}

			val_slot, _ := xitdb.cursor_slot(kv_pair.value_cursor)
			append(&rows, Xitdb_Row_View{
				logical_index = row_idx,
				key_text      = strings.clone(k_str, alloc),
				val_text      = val_str,
				tag           = val_slot.tag,
				slot_offset   = val_slot.value,
			})
			row_idx += 1
			i += 1
		}

	case:
		it := xitdb.cursor_iterator(target_cur) or_return
		row_idx: i64 = 0
		key_buf: [256]u8
		for {
			kv_maybe := xitdb.cursor_iterator_next(&it) or_return
			kv_cur, has_kv := kv_maybe.?
			if !has_kv {
				break
			}
			kv_pair, kv_err := xitdb.cursor_read_kv_pair(kv_cur, context.temp_allocator)
			if kv_err != nil {
				continue
			}
			k_raw, _ := xitdb.cursor_read_bytes_buf(kv_pair.key_cursor, key_buf[:])
			k_str := string(k_raw.value)
			if filter.hide_tx && (k_str == "_tx" || k_str == "__tx") {
				continue
			}
			if filter.kind == .Key_Prefix && len(filter.prefix) > 0 {
				if !strings.has_prefix(k_str, filter.prefix) {
					continue
				}
			}
			val_str := xitdb_format_cursor_preview(kv_pair.value_cursor, alloc)
			if filter.kind == .Substring && len(filter.needle) > 0 {
				if !strings.contains(k_str, filter.needle) && !strings.contains(val_str, filter.needle) {
					continue
				}
			}
			if row_idx >= clamped_start && i64(len(rows)) < max_fetch {
				val_slot, _ := xitdb.cursor_slot(kv_pair.value_cursor)
				append(&rows, Xitdb_Row_View{
					logical_index = row_idx,
					key_text      = strings.clone(k_str, alloc),
					val_text      = val_str,
					tag           = val_slot.tag,
					slot_offset   = val_slot.value,
				})
			}
			row_idx += 1
		}
		if total_count == 0 {
			total_count = row_idx
		}
	}

	return Xitdb_Viewport_Slice{
		moment_idx     = resolved_idx,
		collection_key = collection_name,
		total_rows     = total_count,
		start_row      = clamped_start,
		rows           = rows[:],
	}, nil
}

// =============================================================================
// 5. UI Coordinator Actor (Mailbox Burst Coalescing & Immediate-Mode Frame Gate)
// =============================================================================

UI_Fast_Event :: union {
	UI_Msg_Key,
	UI_Msg_Mouse,
}

UI_Render_Pass_Fn :: #type proc(coord: ^UI_Coordinator_State)

UI_Coordinator_State :: struct {
	allocator:            mem.Allocator,
	shared_db:            ^Xitdb_Shared_Handle,

	// Bifrost Immediate-Mode Rendering & Widget Pipeline
	screen:               Screen,
	layout_ctx:           Layout_Context,
	input:                Input_State,
	state_store:          Widget_State_Store,
	palette:              Command_Palette,
	pending_inputs:       [dynamic]Input_Event,
	use_widget_pipeline:  bool,

	// Cell-buffer aliases into `screen.front` / `screen.back`
	cols:                 int,
	rows:                 int,
	front_buf:            []Cell,
	back_buf:             []Cell,
	ansi_builder:         strings.Builder,
	last_diff_cells:      int,
	last_ansi_bytes:      int,

	// Frame-Pacing & Mailbox Coalescing State
	dirty:                bool,
	urgent_input:         bool,
	quit_requested:       bool,
	render_on_drain:      bool,
	last_frame_tick:      time.Tick,
	frame_interval:       time.Duration,
	min_frame_duration:   time.Duration,
	max_coalesce_batch:   int,
	batch_drained:        int,
	total_msgs_processed: int,
	total_frames:         int,
	coalesced_commits:    int,

	// Snapshot & Time-Travel State
	latest_moment_idx:    i64,
	latest_slot_ptr:      i64,
	latest_tx_id:         i64,
	pinned_moment:        bool,
	active_moment_idx:    i64,
	active_collection:    string,

	// Widget & Viewport State
	vlist:                UI_Virtual_List,
	filter:               Xitdb_Filter,
	search_buf:           [128]u8,
	search_len:           int,
	palette_open:         bool,
	palette_selected:     int,
	last_datalog_buf:     [128]u8,
	last_datalog_len:     int,
	last_datalog_summary: string,
	last_diff_summary:    UI_Msg_Diff_Ready,
	last_viewport_rows:   int,

	// Optional Sharded SPSC Fast-Path Mailbox for Dedicated Terminal Reader
	spsc_mailbox:         ^actor.Sharded_SPSC_Mailbox(UI_Fast_Event),

	// Immediate-Mode Render Callback
	render_pass:          UI_Render_Pass_Fn,
}

ui_coordinator_init :: proc(
	coord: ^UI_Coordinator_State,
	cols, rows: int,
	shared_db: ^Xitdb_Shared_Handle,
	render_pass: UI_Render_Pass_Fn = nil,
	allocator := context.allocator,
) -> bool {
	if coord == nil {
		return false
	}
	w := max(cols, 2)
	h := max(rows, 2)

	coord.allocator = allocator
	coord.shared_db = shared_db
	if screen_init(&coord.screen, i32(w), i32(h), allocator) != nil {
		return false
	}
	if state_store_init(&coord.state_store, allocator) != nil {
		screen_destroy(&coord.screen)
		return false
	}
	if xitdb_filter_init(&coord.filter, allocator) != nil {
		state_store_destroy(&coord.state_store)
		screen_destroy(&coord.screen)
		return false
	}
	pending_inputs, p_err := make([dynamic]Input_Event, 0, 64, allocator)
	if p_err != nil {
		xitdb_filter_destroy(&coord.filter)
		state_store_destroy(&coord.state_store)
		screen_destroy(&coord.screen)
		return false
	}
	coord.pending_inputs = pending_inputs

	command_palette_init(&coord.palette, &coord.input)
	register_command(&coord.palette, "moment.follow", "Follow Latest Moment (Unpin)", "Time Travel", "f")
	register_command(&coord.palette, "moment.prev", "Step Backward One Moment", "Time Travel", "[")
	register_command(&coord.palette, "moment.next", "Step Forward One Moment", "Time Travel", "]")
	register_command(&coord.palette, "query.datalog", "Execute Datalog Audit Query", "Analytics", "Ctrl+D")
	register_command(&coord.palette, "query.diff", "Diff Pinned vs Latest Moment", "Analytics", "Ctrl+G")

	coord.cols               = w
	coord.rows               = h
	coord.front_buf          = coord.screen.front
	coord.back_buf           = coord.screen.back
	coord.ansi_builder       = strings.builder_make(0, 8192, allocator)
	coord.frame_interval     = DEFAULT_FRAME_INTERVAL
	coord.min_frame_duration = DEFAULT_MIN_FRAME_DURATION
	coord.max_coalesce_batch = DEFAULT_MAX_COALESCE_BATCH
	coord.last_frame_tick    = time.tick_now()
	coord.vlist              = UI_Virtual_List{
		viewport_rows = max(1, h - 6),
		overscan      = DEFAULT_SCROLL_OVERSCAN,
	}
	coord.filter.hide_tx     = true
	coord.render_pass        = render_pass
	coord.input.wants_focus_id = hash_id("records_pane")
	return true
}

ui_coordinator_destroy :: proc(coord: ^UI_Coordinator_State) {
	if coord == nil {
		return
	}
	strings.builder_destroy(&coord.ansi_builder)
	delete(coord.pending_inputs)
	xitdb_filter_destroy(&coord.filter)
	state_store_destroy(&coord.state_store)
	screen_destroy(&coord.screen)
	coord^ = {}
}

spawn_ui_coordinator :: proc(
	sched: ^actor.Scheduler,
	cols, rows: int,
	shared_db: ^Xitdb_Shared_Handle,
	render_pass: UI_Render_Pass_Fn = nil,
	allocator := context.allocator,
) -> (
	ui_actor: ^actor.Actor(UI_Coordinator_State, UI_Msg),
	ok: bool,
) {
	init_state: UI_Coordinator_State
	if !ui_coordinator_init(&init_state, cols, rows, shared_db, render_pass, allocator) {
		return nil, false
	}
	spawned, s_err := actor.spawn(sched, init_state, ui_coordinator_receive, 1, allocator)
	if s_err != nil {
		ui_coordinator_destroy(&init_state)
		return nil, false
	}
	return spawned, true
}

// Helper for drawing a string directly onto `coord.back_buf` in custom `render_pass` callbacks.
ui_back_draw_text :: proc(
	coord: ^UI_Coordinator_State,
	col, row: int,
	text: string,
	fg: Color = {},
	bg: Color = {},
	style: Style_Flags = {},
) {
	if row < 0 || row >= coord.rows {
		return
	}
	x := col
	for ch in text {
		if x >= coord.cols {
			break
		}
		if x >= 0 {
			coord.back_buf[row * coord.cols + x] = Cell{
				ch    = ch,
				fg    = fg,
				bg    = bg,
				style = style,
				width = 1,
			}
		}
		x += 1
	}
}

ui_coordinator_clear_back :: proc(coord: ^UI_Coordinator_State, fill := DEFAULT_CELL) {
	for i in 0 ..< len(coord.back_buf) {
		coord.back_buf[i] = fill
	}
}

// O(1) state reducer for a single `UI_Msg`.
ui_reduce_single_msg :: proc(state: ^UI_Coordinator_State, msg: UI_Msg) -> (is_tick: bool) {
	state.total_msgs_processed += 1

	switch m in msg {
	case UI_Msg_Key:
		state.dirty = true
		state.urgent_input = true

		if m.ctrl && (m.ch == 'p' || m.ch == 'P') {
			state.palette_open    = !state.palette_open
			state.palette.is_open = state.palette_open
			return false
		}

		// Also enqueue a `Key_Event` into `pending_inputs` for immediate-mode widget resolution
		mods: Modifiers
		if m.shift {
			mods += {.Shift}
		}
		if m.alt {
			mods += {.Alt}
		}
		if m.ctrl {
			mods += {.Ctrl}
		}
		if m.super_mod {
			mods += {.Super}
		}
		ke := Key_Event{
			code      = m.code if m.code != .None else (.Rune if m.ch != 0 else .None),
			ch        = m.ch,
			codepoint = m.ch,
			mods      = mods,
			action    = .Repeat if m.is_repeat else .Press,
		}
		if m.ch != 0 && !m.ctrl && !m.alt {
			encoded, w := utf8.encode_rune(m.ch)
			for b_idx in 0 ..< w {
				ke.text_buf[b_idx] = encoded[b_idx]
			}
			ke.text_len = u8(w)
		}
		append(&state.pending_inputs, Input_Event(ke))
		if m.code == .Up || m.ch == 'k' {
			ui_virtual_list_move(&state.vlist, -1)
		} else if m.code == .Down || m.ch == 'j' {
			ui_virtual_list_move(&state.vlist, 1)
		} else if m.code == .Page_Up {
			ui_virtual_list_move(&state.vlist, -state.vlist.viewport_rows)
		} else if m.code == .Page_Down {
			ui_virtual_list_move(&state.vlist, state.vlist.viewport_rows)
		} else if m.code == .Home {
			state.vlist.selected_row = 0
			ui_virtual_list_clamp(&state.vlist)
		} else if m.code == .End {
			state.vlist.selected_row = max(0, state.vlist.total_rows - 1)
			ui_virtual_list_clamp(&state.vlist)
		} else if m.ch == '[' {
			state.pinned_moment = true
			state.active_moment_idx = max(0, state.active_moment_idx - 1)
		} else if m.ch == ']' {
			if state.active_moment_idx + 1 >= state.latest_moment_idx {
				state.pinned_moment = false
				state.active_moment_idx = state.latest_moment_idx
			} else {
				state.pinned_moment = true
				state.active_moment_idx += 1
			}
		} else if m.ch == 'f' {
			state.pinned_moment = false
			state.active_moment_idx = state.latest_moment_idx
		} else if (m.ctrl && (m.ch == 'q' || m.ch == 'Q' || m.ch == 'c' || m.ch == 'C')) ||
		          ((m.ch == 'q' || m.ch == 'Q') && !state.palette_open && !is_focused(&state.input, "search_box")) {
			state.quit_requested = true
		}

	case UI_Msg_Mouse:
		state.dirty = true
		state.urgent_input = true
		mods: Modifiers
		if m.shift {
			mods += {.Shift}
		}
		if m.alt {
			mods += {.Alt}
		}
		if m.ctrl {
			mods += {.Ctrl}
		}
		btn := Mouse_Button.None
		if m.button == 1 {
			btn = .Left
		} else if m.button == 2 {
			btn = .Middle
		} else if m.button == 3 {
			btn = .Right
		} else if m.button == 4 || m.action == .Scroll_Up {
			btn = .Wheel_Up
		} else if m.button == 5 || m.action == .Scroll_Down {
			btn = .Wheel_Down
		}
		append(&state.pending_inputs, Input_Event(Mouse_Event{
			x      = m.x,
			y      = m.y,
			col    = i16(m.x),
			row    = i16(m.y),
			action = m.action,
			button = btn,
			mods   = mods,
		}))
		if m.action == .Scroll_Up {
			ui_virtual_list_move(&state.vlist, -3)
		} else if m.action == .Scroll_Down {
			ui_virtual_list_move(&state.vlist, 3)
		}

	case UI_Msg_Input:
		state.dirty = true
		state.urgent_input = true
		append(&state.pending_inputs, m.event)
		#partial switch ev in m.event {
		case Resize_Event:
			cols := int(ev.width)
			rows := int(ev.height)
			if is_plausible_window_size(cols, rows) && (cols != state.cols || rows != state.rows) {
				_ = screen_resize(&state.screen, i32(cols), i32(rows))
				state.cols = cols
				state.rows = rows
				state.front_buf = state.screen.front
				state.back_buf  = state.screen.back
				state.vlist.viewport_rows = max(1, rows - 6)
				ui_virtual_list_clamp(&state.vlist)
			}
		}

	case UI_Msg_Resize:
		cols := int(m.cols)
		rows := int(m.rows)
		if is_plausible_window_size(cols, rows) && (cols != state.cols || rows != state.rows) {
			_ = screen_resize(&state.screen, i32(cols), i32(rows))
			state.cols = cols
			state.rows = rows
			state.front_buf = state.screen.front
			state.back_buf  = state.screen.back
			state.vlist.viewport_rows = max(1, rows - 6)
			ui_virtual_list_clamp(&state.vlist)
			state.dirty = true
			state.urgent_input = true
		}

	case UI_Msg_Commit_Notification:
		state.latest_moment_idx = m.moment_idx
		state.latest_slot_ptr   = m.slot_ptr
		state.latest_tx_id      = m.tx_id
		state.coalesced_commits += 1
		if !state.pinned_moment {
			state.active_moment_idx = m.moment_idx
		}
		state.dirty = true

	case UI_Msg_Select_Moment:
		state.pinned_moment = m.pin
		if m.pin {
			state.active_moment_idx = clamp(m.moment_idx, 0, max(i64(0), state.latest_moment_idx))
		} else {
			state.active_moment_idx = state.latest_moment_idx
		}
		state.dirty = true
		state.urgent_input = true

	case UI_Msg_Scroll_Viewport:
		delta := m.delta_rows
		if m.page_scroll {
			delta *= state.vlist.viewport_rows
		}
		ui_virtual_list_move(&state.vlist, delta)
		state.dirty = true
		state.urgent_input = true

	case UI_Msg_Search_Input:
		n := min(len(m.query), len(state.search_buf))
		if n > 0 {
			mem.copy(&state.search_buf[0], raw_data(m.query), n)
		}
		state.search_len = n
		q_slice := string(state.search_buf[:n])
		if strings.has_prefix(q_slice, "^") {
			state.filter.kind   = .Key_Prefix
			state.filter.prefix = q_slice[1:]
			state.filter.needle = ""
		} else if len(q_slice) > 0 {
			state.filter.kind   = .Substring
			state.filter.needle = q_slice
			state.filter.prefix = ""
		} else {
			state.filter.kind   = .None
			state.filter.prefix = ""
			state.filter.needle = ""
		}
		set_text(&state.input, "search_box", q_slice)
		state.vlist.selected_row  = 0
		state.vlist.scroll_offset = 0
		state.dirty               = true
		state.urgent_input        = true

	case UI_Msg_Palette_Toggle:
		state.palette_open    = m.open
		state.palette.is_open = m.open
		state.dirty           = true
		state.urgent_input    = true

	case UI_Msg_Datalog_Ready:
		if m.summary_len > 0 {
			n := min(m.summary_len, len(state.last_datalog_buf))
			buf_copy := m.summary_buf
			copy(state.last_datalog_buf[:n], buf_copy[:n])
			state.last_datalog_len     = n
			state.last_datalog_summary = string(state.last_datalog_buf[:n])
		} else if len(m.summary) > 0 {
			n := min(len(m.summary), len(state.last_datalog_buf))
			copy(state.last_datalog_buf[:n], transmute([]u8)m.summary[:n])
			state.last_datalog_len     = n
			state.last_datalog_summary = string(state.last_datalog_buf[:n])
		}
		state.dirty = true

	case UI_Msg_Diff_Ready:
		state.last_diff_summary = m
		state.dirty = true

	case UI_Msg_Batch:
		for sub in m.msgs {
			if ui_reduce_single_msg(state, sub) {
				is_tick = true
			}
		}

	case UI_Msg_Sequence:
		for cmd in m.cmds {
			if cmd == nil {
				continue
			}
			if produced, ok := cmd(context.temp_allocator); ok {
				if ui_reduce_single_msg(state, produced) {
					is_tick = true
				}
			}
		}

	case UI_Msg_Frame_Tick:
		is_tick = true

	case UI_Msg_Quit:
		state.quit_requested = true
		state.dirty = true
	}

	return is_tick
}

// Built-in immediate-mode Inspector layout using Bifrost's Flexbox, Splitter, Virtual List,
// Text Input, Command Palette, and Zero-Copy `xitdb_slice_viewport`.
ui_render_inspector_frame :: proc(coord: ^UI_Coordinator_State) {
	coord.use_widget_pipeline = true
	begin_frame(&coord.screen)
	begin_layout(&coord.layout_ctx, i32(coord.cols), i32(coord.rows))

	if container(
		&coord.layout_ctx,
		"inspector_root",
		Box_Config{
			dir    = .Column,
			width  = fixed(i32(coord.cols)),
			height = fixed(i32(coord.rows)),
		},
	) {
		// 1. Top Status Bar
		mode_str := "PINNED" if coord.pinned_moment else "LIVE"
		header_str := fmt.tprintf(
			"BIFROST xitdb | %s @%d (latest @%d tx=%d) | coll=%s | commits=%d frames=%d",
			mode_str,
			coord.active_moment_idx,
			coord.latest_moment_idx,
			coord.latest_tx_id,
			coord.active_collection if len(coord.active_collection) > 0 else "<root>",
			coord.coalesced_commits,
			coord.total_frames + 1,
		)
		coord.screen.paints[hash_id("status_bar")] = Paint_Spec{
			text    = header_str,
			fg      = rgb(230, 240, 255),
			bg      = rgb(25, 35, 55),
			style   = {.Bold},
			fill_bg = true,
		}
		_ = leaf(&coord.layout_ctx, "status_bar", i32(len(header_str)), 1, Box_Config{
			width  = grow(1),
			height = fixed(1),
			text   = header_str,
		})

		// 2. Search Input Bar
		ui_text_input(
			&coord.layout_ctx,
			&coord.screen,
			&coord.input,
			"search_box",
			Text_Input_Config{
				placeholder = "Search (^prefix or substring)...",
				width       = grow(1),
				height      = fixed(1),
				fg          = rgb(230, 235, 245),
				bg          = rgb(32, 40, 56),
			},
		)

		// 3. Main Body Split Pane (Sidebar + Virtualized Record Table)
		body_h := max(i32(3), i32(coord.rows) - 3)
		if container(
			&coord.layout_ctx,
			"inspector_body",
			Box_Config{
				dir    = .Row,
				width  = grow(1),
				height = fixed(body_h),
			},
		) {
			sidebar_w := get_split_size(&coord.input, "main_split", max(16, i32(coord.cols) / 4), 12, max(20, i32(coord.cols) - 20))
			sidebar_text := fmt.tprintf(
				"active=@%d latest=@%d %s",
				coord.active_moment_idx,
				coord.latest_moment_idx,
				coord.active_collection if len(coord.active_collection) > 0 else "<root>",
			)
			coord.screen.paints[hash_id("sidebar_pane")] = Paint_Spec{
				title       = "Moments & Collections",
				text        = sidebar_text,
				fg          = rgb(200, 215, 230),
				border_fg   = rgb(80, 100, 130),
				title_style = {.Bold},
			}
			_ = leaf(&coord.layout_ctx, "sidebar_pane", sidebar_w, body_h, Box_Config{
				width  = fixed(sidebar_w),
				height = grow(1),
				border = .Plain,
				text   = sidebar_text,
			})

			_ = ui_splitter(
				&coord.layout_ctx,
				&coord.screen,
				&coord.input,
				"main_split",
				Splitter_Config{
					dir          = .Row,
					default_size = sidebar_w,
					min_first    = 12,
					min_second   = 16,
				},
			)

			// Right Pane: Zero-Copy Virtualized xitdb Slice
			visible_rows := max(1, int(body_h) - 2)
			coord.vlist.viewport_rows = visible_rows

			slice: Xitdb_Viewport_Slice
			if coord.shared_db != nil && coord.shared_db.db != nil {
				sync.rw_mutex_shared_lock(&coord.shared_db.rw_lock)
				total_cnt, cnt_err := xitdb_read_collection_count(
					coord.shared_db.db,
					coord.active_moment_idx,
					coord.active_collection,
				)
				if cnt_err == nil {
					coord.vlist.total_rows = int(total_cnt)
					ui_virtual_list_clamp(&coord.vlist)
					slice, _ = xitdb_slice_viewport(
						coord.shared_db.db,
						coord.active_moment_idx,
						coord.active_collection,
						i64(coord.vlist.scroll_offset),
						i64(visible_rows),
						coord.filter,
						context.temp_allocator,
					)
				}
				sync.rw_mutex_shared_unlock(&coord.shared_db.rw_lock)
			}
			coord.last_viewport_rows = len(slice.rows)

			vslice: Virtual_Slice
			if ui_virtual_list(
				&coord.layout_ctx,
				&coord.screen,
				&coord.input,
				"records_pane",
				i32(slice.total_rows),
				Virtual_List_Config{
					title         = fmt.tprintf("Records (%d total)", slice.total_rows),
					width         = grow(1),
					height        = grow(1),
					border        = .Plain,
					fg            = rgb(210, 220, 230),
					border_fg     = rgb(80, 100, 130),
					fallback_rows = i32(visible_rows),
				},
				&vslice,
			) {
				for row_i in 0 ..< len(slice.rows) {
					rv := slice.rows[row_i]
					is_sel := int(rv.logical_index) == coord.vlist.selected_row
					row_id := fmt.tprintf("row_%d", row_i)
					row_line := fmt.tprintf(
						"%s %05d | %-18s | %s",
						">" if is_sel else " ",
						rv.logical_index,
						rv.key_text,
						rv.val_text,
					)
					coord.screen.paints[hash_id(row_id)] = Paint_Spec{
						text    = row_line,
						fg      = rgb(255, 255, 180) if is_sel else rgb(210, 220, 230),
						bg      = rgb(45, 65, 95) if is_sel else Color{},
						style   = {.Bold} if is_sel else {},
						fill_bg = is_sel,
					}
					_ = leaf(&coord.layout_ctx, row_id, i32(len(row_line)), 1, Box_Config{
						width  = grow(1),
						height = fixed(1),
						text   = row_line,
					})
				}
			}
		}

		// 4. Footer Bar (Datalog + Diff Summary)
		footer_str := fmt.tprintf(
			"Datalog: %s | Diff(@%d->@%d): +%d ~%d -%d | [ / ]: time-travel | f: follow | Ctrl+P: palette",
			coord.last_datalog_summary if len(coord.last_datalog_summary) > 0 else "idle",
			coord.last_diff_summary.from_moment,
			coord.last_diff_summary.to_moment,
			coord.last_diff_summary.added,
			coord.last_diff_summary.modified,
			coord.last_diff_summary.removed,
		)
		coord.screen.paints[hash_id("footer_bar")] = Paint_Spec{
			text    = footer_str,
			fg      = rgb(180, 200, 220),
			bg      = rgb(20, 26, 38),
			fill_bg = true,
		}
		_ = leaf(&coord.layout_ctx, "footer_bar", i32(len(footer_str)), 1, Box_Config{
			width  = grow(1),
			height = fixed(1),
			text   = footer_str,
		})
	}

	// 5. Optional Command Palette Modal Overlay
	coord.palette.is_open = coord.palette_open
	if coord.palette.is_open {
		ui_command_palette(
			&coord.layout_ctx,
			&coord.screen,
			&coord.input,
			&coord.palette,
			min(54, max(20, i32(coord.cols) - 4)),
			min(6, max(2, i32(coord.rows) - 6)),
		)
	}

	end_layout(&coord.layout_ctx)
}

ui_coordinator_flush_frame :: proc(state: ^UI_Coordinator_State) {
	state.use_widget_pipeline = false
	state_store_begin_frame(&state.state_store)

	// Run either the caller's custom `render_pass` or the default Bifrost Inspector UI
	if state.render_pass != nil {
		state.render_pass(state)
	} else {
		ui_render_inspector_frame(state)
	}

	if state.use_widget_pipeline {
		// Resolve any pending input events against the layout tree, and if inputs occurred,
		// re-run the immediate-mode layout pass so state changes appear in the same frame.
		if len(state.pending_inputs) > 0 {
			resolve_input(&state.input, &state.layout_ctx, ..state.pending_inputs[:])
			if update_command_palette(&state.palette, &state.input) {
				state.palette_open = state.palette.is_open
			}
			clear(&state.pending_inputs)
			if state.render_pass != nil {
				state.render_pass(state)
			} else {
				ui_render_inspector_frame(state)
			}
		}
		state_store_sync_from_layout(&state.state_store, &state.layout_ctx, &state.input)
		apply_input_highlights(&state.screen, &state.layout_ctx, &state.input)
		render_layout(&state.screen, &state.layout_ctx)
	} else {
		clear(&state.pending_inputs)
	}

	strings.builder_reset(&state.ansi_builder)
	state.last_diff_cells = screen_diff_ansi(&state.screen, &state.ansi_builder)
	state.last_ansi_bytes = strings.builder_len(state.ansi_builder)
	state.front_buf       = state.screen.front
	state.back_buf        = state.screen.back

	state.dirty           = false
	state.urgent_input    = false
	state.batch_drained   = 0
	state.total_frames    += 1
	state.last_frame_tick = time.tick_now()
}

// Single-owner UI Coordinator actor receive callback with mailbox burst coalescing.
ui_coordinator_receive :: proc(
	ctx: ^actor.Context,
	self: ^actor.Actor(UI_Coordinator_State, UI_Msg),
	msg: ^UI_Msg,
) {
	_ = ctx
	state := &self.state
	if msg == nil {
		return
	}

	// 1. Reduce the incoming message in O(1) time.
	is_tick := ui_reduce_single_msg(state, msg^)
	state.batch_drained += 1

	// 2. Also drain any lock-free SPSC fast-path input events from a terminal reader thread.
	if state.spsc_mailbox != nil {
		actor.sharded_spsc_consume(
			state.spsc_mailbox,
			64,
			state,
			proc(s: ^UI_Coordinator_State, fe: ^UI_Fast_Event) {
				switch ev in fe^ {
				case UI_Msg_Key:
					_ = ui_reduce_single_msg(s, UI_Msg(ev))
				case UI_Msg_Mouse:
					_ = ui_reduce_single_msg(s, UI_Msg(ev))
				}
			},
		)
	}

	// 3. Mailbox Burst Coalescing:
	//    While more messages are queued in the actor's Vyukov MPSC mailbox and we haven't
	//    exceeded `max_coalesce_batch` (and this message wasn't an explicit vsync tick),
	//    return immediately so `sleipnir`'s scheduler delivers the next message before rendering.
	if !is_tick && !actor.mpsc_is_empty(&self.mailbox) && state.batch_drained < state.max_coalesce_batch {
		return
	}

	if !state.dirty {
		state.batch_drained = 0
		return
	}

	// 4. Frame-Rate Gate:
	elapsed := time.tick_since(state.last_frame_tick)
	should_render := is_tick ||
		state.render_on_drain ||
		(state.urgent_input && elapsed >= state.min_frame_duration) ||
		(elapsed >= state.frame_interval)

	if !should_render {
		return
	}

	// 5. Execute immediate-mode layout, paint, and differential ANSI emission.
	ui_coordinator_flush_frame(state)
}
