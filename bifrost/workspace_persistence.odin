package bifrost

import "core:fmt"
import "core:sync"
import xitdb "../deps/xitdb/xitdb"

// =============================================================================
// 7. Optional `xitdb` Workspace Snapshot Persistence (Splitters, H/H*, Focus)
// =============================================================================

UI_Workspace_Splitter_Entry :: struct {
	id_hash:      i64,
	size:         i32,
	default_size: i32,
}

UI_Workspace_Scope_Entry :: struct {
	scope_hash:      i64,
	last_child_hash: i64,
	last_leaf_hash:  i64,
}

UI_Workspace_Keymap_Entry :: struct {
	action_name:  string,
	chord_spec:   string,
	user_rebound: bool,
}

UI_Workspace_Snapshot :: struct {
	version:           i64,
	focused_id:        i64,
	active_collection: string,
	pinned_moment:     bool,
	active_moment_idx: i64,
	keymap_style:      i64,
	splitters:         []UI_Workspace_Splitter_Entry,
	scopes:            []UI_Workspace_Scope_Entry,
	keymap_overrides:  []UI_Workspace_Keymap_Entry,
}

save_ui_workspace_to_xitdb :: proc {
	save_ui_workspace_db_coord,
	save_ui_workspace_shared_coord,
	save_ui_workspace_coord_only,
	save_ui_workspace_db_input,
}

load_ui_workspace_from_xitdb :: proc {
	load_ui_workspace_db_coord,
	load_ui_workspace_shared_coord,
	load_ui_workspace_coord_only,
	load_ui_workspace_db_input,
}

save_ui_workspace_coord_only :: proc(
	coord: ^UI_Coordinator_State,
	workspace_id: string = "default",
) -> bool {
	if coord == nil || coord.shared_db == nil {
		return false
	}
	return save_ui_workspace_shared_coord(coord.shared_db, coord, workspace_id)
}

save_ui_workspace_shared_coord :: proc(
	shared: ^Xitdb_Shared_Handle,
	coord: ^UI_Coordinator_State,
	workspace_id: string = "default",
) -> bool {
	if shared == nil || shared.db == nil || coord == nil {
		return false
	}
	sync.rw_mutex_lock(&shared.rw_lock)
	defer sync.rw_mutex_unlock(&shared.rw_lock)
	return save_ui_workspace_db_coord(shared.db, coord, workspace_id)
}

save_ui_workspace_db_coord :: proc(
	db: ^xitdb.Database,
	coord: ^UI_Coordinator_State,
	workspace_id: string = "default",
) -> bool {
	if db == nil || coord == nil {
		return false
	}
	return save_workspace_snapshot_internal(
		db,
		&coord.input,
		coord.active_collection,
		coord.pinned_moment,
		coord.active_moment_idx,
		workspace_id,
	)
}

save_ui_workspace_db_input :: proc(
	db: ^xitdb.Database,
	inp: ^Input_State,
	workspace_id: string = "default",
) -> bool {
	if db == nil || inp == nil {
		return false
	}
	return save_workspace_snapshot_internal(db, inp, "", false, 0, workspace_id)
}

