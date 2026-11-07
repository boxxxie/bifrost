package bifrost

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
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
	defer free_all(context.temp_allocator)
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
		local_core := state.shared.db.core^
		local_db   := state.shared.db^
		local_db.core = &local_core
		res, q_err := xitdb.query_datalog(
			&local_db,
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
		local_core := state.shared.db.core^
		local_db   := state.shared.db^
		local_db.core = &local_core
		entries, d_err := xitdb.diff_moments(
			&local_db,
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
		local_core := state.shared.db.core^
		local_db   := state.shared.db^
		local_db.core = &local_core
		rc := xitdb.database_root_cursor(&local_db)
		cnt, _ := xitdb.cursor_count(rc.read_cursor)
		sync.rw_mutex_shared_unlock(&state.shared.rw_lock)
		actor.reply(ctx, cnt)
	}
}

// =============================================================================
// 4. Zero-Copy xitdb Viewport Slicing (O(log_16 N) B+Tree / Hash / Array Seek)
// =============================================================================

Xitdb_Row_View :: struct {
	view_index:    i64, // 0-based index inside the active filtered view
	logical_index: i64, // Underlying index inside the xitdb collection
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

@(private)
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
is_internal_xitdb_key :: #force_inline proc "contextless" (k: string) -> bool {
	return k == "_tx" || k == "__tx" || k == BI_WORKSPACE_ROOT_KEY
}

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
					if is_internal_xitdb_key(string(b_res.value)) {
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
		return fmt.aprintf("{{%d entries}}", cnt, allocator = alloc)
	case .Hash_Set:
		return "#{set}"
	case .Counted_Hash_Set, .Sorted_Set:
		cnt, _ := xitdb.cursor_count(cur)
		return fmt.aprintf("#{{%d members}}", cnt, allocator = alloc)
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

	has_active_filter := (filter.kind == .Substring && len(filter.needle) > 0) ||
		(filter.kind == .Key_Prefix && len(filter.prefix) > 0) ||
		(filter.kind == .Key_Range && (len(filter.lower_key) > 0 || len(filter.upper_key) > 0))

	total_count: i64 = 0
	if !has_active_filter && coll_tag != .Hash_Map && coll_tag != .Hash_Set {
		total_count = xitdb.cursor_count(target_cur) or_return
	}
	clamped_start := max(i64(0), start_row)
	if !has_active_filter && total_count > 0 && clamped_start > total_count {
		clamped_start = total_count
	}
	max_fetch := max(i64(0), visible_rows)

	rows := make([dynamic]Xitdb_Row_View, 0, int(max_fetch), alloc)

	#partial switch coll_tag {
	case .None, .Bytes, .Short_Bytes, .Uint, .Int, .Float:
		val_str := xitdb_format_cursor_preview(target_cur, alloc)
		key_str := collection_name if len(collection_name) > 0 else "<scalar>"
		passes_filter := true
		if filter.kind == .Substring && len(filter.needle) > 0 {
			passes_filter = strings.contains(val_str, filter.needle) || strings.contains(key_str, filter.needle)
		} else if filter.kind == .Key_Prefix && len(filter.prefix) > 0 {
			passes_filter = strings.has_prefix(key_str, filter.prefix)
		}
		if passes_filter {
			if clamped_start == 0 && max_fetch > 0 {
				append(&rows, Xitdb_Row_View{
					view_index    = 0,
					logical_index = 0,
					key_text      = strings.clone(key_str, alloc),
					val_text      = val_str,
					tag           = coll_tag,
					slot_offset   = target_slot.value,
				})
			}
			total_count = 1
		}

	case .Array_List, .Linked_Array_List:
		seek_start := i64(0) if has_active_filter else clamped_start
		it: xitdb.Cursor_Iterator
		if coll_tag == .Array_List {
			it = xitdb.cursor_iterator_array_list_from_index(target_cur, seek_start) or_return
		} else {
			it = xitdb.cursor_iterator_linked_array_list_from_index(target_cur, seek_start) or_return
		}
		row_idx := seek_start
		matched_idx := seek_start
		for {
			if !has_active_filter && i64(len(rows)) >= max_fetch {
				break
			}
			item_maybe := xitdb.cursor_iterator_next(&it) or_return
			item_cur, has_item := item_maybe.?
			if !has_item {
				break
			}
			val_str := xitdb_format_cursor_preview(item_cur, alloc)
			key_str := fmt.aprintf("[%d]", row_idx, allocator = alloc)
			if filter.kind == .Substring && len(filter.needle) > 0 {
				if !strings.contains(val_str, filter.needle) && !strings.contains(key_str, filter.needle) {
					row_idx += 1
					continue
				}
			}
			if matched_idx >= clamped_start && i64(len(rows)) < max_fetch {
				item_slot, _ := xitdb.cursor_slot(item_cur)
				append(&rows, Xitdb_Row_View{
					view_index    = matched_idx,
					logical_index = row_idx,
					key_text      = key_str,
					val_text      = val_str,
					tag           = item_slot.tag,
					slot_offset   = item_slot.value,
				})
			}
			row_idx += 1
			matched_idx += 1
		}
		if has_active_filter {
			total_count = matched_idx
		}

	case .Sorted_Map, .Sorted_Set:
		it: xitdb.Cursor_Iterator
		row_idx := clamped_start
		matched_idx: i64 = 0
		if filter.kind == .Key_Prefix && len(filter.prefix) > 0 {
			it = xitdb.cursor_iterator_sorted_from_key(target_cur, transmute([]u8)filter.prefix) or_return
			row_idx = it.index
		} else if filter.kind == .Key_Range && len(filter.lower_key) > 0 {
			it = xitdb.cursor_iterator_sorted_from_key(target_cur, transmute([]u8)filter.lower_key) or_return
			row_idx = it.index
		} else if has_active_filter {
			it = xitdb.cursor_iterator_sorted_from_index(target_cur, 0) or_return
			row_idx = 0
		} else {
			it = xitdb.cursor_iterator_sorted_from_index(target_cur, clamped_start) or_return
			matched_idx = clamped_start
		}

		key_buf: [256]u8
		for {
			if !has_active_filter && i64(len(rows)) >= max_fetch {
				break
			}
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

			if filter.hide_tx && is_internal_xitdb_key(k_str) {
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

			is_set_coll := coll_tag == .Sorted_Set
			val_str := "∈ set" if is_set_coll else xitdb_format_cursor_preview(kv_pair.value_cursor, alloc)
			if filter.kind == .Substring && len(filter.needle) > 0 {
				if !strings.contains(k_str, filter.needle) && !strings.contains(val_str, filter.needle) {
					row_idx += 1
					continue
				}
			}

			if matched_idx >= clamped_start && i64(len(rows)) < max_fetch {
				val_slot, _ := xitdb.cursor_slot(kv_pair.key_cursor if is_set_coll else kv_pair.value_cursor)
				append(&rows, Xitdb_Row_View{
					view_index    = matched_idx,
					logical_index = row_idx,
					key_text      = strings.clone(k_str, alloc),
					val_text      = val_str,
					tag           = val_slot.tag,
					slot_offset   = val_slot.value,
				})
			}
			row_idx += 1
			matched_idx += 1
		}
		if has_active_filter {
			total_count = matched_idx
		}

	case:
		it := xitdb.cursor_iterator(target_cur) or_return
		row_idx: i64 = 0
		matched_idx: i64 = 0
		key_buf: [256]u8
		is_set_coll := coll_tag == .Hash_Set || coll_tag == .Counted_Hash_Set
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
			if filter.hide_tx && is_internal_xitdb_key(k_str) {
				continue
			}
			if filter.kind == .Key_Prefix && len(filter.prefix) > 0 {
				if !strings.has_prefix(k_str, filter.prefix) {
					row_idx += 1
					continue
				}
			}
			val_str := "∈ set" if is_set_coll else xitdb_format_cursor_preview(kv_pair.value_cursor, alloc)
			if filter.kind == .Substring && len(filter.needle) > 0 {
				if !strings.contains(k_str, filter.needle) && !strings.contains(val_str, filter.needle) {
					row_idx += 1
					continue
				}
			}
			if matched_idx >= clamped_start && i64(len(rows)) < max_fetch {
				val_slot, _ := xitdb.cursor_slot(kv_pair.key_cursor if is_set_coll else kv_pair.value_cursor)
				append(&rows, Xitdb_Row_View{
					view_index    = matched_idx,
					logical_index = row_idx,
					key_text      = strings.clone(k_str, alloc),
					val_text      = val_str,
					tag           = val_slot.tag,
					slot_offset   = val_slot.value,
				})
			}
			row_idx += 1
			matched_idx += 1
		}
		total_count = matched_idx
	}

	return Xitdb_Viewport_Slice{
		moment_idx     = resolved_idx,
		collection_key = collection_name,
		total_rows     = total_count,
		start_row      = clamped_start,
		rows           = rows[:],
	}, nil
}