@(private)
save_workspace_snapshot_internal :: proc(
	db: ^xitdb.Database,
	inp: ^Input_State,
	active_collection: string,
	pinned_moment: bool,
	active_moment_idx: i64,
	workspace_id: string,
) -> bool {
	ws_key := workspace_id if len(workspace_id) > 0 else "default"

	splitter_buf: [MAX_SPLITTER_SLOTS]UI_Workspace_Splitter_Entry
	splitter_cnt := 0
	for i := 0; i < MAX_SPLITTER_SLOTS; i += 1 {
		slot := inp.splitter_slots[i]
		if slot.id_hash != 0 {
			splitter_buf[splitter_cnt] = UI_Workspace_Splitter_Entry{
				id_hash      = i64(slot.id_hash),
				size         = slot.size,
				default_size = slot.default_size,
			}
			splitter_cnt += 1
		}
	}

	scope_buf: [MAX_SCOPE_MEMORY]UI_Workspace_Scope_Entry
	scope_cnt := 0
	for i := 0; i < inp.scope_memory_len; i += 1 {
		entry := inp.scope_memory[i]
		if entry.scope_hash != 0 {
			scope_buf[scope_cnt] = UI_Workspace_Scope_Entry{
				scope_hash      = i64(entry.scope_hash),
				last_child_hash = i64(entry.last_child_hash),
				last_leaf_hash  = i64(entry.last_leaf_hash),
			}
			scope_cnt += 1
		}
	}

	keymap_buf: [MAX_ACTION_SPECS]UI_Workspace_Keymap_Entry
	keymap_cnt := 0
	for i := 0; i < inp.action_spec_cnt; i += 1 {
		spec := inp.action_specs[i]
		if len(spec.action_name) > 0 && len(spec.chord_spec) > 0 {
			keymap_buf[keymap_cnt] = UI_Workspace_Keymap_Entry{
				action_name  = spec.action_name,
				chord_spec   = spec.chord_spec,
				user_rebound = spec.user_rebound,
			}
			keymap_cnt += 1
		}
	}

	focus_target := inp.focused_id if inp.focused_id != 0 else inp.wants_focus_id
	snap := UI_Workspace_Snapshot{
		version           = 2,
		focused_id        = i64(focus_target),
		active_collection = active_collection,
		pinned_moment     = pinned_moment,
		active_moment_idx = active_moment_idx,
		keymap_style      = i64(inp.keymap_style),
		splitters         = splitter_buf[:splitter_cnt],
		scopes            = scope_buf[:scope_cnt],
		keymap_overrides  = keymap_buf[:keymap_cnt],
	}

	Workspace_Tx_Ctx :: struct {
		ws_key: string,
		snap:   UI_Workspace_Snapshot,
	}
	tx_ctx := Workspace_Tx_Ctx{
		ws_key = ws_key,
		snap   = snap,
	}
	tx := xitdb.tx_init(db, -1, false, context.temp_allocator)
	xitdb.tx_with_cursor(&tx, proc(cursor: ^xitdb.Write_Cursor, raw: rawptr) -> xitdb.Error {
		c := (^Workspace_Tx_Ctx)(raw)
		steps := [2]xitdb.Path_Step{xitdb.hm(BI_WORKSPACE_ROOT_KEY), xitdb.hm(c.ws_key)}
		target := xitdb.write_steps_cursor(cursor^, steps[:]) or_return
		return xitdb.marshal(&target, c.snap)
	}, &tx_ctx)
	_, err := xitdb.tx_commit(&tx)
	if err != nil {
		fmt.eprintf("save_workspace_snapshot_internal: tx_commit failed: %v\n", err)
	}
	return err == nil
}

load_ui_workspace_coord_only :: proc(
	coord: ^UI_Coordinator_State,
	workspace_id: string = "default",
) -> bool {
	if coord == nil || coord.shared_db == nil {
		return false
	}
	return load_ui_workspace_shared_coord(coord.shared_db, coord, workspace_id)
}

load_ui_workspace_shared_coord :: proc(
	shared: ^Xitdb_Shared_Handle,
	coord: ^UI_Coordinator_State,
	workspace_id: string = "default",
) -> bool {
	if shared == nil || shared.db == nil || coord == nil {
		return false
	}
	sync.rw_mutex_shared_lock(&shared.rw_lock)
	defer sync.rw_mutex_shared_unlock(&shared.rw_lock)
	local_core := shared.db.core^
	local_db   := shared.db^
	local_db.core = &local_core
	return load_ui_workspace_db_coord(&local_db, coord, workspace_id)
}

load_ui_workspace_db_coord :: proc(
	db: ^xitdb.Database,
	coord: ^UI_Coordinator_State,
	workspace_id: string = "default",
) -> bool {
	if db == nil || coord == nil {
		return false
	}
	snap, latest_idx, ok := read_workspace_snapshot_internal(db, workspace_id)
	if !ok {
		return false
	}
	apply_workspace_snapshot_to_input(&coord.input, snap)
	if latest_idx > coord.latest_moment_idx {
		coord.latest_moment_idx = latest_idx
	}
	coord.active_collection_len, coord.active_collection = copy_string_to_buf(coord.active_collection_buf[:], snap.active_collection)
	coord.pinned_moment = snap.pinned_moment
	if snap.pinned_moment {
		coord.active_moment_idx = max(i64(0), snap.active_moment_idx)
	} else {
		coord.active_moment_idx = coord.latest_moment_idx
	}
	coord.dirty = true
	return true
}

load_ui_workspace_db_input :: proc(
	db: ^xitdb.Database,
	inp: ^Input_State,
	workspace_id: string = "default",
) -> bool {
	if db == nil || inp == nil {
		return false
	}
	snap, _, ok := read_workspace_snapshot_internal(db, workspace_id)
	if !ok {
		return false
	}
	apply_workspace_snapshot_to_input(inp, snap)
	return true
}

@(private)
read_workspace_snapshot_internal :: proc(
	db: ^xitdb.Database,
	workspace_id: string,
) -> (
	snap: UI_Workspace_Snapshot,
	latest_idx: i64,
	ok: bool,
) {
	ws_key := workspace_id if len(workspace_id) > 0 else "default"
	moment_cur, resolved_idx, m_err := xitdb_open_moment_cursor(db, -1)
	if m_err != nil {
		return {}, 0, false
	}
	steps := [2]xitdb.Path_Step{xitdb.hm(BI_WORKSPACE_ROOT_KEY), xitdb.hm(ws_key)}
	ws_maybe, r_err := xitdb.read_steps_cursor(moment_cur, steps[:])
	if r_err != nil {
		return {}, resolved_idx, false
	}
	ws_cur, exists := ws_maybe.?
	if !exists {
		return {}, resolved_idx, false
	}
	parsed, u_err := xitdb.unmarshal(UI_Workspace_Snapshot, ws_cur, context.temp_allocator)
	if u_err != nil {
		return {}, resolved_idx, false
	}
	return parsed, resolved_idx, true
}

@(private)
apply_workspace_snapshot_to_input :: proc(inp: ^Input_State, snap: UI_Workspace_Snapshot) {
	for entry in snap.splitters {
		id_h := u64(entry.id_hash)
		if id_h == 0 {
			continue
		}
		slot := get_splitter_slot(inp, id_h)
		slot.size = entry.size
		if entry.default_size > 0 {
			slot.default_size = entry.default_size
		}
		slot.initialized = true
	}
	for entry in snap.scopes {
		s_hash := u64(entry.scope_hash)
		if s_hash == 0 {
			continue
		}
		upsert_scope_memory(
			inp,
			s_hash,
			u64(entry.last_child_hash),
			u64(entry.last_leaf_hash),
		)
	}
	if snap.keymap_style >= 0 && int(snap.keymap_style) < len(Keymap_Style) {
		set_keymap_style(inp, Keymap_Style(snap.keymap_style))
	}
	for entry in snap.keymap_overrides {
		if len(entry.action_name) > 0 && len(entry.chord_spec) > 0 {
			act_id := hash_id(entry.action_name)
			is_custom := entry.user_rebound
			for i := 0; i < inp.action_spec_cnt; i += 1 {
				if inp.action_specs[i].action_id == act_id {
					if !is_custom {
						is_custom = inp.action_specs[i].chord_spec != entry.chord_spec
					}
					break
				}
			}
			_ = rebind_action_chord_internal(inp, entry.action_name, entry.chord_spec, is_custom)
		}
	}
	f_hash := u64(snap.focused_id)
	if f_hash != 0 {
		inp.wants_focus_id = f_hash
	}
}

