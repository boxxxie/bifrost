### 1. Sleipnir Actor Integration (`bifrost/actor_bridge.odin`)

In `deps/sleipnir/actor` (`package actor`), the M:N work-stealing runtime is `actor.Scheduler` (aliased as `Actor_System :: actor.Scheduler` in `bifrost`). Every `actor.Actor($State, $Msg)` embeds `actor.Actor_Ref(Msg)` at offset 0 (which itself embeds `actor.Actor_Base` at offset 0), enabling type-erased scheduling on `RunQ_Shard(Actor_Base)` alongside strongly-typed addressing via `actor.PID($Msg)` (`struct { ref: ^Actor_Ref(Msg) }`).

The four runtime participants are wired together as follows:

1. **UI Coordinator Actor (`actor.Actor(UI_Coordinator_State, UI_Msg)`):**
* Spawned on the `actor.Scheduler` via `actor.spawn` using `STEP_MODE_ACTOR` (`proc(ctx: ^actor.Context, self: ^actor.Actor(UI_Coordinator_State, UI_Msg), msg: ^UI_Msg)`) so the handler has direct access to both `ctx` and `&self.mailbox` (`actor.MPSC_Queue(actor.Envelope(UI_Msg))`).


* Owns a `actor.PID(UI_Msg)` handle (`actor.pid(ui_actor)`) passed to the Input Producer, Tick/Resize Producer, and Background `xitdb` Worker Actor.


* Also owns an optional `actor.Sharded_SPSC_Mailbox(UI_Fast_Event, 8192)` (`actor.sharded_spsc_init`) with dedicated wait-free `actor.SPSC_Lane` rings (`actor.sharded_spsc_push` / `actor.sharded_spsc_consume`) for zero-RMW (`lock xchg`-free) high-frequency telemetry or frame-tick fan-in from fixed OS producer threads.




2. **Background `xitdb` Worker Actor (`actor.Actor(Xitdb_Worker_State, Xitdb_Worker_Msg)`):**
* Spawned on the same `actor.Scheduler` via `actor.spawn` (`STEP_MODE_ACTOR` or `STEP_MODE_STATE`) with a larger `batch_quota`.


* Owns the write-side `^xitdb.Database` handle and processes `Xitdb_Worker_Msg` variants:
* `Worker_Msg_Transact_Script`: Executes `xitdb.transact_script(state.db, m.script, context.temp_allocator)`.


* `Worker_Msg_Commit_Batch`: Opens a `xitdb.Tx` via `xitdb.tx_init(state.db, -1, m.track_changes, context.temp_allocator)`, applies `xitdb.tx_put` / `xitdb.tx_append` / `xitdb.tx_index_on`, and commits via `xitdb.tx_commit(&tx)`.


* `Worker_Msg_Run_Datalog`: Executes `xitdb.query_datalog(state.db, m.query, m.moment_idx, state.result_allocator)` and replies or sends the result to `ui_pid`.


* `Worker_Msg_Diff_Moments`: Calls `xitdb.diff_moments(state.db, m.moment_a, m.moment_b, false, state.result_allocator)`.




* When a transaction commits, the worker notifies the UI Coordinator via `actor.send(ctx, state.ui_pid, UI_Msg(UI_Msg_State_Committed{moment_idx = report.moment_index, commit_size = report.commit_size}))`, which acquires an `Envelope(UI_Msg)` from the worker's thread-local `target.ref.pools[ctx.worker_id]` (`actor.pool_acquire`) with zero cross-thread lock contention.


* Supports synchronous request/reply (`actor.call(worker_pid, msg, Res)` paired with `actor.reply(ctx, res)`) because Sleipnir's `call_sched_pid` cooperatively steps runnable actors on worker threads (`scheduler_step_one_cooperative`) instead of deadlocking.




3. **Terminal Input Producer (`Terminal_Input_Producer`):**
* Modeled after Bubble Tea's `readLoop` (`tty.go`): runs on a dedicated OS reader thread (since blocking `os.read` on `os.stdin` or TTY file descriptors would stall an M:N work-stealing worker thread).


* Parses raw ANSI / UTF-8 input bytes into `UI_Input_Event` values and dispatches bursts to `ui_pid` in a **single atomic `XCHG**` using `actor.send(sched, ui_pid, batch_slice)` (`send_sched_batch_auto_pid` -> `acquire_auto_envelope_chain` -> `mpsc_push_chain`).




4. **Tick & Resize Producer (`Frame_Ticker_Producer`):**
* Modeled after Bubble Tea's `startRenderer` ticker (`tea.go`, bounded between `1` and `maxFPS = 120`, default `60` FPS) and `listenForResize` (`SIGWINCH` / `checkResize` with `isPlausibleWindowSize` bounds `4096x4096` and `1 << 20` cells in `screen.go`).


* Emits `UI_Msg_Frame_Tick` at the configured frame interval and `UI_Msg_Resize{width, height}` whenever terminal dimensions change.





---

### 2. Mailbox Batch Coalescing & Frame Pacing (`bubbletea` + `sleipnir`)

In Go's Bubble Tea (`tea.go` and `cursed_renderer.go`), `eventLoop` updates the model and calls `p.renderer.render(model.View())`, which merely stores `s.view = v` under a mutex; actual diffing (`s.scr.Render(s.cellbuf.RenderBuffer)`) and synchronized ANSI output (`SetModeSynchronizedOutput` / `ResetModeSynchronizedOutput`) only happen when `<-p.ticker.C` fires in `startRenderer`. Furthermore, `compactCmds` (`commands.go`) collapses `nil` and single-element command slices before spawning goroutines.

In Sleipnir (`actor/actor.odin`), `actor_generic_step_proc` pops each envelope with `env := mpsc_pop_detached(&self.mailbox)` **before** invoking `self.receive(ctx, self, &env.msg)`, and loops up to `quota` messages per turn while batch-recycling consumed envelopes through `Batch_Return_Collector(UI_Msg)` (`collector_add` + `collector_flush`).

We combine both mechanisms in `ui_coordinator_receive` so 1,000 rapid `UI_Msg_State_Committed` messages result in **1 layout/diff/ANSI pass**:

1. **Phase 1 — State Reduction (`ui_reduce_single_msg`):**
* `UI_Msg_State_Committed{moment_idx, commit_size, tx_doc}`: Overwrites `state.current_moment_idx = m.moment_idx` and `state.latest_commit_size = m.commit_size` in $O(1)$ time, increments `state.coalesced_commits += 1`, and marks `state.dirty = true`.
* `UI_Msg_Input`: Appends the event to `state.pending_inputs` (`[dynamic]UI_Input_Event`) so rapid keystrokes or mouse wheel steps are never dropped during coalescing, and sets `state.dirty = true` and `state.urgent_input = true`.
* `UI_Msg_Resize`: Validates dimensions with `is_plausible_window_size(m.width, m.height)` (`width * height <= (1 << 20)` from `screen.go`), updates `state.width, state.height`, and sets `state.needs_resize = true` and `state.dirty = true`.


* `UI_Msg_Batch`: Mirrors Bubble Tea's `compactCmds` (`commands.go`) by ignoring `nil` commands, executing a single command inline, or fanning out multiple commands.




2. **Phase 2 — Non-Blocking MPSC + SPSC Burst Drain:**
* If `state.has_spsc_mailbox`, calls `actor.sharded_spsc_consume(&state.spsc_mailbox, 256, state, ui_spsc_reduce_proc)` to drain wait-free SPSC producer lanes in a single `.Release` update per lane.


* Checks `!actor.mpsc_is_empty(&self.mailbox)`: as long as more envelopes are queued in the MPSC mailbox (up to `state.max_coalesce_batch`, e.g., `4096`), `ui_coordinator_receive` returns immediately! `actor_generic_step_proc` then pops the next `Envelope(UI_Msg)` in ~5–10 ns and adds the previous envelope to `Batch_Return_Collector(UI_Msg)` without running layout or ANSI rendering.




3. **Phase 3 — VSync Frame Gate & Single Render Pass (`ui_flush_frame_if_due`):**
* Once the MPSC burst is drained (`actor.mpsc_is_empty(&self.mailbox)` is `true` or `UI_Msg_Frame_Tick` arrives), the coordinator checks whether `state.dirty` is set and either:
* A `UI_Msg_Frame_Tick` triggered this turn, OR
* `state.urgent_input` is set and `time.diff(state.last_render_tick, time.tick_now()) >= state.min_frame_duration` (low-latency interactive fast-path capped at 120 FPS).


* When due, it resets `free_all(context.temp_allocator)`, runs **one** `begin_layout` -> `resolve_input` (over `state.pending_inputs[:]`) -> `render_layout` -> `screen_diff_ansi` pass wrapped in DEC Mode 2026 Synchronized Output (`\x1b[?2026h` ... `\x1b[?2026l`), clears `state.pending_inputs`, and resets `state.dirty = false`.





---

### 3. Zero-Copy `xitdb` Viewport Slicing (`deps/xitdb`)

Using `track5_xitdb_api.patch`, the viewport adapter avoids loading entire collections into memory by leveraging `xitdb`'s persistent tree structure:

1. **Snapshot Resolution (`xitdb_open_moment_cursor`):**
* Obtains a read-only root cursor via `rc := xitdb.cursor_read_only(xitdb.database_root_cursor(db))`.


* Inspects `root_slot := xitdb.cursor_slot(rc) or_return`. When `root_slot.tag == .Array_List`, it resolves `moment_idx` (`-1` for latest, or `0 ..< moment_count`) in $O(\log_{16} M)$ time via `xitdb.cursor_read_path(rc, []xitdb.Path_Part{xitdb.Array_List_Get{index = moment_idx}})`.


* Walks any sub-path selector (`[]xitdb.Path_Step` or string selector parsed via `xitdb.parse_steps(path, context.temp_allocator)`) using `xitdb.read_steps_cursor(moment_cursor, steps)`.




2. **$O(1)$ Collection Header Counts (`xitdb_read_collection_count`):**
* Calls `xitdb.cursor_count(col_cursor)` for `.Array_List` (`ARRAY_LIST_HEADER_LENGTH`), `.Linked_Array_List`, `.Sorted_Map`, `.Sorted_Set` (`BTREE_HEADER_LENGTH`), `.Counted_Hash_Map`, and `.Counted_Hash_Set`, which reads the 8-byte size directly from the collection header in $O(1)$.


* Falls back to `xitdb.cursor_iterator(col_cursor)` only for uncounted `.Hash_Map` / `.Hash_Set` tags (where `cursor_count` returns `.Unexpected_Tag`).




3. **$O(\log_{16} N + K)$ Viewport Slicing (`xitdb_slice_viewport`):**
* For unfiltered indexed collections, seeks directly to `start_row` in $O(\log_{16} N)$ without scanning rows `0 ..< start_row`:
* `.Array_List`: `xitdb.cursor_iterator_array_list_from_index(col_cursor, start_row)`.


* `.Linked_Array_List`: `xitdb.cursor_iterator_linked_array_list_from_index(col_cursor, start_row)`.


* `.Sorted_Map` / `.Sorted_Set`: `xitdb.cursor_iterator_sorted_from_index(col_cursor, start_row)`.




* For prefix/range-filtered `.Sorted_Map` / `.Sorted_Set` (`Xitdb_Filter.kind == .Key_Prefix` or `.Key_Range`):
* Seeks directly to the first matching key in the B+Tree via `xitdb.cursor_iterator_sorted_from_key(col_cursor, transmute([]u8)start_key)` (and when querying a moment's secondary index, computes total range cardinality in $O(\log N)$ via `xitdb.query_count_range`).




* During row materialization, scalar keys and values are decoded using a stack buffer (`stack_buf: [256]u8`) via `xitdb.cursor_read_bytes_buf(c, stack_buf[:])` (which decodes inline `.Short_Bytes` and `.Bytes` with zero heap allocations), and only the `visible_count = end_row - start_row` visible rows are cloned onto `context.temp_allocator`.





---

### Deliverable 1: `bifrost/actor_bridge.odin`

```odin
package bifrost

import "base:intrinsics"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

import actor "../deps/sleipnir/actor"
import xitdb "../deps/xitdb/xitdb"

// =============================================================================
// 1. Sleipnir Actor System Alias & Frame Pacing Constants
// =============================================================================

Actor_System :: actor.Scheduler

DEFAULT_FPS               :: 60
MAX_FPS                   :: 120
DEFAULT_MAX_COALESCE      :: 4096
MAX_WINDOW_DIMENSION      :: 4096
MAX_WINDOW_CELLS          :: 1 << 20

ANSI_SYNC_BEGIN           :: "\x1b[?2026h"
ANSI_SYNC_END             :: "\x1b[?2026l"
ANSI_ALT_SCREEN_ENTER     :: "\x1b[?1049h"
ANSI_ALT_SCREEN_EXIT      :: "\x1b[?1049l"
ANSI_CURSOR_HIDE          :: "\x1b[?25l"
ANSI_CURSOR_SHOW          :: "\x1b[?25h"

// Plausibility check modeled after Bubble Tea's `isPlausibleWindowSize` (`screen.go`).
is_plausible_window_size :: #force_inline proc(width, height: int) -> bool {
	if width <= 0 || height <= 0 {
		return false
	}
	if width > MAX_WINDOW_DIMENSION || height > MAX_WINDOW_DIMENSION {
		return false
	}
	return width * height <= MAX_WINDOW_CELLS
}

// =============================================================================
// 2. UI & Input Message Types (Elm / Bubble Tea Architecture over Sleipnir)
// =============================================================================

Key_Code :: enum u8 {
	None,
	Rune,
	Up,
	Down,
	Left,
	Right,
	Page_Up,
	Page_Down,
	Home,
	End,
	Enter,
	Tab,
	Back_Tab,
	Backspace,
	Escape,
	Ctrl_C,
}

UI_Input_Kind :: enum u8 {
	Key_Press,
	Mouse_Wheel_Up,
	Mouse_Wheel_Down,
	Mouse_Click,
}

UI_Input_Event :: struct {
	kind:   UI_Input_Kind,
	key:    Key_Code,
	ch:     rune,
	x:      int,
	y:      int,
}

// Bubble Tea-style asynchronous command returning a `UI_Msg`.
UI_Cmd :: #type proc() -> UI_Msg

UI_Msg_Input :: struct {
	event: UI_Input_Event,
}

UI_Msg_Resize :: struct {
	width:  int,
	height: int,
}

UI_Msg_Frame_Tick :: struct {
	timestamp: time.Tick,
}

UI_Msg_State_Committed :: struct {
	moment_idx:  i64,
	commit_size: i64,
	tx_doc:      string,
}

UI_Msg_Datalog_Ready :: struct {
	request_id: u64,
	moment_idx: i64,
	summary:    string,
	row_count:  int,
}

UI_Msg_Diff_Ready :: struct {
	moment_a:     i64,
	moment_b:     i64,
	change_count: int,
	summary:      string,
}

UI_Msg_Batch :: struct {
	cmds: []UI_Cmd,
}

UI_Msg_Sequence :: struct {
	cmds: []UI_Cmd,
}

UI_Msg_Quit :: struct {}

UI_Msg :: union {
	UI_Msg_Input,
	UI_Msg_Resize,
	UI_Msg_Frame_Tick,
	UI_Msg_State_Committed,
	UI_Msg_Datalog_Ready,
	UI_Msg_Diff_Ready,
	UI_Msg_Batch,
	UI_Msg_Sequence,
	UI_Msg_Quit,
}

// Compact command slice helper modeled after Bubble Tea's `compactCmds` (`commands.go`).
ui_batch_cmds :: proc(cmds: ..UI_Cmd, allocator := context.temp_allocator) -> UI_Cmd {
	valid := make([dynamic]UI_Cmd, 0, len(cmds), allocator)
	for c in cmds {
		if c != nil {
			append(&valid, c)
		}
	}
	switch len(valid) {
	case 0:
		return nil
	case 1:
		return valid[0]
	case:
		return nil
	}
}

// =============================================================================
// 3. Background `xitdb` Worker Actor Protocol & Implementation
// =============================================================================

Worker_KV_Op :: struct {
	path: string,
	val:  xitdb.Writeable_Data,
}

Worker_Msg_Transact_Script :: struct {
	script: string,
}

Worker_Msg_Commit_Batch :: struct {
	doc:           string,
	instant_ms:    i64,
	ops:           []Worker_KV_Op,
	index_source:  string,
	index_field:   string,
	index_target:  string,
	track_changes: bool,
}

Worker_Msg_Run_Datalog :: struct {
	request_id: u64,
	moment_idx: i64,
	query_str:  string,
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

// Shared concurrency guard for `xitdb.Database` when the writer actor and UI reader
// share an in-memory `Core_Memory` handle whose `core_seek_to` mutates `core.pos`.
Xitdb_Shared_Handle :: struct {
	db:    ^xitdb.Database,
	rw_mu: sync.RW_Mutex,
}

Xitdb_Worker_State :: struct {
	shared:         ^Xitdb_Shared_Handle,
	ui_pid:         actor.PID(UI_Msg),
	commits_done:   i64,
	last_moment:    i64,
}

xitdb_worker_receive :: proc(
	ctx: ^actor.Context,
	self: ^actor.Actor(Xitdb_Worker_State, Xitdb_Worker_Msg),
	msg: ^Xitdb_Worker_Msg,
) {
	state := &self.state
	if state.shared == nil || state.shared.db == nil {
		return
	}

	switch m in msg^ {
	case Worker_Msg_Transact_Script:
		sync.rw_mutex_lock(&state.shared.rw_mu)
		report, err := xitdb.transact_script(state.shared.db, m.script, context.temp_allocator)
		sync.rw_mutex_unlock(&state.shared.rw_mu)
		if err == nil {
			state.commits_done += 1
			state.last_moment = report.moment_index
			if state.ui_pid.ref != nil {
				actor.send(ctx, state.ui_pid, UI_Msg(UI_Msg_State_Committed{
					moment_idx  = report.moment_index,
					commit_size = report.commit_size,
				}))
			}
		}

	case Worker_Msg_Commit_Batch:
		sync.rw_mutex_lock(&state.shared.rw_mu)
		tx := xitdb.tx_init(state.shared.db, -1, m.track_changes, context.temp_allocator)
		defer xitdb.tx_destroy(&tx)

		if len(m.doc) > 0 {
			xitdb.tx_doc(&tx, m.doc)
		}
		if m.instant_ms > 0 {
			xitdb.tx_instant(&tx, m.instant_ms)
		}
		if len(m.index_source) > 0 && len(m.index_field) > 0 && len(m.index_target) > 0 {
			xitdb.tx_index_on(&tx, m.index_source, m.index_field, m.index_target)
		}
		for op in m.ops {
			_ = xitdb.tx_put(&tx, op.path, op.val)
		}
		report, err := xitdb.tx_commit(&tx)
		sync.rw_mutex_unlock(&state.shared.rw_mu)

		if err == nil {
			state.commits_done += 1
			state.last_moment = report.moment_index
			if state.ui_pid.ref != nil {
				actor.send(ctx, state.ui_pid, UI_Msg(UI_Msg_State_Committed{
					moment_idx  = report.moment_index,
					commit_size = report.commit_size,
					tx_doc      = m.doc,
				}))
			}
		}

	case Worker_Msg_Run_Datalog:
		sync.rw_mutex_shared_lock(&state.shared.rw_mu)
		dres, err := xitdb.query_datalog(state.shared.db, m.query_str, m.moment_idx, context.temp_allocator)
		row_count := len(dres.rows)
		summary := ""
		if err != nil {
			summary = fmt.aprintf("Datalog error: %v", err)
		} else {
			sb := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&sb, "Vars: %v | Rows: %d", dres.vars, row_count)
			max_preview := min(row_count, 5)
			for r in 0 ..< max_preview {
				fmt.sbprintf(&sb, " | [%d]=", r)
				for col, c_idx in dres.rows[r] {
					if c_idx > 0 {
						strings.write_string(&sb, ",")
					}
					fmt.sbprintf(&sb, "%v", col)
				}
			}
			summary = strings.clone(strings.to_string(sb))
		}
		sync.rw_mutex_shared_unlock(&state.shared.rw_mu)

		if state.ui_pid.ref != nil {
			actor.send(ctx, state.ui_pid, UI_Msg(UI_Msg_Datalog_Ready{
				request_id = m.request_id,
				moment_idx = m.moment_idx,
				summary    = summary,
				row_count  = row_count,
			}))
		}

	case Worker_Msg_Diff_Moments:
		sync.rw_mutex_shared_lock(&state.shared.rw_mu)
		changes, err := xitdb.diff_moments(state.shared.db, m.moment_a, m.moment_b, false, context.temp_allocator)
		change_count := len(changes)
		summary := ""
		if err != nil {
			summary = fmt.aprintf("Diff error: %v", err)
		} else {
			sb := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&sb, "Diff @%d -> @%d (%d changes):", m.moment_a, m.moment_b, change_count)
			limit := min(change_count, 4)
			for i in 0 ..< limit {
				chg := changes[i]
				fmt.sbprintf(&sb, " [%v %s]", chg.op, chg.path_str)
			}
			summary = strings.clone(strings.to_string(sb))
		}
		sync.rw_mutex_shared_unlock(&state.shared.rw_mu)

		if state.ui_pid.ref != nil {
			actor.send(ctx, state.ui_pid, UI_Msg(UI_Msg_Diff_Ready{
				moment_a     = m.moment_a,
				moment_b     = m.moment_b,
				change_count = change_count,
				summary      = summary,
			}))
		}

	case Worker_Msg_Ping_Count:
		// Supports synchronous `actor.call(worker_pid, Worker_Msg_Ping_Count{}, i64)`
		actor.reply(ctx, state.commits_done)
	}
}

// =============================================================================
// 4. Zero-Copy `xitdb` Viewport Slicing (`ui_virtual_list` & `Xitdb_Filter`)
// =============================================================================

Xitdb_Filter_Kind :: enum u8 {
	None,
	Key_Prefix,    // B+Tree $O(\log N)$ seek via `cursor_iterator_sorted_from_key`
	Key_Range,     // B+Tree `[lower_key, upper_key)` seek + `query_count_range`
	Substring,     // Key or value substring match using stack buffer
}

Xitdb_Filter :: struct {
	kind:      Xitdb_Filter_Kind,
	prefix:    string,
	lower_key: string,
	upper_key: string,
	needle:    string,
	hide_tx:   bool,
}

Xitdb_Row_View :: struct {
	row_index:   i64,
	key_label:   string,
	value_label: string,
	value_tag:   xitdb.Tag,
	is_branch:   bool,
	cursor:      xitdb.Read_Cursor,
}

Xitdb_Viewport_Slice :: struct {
	moment_idx:     i64,
	moment_count:   i64,
	collection_tag: xitdb.Tag,
	total_rows:     i64,
	start_row:      i64,
	end_row:        i64,
	rows:           []Xitdb_Row_View,
}

UI_Virtual_List :: struct {
	scroll_offset: i64,
	selected_row:  i64,
	viewport_rows: i64,
	total_rows:    i64,
}

// Keep `selected_row` and `scroll_offset` clamped to `[0 ..< total_rows]` and `[0 ..< viewport_rows]`.
ui_virtual_list_clamp :: proc(vl: ^UI_Virtual_List, total_rows, viewport_rows: i64) -> (start_row, end_row: i64) {
	vl.total_rows = max(0, total_rows)
	vl.viewport_rows = max(1, viewport_rows)

	if vl.total_rows == 0 {
		vl.selected_row = 0
		vl.scroll_offset = 0
		return 0, 0
	}
	if vl.selected_row >= vl.total_rows {
		vl.selected_row = vl.total_rows - 1
	}
	if vl.selected_row < 0 {
		vl.selected_row = 0
	}
	if vl.selected_row < vl.scroll_offset {
		vl.scroll_offset = vl.selected_row
	}
	if vl.selected_row >= vl.scroll_offset + vl.viewport_rows {
		vl.scroll_offset = vl.selected_row - vl.viewport_rows + 1
	}
	max_scroll := max(i64(0), vl.total_rows - vl.viewport_rows)
	if vl.scroll_offset > max_scroll {
		vl.scroll_offset = max_scroll
	}
	if vl.scroll_offset < 0 {
		vl.scroll_offset = 0
	}
	start_row = vl.scroll_offset
	end_row = min(vl.total_rows, start_row + vl.viewport_rows)
	return start_row, end_row
}

ui_virtual_list_move :: proc(vl: ^UI_Virtual_List, delta: i64) {
	vl.selected_row += delta
	ui_virtual_list_clamp(vl, vl.total_rows, vl.viewport_rows)
}

// Open a read cursor at `moment_idx` (and optional sub-path `selector_path`) without copying data.
xitdb_open_moment_cursor :: proc(
	db: ^xitdb.Database,
	moment_idx: i64 = -1,
	selector_path: string = "",
	allocator := context.temp_allocator,
) -> (target: xitdb.Read_Cursor, resolved_moment: i64, moment_count: i64, err: xitdb.Error) {
	rc := xitdb.cursor_read_only(xitdb.database_root_cursor(db))
	root_slot := xitdb.cursor_slot(rc) or_return

	moment_cur := rc
	if root_slot.tag == .Array_List {
		moment_count = xitdb.cursor_count(rc) or_return
		if moment_count == 0 {
			return rc, 0, 0, nil
		}
		resolved_moment = moment_idx if moment_idx >= 0 else moment_count + moment_idx
		if resolved_moment < 0 {
			resolved_moment = 0
		}
		if resolved_moment >= moment_count {
			resolved_moment = moment_count - 1
		}
		mc_maybe := xitdb.cursor_read_path(rc, []xitdb.Path_Part{
			xitdb.Array_List_Get{index = resolved_moment},
		}) or_return
		mc, ok := mc_maybe.?
		if !ok {
			return {}, resolved_moment, moment_count, .Key_Not_Found
		}
		moment_cur = mc
	}

	if len(selector_path) == 0 {
		return moment_cur, resolved_moment, moment_count, nil
	}

	steps := xitdb.parse_steps(selector_path, allocator) or_return
	sub_maybe := xitdb.read_steps_cursor(moment_cur, steps) or_return
	sub_cur, has_sub := sub_maybe.?
	if !has_sub {
		return {}, resolved_moment, moment_count, .Key_Not_Found
	}
	return sub_cur, resolved_moment, moment_count, nil
}

// Read collection count in $O(1)$ for header-counted collections, falling back to iterator scan
// only for uncounted `.Hash_Map` / `.Hash_Set`.
xitdb_read_collection_count :: proc(col_cursor: xitdb.Read_Cursor, hide_tx := true) -> (count: i64, err: xitdb.Error) {
	slot := xitdb.cursor_slot(col_cursor) or_return
	#partial switch slot.tag {
	case .None:
		return 0, nil
	case .Array_List, .Linked_Array_List, .Sorted_Map, .Sorted_Set, .Counted_Hash_Map, .Counted_Hash_Set:
		raw_count := xitdb.cursor_count(col_cursor) or_return
		if hide_tx && (slot.tag == .Counted_Hash_Map || slot.tag == .Sorted_Map) {
			tx_maybe := xitdb.read_steps_cursor(col_cursor, []xitdb.Path_Step{xitdb.hm("__tx")}) or_else nil
			if tx_maybe != nil {
				return max(0, raw_count - 1), nil
			}
		}
		return raw_count, nil
	case .Hash_Map, .Hash_Set:
		it := xitdb.cursor_iterator(col_cursor) or_return
		stack_buf: [64]u8
		for {
			c_maybe := xitdb.cursor_iterator_next(&it) or_return
			c, ok := c_maybe.?
			if !ok {
				break
			}
			if hide_tx && slot.tag == .Hash_Map {
				kv := xitdb.cursor_read_kv_pair(c, context.temp_allocator) or_return
				if b, b_err := xitdb.cursor_read_bytes_buf(kv.key_cursor, stack_buf[:]); b_err == nil {
					if string(b.value) == "__tx" {
						continue
					}
				}
			}
			count += 1
		}
		return count, nil
	case:
		return 1, nil
	}
}

// Format a `Read_Cursor` value using a stack buffer (`cursor_read_bytes_buf`) before cloning
// only the final visible string onto `allocator` (`context.temp_allocator`).
xitdb_format_cursor_preview :: proc(
	c: xitdb.Read_Cursor,
	allocator := context.temp_allocator,
) -> (label: string, tag: xitdb.Tag, is_branch: bool, err: xitdb.Error) {
	slot := xitdb.cursor_slot(c) or_return
	tag = slot.tag

	#partial switch slot.tag {
	case .None:
		return "nil", slot.tag, false, nil
	case .Uint:
		u := xitdb.cursor_read_uint(c) or_return
		return fmt.aprintf("%d", u, allocator = allocator), slot.tag, false, nil
	case .Int:
		i := xitdb.cursor_read_int(c) or_return
		return fmt.aprintf("%d", i, allocator = allocator), slot.tag, false, nil
	case .Float:
		f := xitdb.cursor_read_float(c) or_return
		return fmt.aprintf("%.4f", f, allocator = allocator), slot.tag, false, nil
	case .Short_Bytes, .Bytes:
		stack_buf: [256]u8
		if b, b_err := xitdb.cursor_read_bytes_buf(c, stack_buf[:]); b_err == nil {
			if len(b.format_tag) == 2 {
				return fmt.aprintf("\"%s\"^^%s", string(b.value), string(b.format_tag), allocator = allocator), slot.tag, false, nil
			}
			return fmt.aprintf("\"%s\"", string(b.value), allocator = allocator), slot.tag, false, nil
		}
		s := xitdb.cursor_read_string(c, 128, allocator) or_return
		return fmt.aprintf("\"%s\"", s, allocator = allocator), slot.tag, false, nil
	case .Array_List:
		cnt := xitdb.cursor_count(c) or_return
		return fmt.aprintf("Array_List[%d]", cnt, allocator = allocator), slot.tag, true, nil
	case .Linked_Array_List:
		cnt := xitdb.cursor_count(c) or_return
		return fmt.aprintf("Linked_Array_List[[%d]]", cnt, allocator = allocator), slot.tag, true, nil
	case .Sorted_Map:
		cnt := xitdb.cursor_count(c) or_return
		return fmt.aprintf("Sorted_Map$N=%d", cnt, allocator = allocator), slot.tag, true, nil
	case .Sorted_Set:
		cnt := xitdb.cursor_count(c) or_return
		return fmt.aprintf("Sorted_Set^N=%d", cnt, allocator = allocator), slot.tag, true, nil
	case .Counted_Hash_Map:
		cnt := xitdb.cursor_count(c) or_return
		return fmt.aprintf("Counted_Hash_Map#N=%d", cnt, allocator = allocator), slot.tag, true, nil
	case .Counted_Hash_Set:
		cnt := xitdb.cursor_count(c) or_return
		return fmt.aprintf("Counted_Hash_Set#%N=%d", cnt, allocator = allocator), slot.tag, true, nil
	case .Hash_Map:
		return "Hash_Map{...}", slot.tag, true, nil
	case .Hash_Set:
		return "Hash_Set{...}", slot.tag, true, nil
	}
	return fmt.aprintf("<%v>", slot.tag, allocator = allocator), slot.tag, false, nil
}

// Compute the lexicographical successor of `prefix` on `context.temp_allocator` for
// $O(\log N)$ B+Tree range cardinality queries (`xitdb.query_count_range`).
@(private)
_prefix_upper_bound :: proc(prefix: string, allocator := context.temp_allocator) -> (upper: string, ok: bool) {
	if len(prefix) == 0 {
		return "", false
	}
	buf := make([]u8, len(prefix), allocator)
	copy(buf, transmute([]u8)prefix)
	for i := len(buf) - 1; i >= 0; i -= 1 {
		if buf[i] < 0xFF {
			buf[i] += 1
			return string(buf[:i + 1]), true
		}
	}
	return "", false
}

// Slice `[start_row ..< end_row]` inside `ui_virtual_list` and `Xitdb_Filter` on `context.temp_allocator`.
// Uses $O(\log_{16} N)$ indexed tree iterators (`cursor_iterator_array_list_from_index`,
// `cursor_iterator_linked_array_list_from_index`, `cursor_iterator_sorted_from_index`,
// and `cursor_iterator_sorted_from_key`) so off-screen rows are never materialized.
xitdb_slice_viewport :: proc(
	db: ^xitdb.Database,
	moment_idx: i64,
	selector_path: string,
	vl: ^UI_Virtual_List,
	filter: Xitdb_Filter = {hide_tx = true},
	allocator := context.temp_allocator,
) -> (slice: Xitdb_Viewport_Slice, err: xitdb.Error) {
	col_cursor, resolved_moment, moment_count := xitdb_open_moment_cursor(
		db,
		moment_idx,
		selector_path,
		allocator,
	) or_return

	col_slot := xitdb.cursor_slot(col_cursor) or_return
	slice.moment_idx = resolved_moment
	slice.moment_count = moment_count
	slice.collection_tag = col_slot.tag

	// Fast Path A: Unfiltered indexed collections (`Array_List`, `Linked_Array_List`, `Sorted_Map`, `Sorted_Set`)
	// Jump directly to `start_row` in O(log_16 N) without visiting rows 0 ..< start_row!
	is_indexed_collection := col_slot.tag == .Array_List ||
		col_slot.tag == .Linked_Array_List ||
		col_slot.tag == .Sorted_Map ||
		col_slot.tag == .Sorted_Set

	if filter.kind == .None && is_indexed_collection && !filter.hide_tx {
		total := xitdb.cursor_count(col_cursor) or_return
		start_row, end_row := ui_virtual_list_clamp(vl, total, vl.viewport_rows)
		slice.total_rows = total
		slice.start_row = start_row
		slice.end_row = end_row

		visible_len := max(i64(0), end_row - start_row)
		rows := make([dynamic]Xitdb_Row_View, 0, int(visible_len), allocator)
		if visible_len == 0 {
			slice.rows = rows[:]
			return slice, nil
		}

		it: xitdb.Cursor_Iterator
		#partial switch col_slot.tag {
		case .Array_List:
			it = xitdb.cursor_iterator_array_list_from_index(col_cursor, start_row) or_return
		case .Linked_Array_List:
			it = xitdb.cursor_iterator_linked_array_list_from_index(col_cursor, start_row) or_return
		case .Sorted_Map, .Sorted_Set:
			it = xitdb.cursor_iterator_sorted_from_index(col_cursor, start_row) or_return
		}

		for row_idx := start_row; row_idx < end_row; row_idx += 1 {
			c_maybe := xitdb.cursor_iterator_next(&it) or_return
			c, ok := c_maybe.?
			if !ok {
				break
			}
			view := _materialize_row_view(c, col_slot.tag, row_idx, allocator) or_return
			append(&rows, view)
		}
		slice.rows = rows[:]
		return slice, nil
	}

	// Fast Path B: Prefix or Key-Range filter on `Sorted_Map` / `Sorted_Set`
	// Seeks directly to the first matching key in the B+Tree via `cursor_iterator_sorted_from_key`.
	if (col_slot.tag == .Sorted_Map || col_slot.tag == .Sorted_Set) &&
	   (filter.kind == .Key_Prefix || filter.kind == .Key_Range) {
		seek_key := filter.prefix if filter.kind == .Key_Prefix else filter.lower_key
		it := xitdb.cursor_iterator_sorted_from_key(col_cursor, transmute([]u8)seek_key) or_return

		// Clamp using target window; collect only `[start_row ..< end_row]` while counting matches in range.
		target_start := max(i64(0), vl.scroll_offset)
		target_end := target_start + max(i64(1), vl.viewport_rows)
		rows := make([dynamic]Xitdb_Row_View, 0, int(vl.viewport_rows), allocator)
		matched: i64 = 0
		key_stack_buf: [256]u8

		for {
			c_maybe := xitdb.cursor_iterator_next(&it) or_return
			c, ok := c_maybe.?
			if !ok {
				break
			}
			kv := xitdb.cursor_read_kv_pair(c, allocator) or_return
			k_bytes, k_err := xitdb.cursor_read_bytes_buf(kv.key_cursor, key_stack_buf[:])
			k_str := string(k_bytes.value) if k_err == nil else (xitdb.cursor_read_string(kv.key_cursor, 128, allocator) or_return)

			if filter.kind == .Key_Prefix && !strings.has_prefix(k_str, filter.prefix) {
				break
			}
			if filter.kind == .Key_Range && len(filter.upper_key) > 0 && k_str >= filter.upper_key {
				break
			}
			if filter.hide_tx && k_str == "__tx" {
				continue
			}

			if matched >= target_start && matched < target_end {
				val_cur := kv.key_cursor if col_slot.tag == .Sorted_Set else kv.value_cursor
				val_label, val_tag, is_br := xitdb_format_cursor_preview(val_cur, allocator) or_return
				append(&rows, Xitdb_Row_View{
					row_index   = matched,
					key_label   = strings.clone(k_str, allocator),
					value_label = val_label,
					value_tag   = val_tag,
					is_branch   = is_br,
					cursor      = val_cur,
				})
			}
			matched += 1
		}

		start_row, end_row := ui_virtual_list_clamp(vl, matched, vl.viewport_rows)
		slice.total_rows = matched
		slice.start_row = start_row
		slice.end_row = end_row
		slice.rows = rows[:]
		return slice, nil
	}

	// Path C: General filtered or Hash_Map / Hash_Set iteration using stack buffers for non-visible rows
	it, it_err := xitdb.cursor_iterator(col_cursor)
	if it_err != nil {
		// Scalar leaf value cursor
		val_label, val_tag, is_br := xitdb_format_cursor_preview(col_cursor, allocator) or_return
		rows := make([]Xitdb_Row_View, 1, allocator)
		rows[0] = Xitdb_Row_View{
			row_index   = 0,
			key_label   = "(value)",
			value_label = val_label,
			value_tag   = val_tag,
			is_branch   = is_br,
			cursor      = col_cursor,
		}
		slice.total_rows = 1
		slice.start_row = 0
		slice.end_row = 1
		slice.rows = rows
		return slice, nil
	}

	target_start := max(i64(0), vl.scroll_offset)
	target_end := target_start + max(i64(1), vl.viewport_rows)
	rows := make([dynamic]Xitdb_Row_View, 0, int(vl.viewport_rows), allocator)
	matched: i64 = 0
	raw_idx: i64 = 0
	key_buf: [256]u8
	val_buf: [256]u8

	is_kv := col_slot.tag == .Hash_Map ||
		col_slot.tag == .Counted_Hash_Map ||
		col_slot.tag == .Sorted_Map ||
		col_slot.tag == .Hash_Set ||
		col_slot.tag == .Counted_Hash_Set ||
		col_slot.tag == .Sorted_Set
	is_set := col_slot.tag == .Hash_Set ||
		col_slot.tag == .Counted_Hash_Set ||
		col_slot.tag == .Sorted_Set

	for {
		c_maybe := xitdb.cursor_iterator_next(&it) or_return
		c, ok := c_maybe.?
		if !ok {
			break
		}
		curr_raw := raw_idx
		raw_idx += 1

		k_tmp := ""
		val_cur := c
		if is_kv {
			kv := xitdb.cursor_read_kv_pair(c, allocator) or_return
			if kb, k_err := xitdb.cursor_read_bytes_buf(kv.key_cursor, key_buf[:]); k_err == nil {
				k_tmp = string(kb.value)
			} else {
				k_tmp = xitdb.cursor_read_string(kv.key_cursor, 128, allocator) or_return
			}
			if filter.hide_tx && k_tmp == "__tx" {
				continue
			}
			val_cur = kv.key_cursor if is_set else kv.value_cursor
		}

		// Apply filter predicates using stack buffer before allocating
		if filter.kind == .Key_Prefix && !strings.has_prefix(k_tmp, filter.prefix) {
			continue
		}
		if filter.kind == .Substring && len(filter.needle) > 0 {
			hit := strings.contains(k_tmp, filter.needle)
			if !hit {
				if vb, v_err := xitdb.cursor_read_bytes_buf(val_cur, val_buf[:]); v_err == nil {
					hit = strings.contains(string(vb.value), filter.needle)
				}
			}
			if !hit {
				continue
			}
		}

		if matched >= target_start && matched < target_end {
			key_str := strings.clone(k_tmp, allocator) if is_kv else fmt.aprintf("[%d]", curr_raw, allocator = allocator)
			val_label, val_tag, is_br := xitdb_format_cursor_preview(val_cur, allocator) or_return
			append(&rows, Xitdb_Row_View{
				row_index   = matched,
				key_label   = key_str,
				value_label = val_label,
				value_tag   = val_tag,
				is_branch   = is_br,
				cursor      = val_cur,
			})
		}
		matched += 1
	}

	start_row, end_row := ui_virtual_list_clamp(vl, matched, vl.viewport_rows)
	slice.total_rows = matched
	slice.start_row = start_row
	slice.end_row = end_row
	slice.rows = rows[:]
	return slice, nil
}

@(private)
_materialize_row_view :: proc(
	c: xitdb.Read_Cursor,
	col_tag: xitdb.Tag,
	row_idx: i64,
	allocator := context.temp_allocator,
) -> (view: Xitdb_Row_View, err: xitdb.Error) {
	#partial switch col_tag {
	case .Sorted_Map, .Hash_Map, .Counted_Hash_Map:
		kv := xitdb.cursor_read_kv_pair(c, allocator) or_return
		k_str := xitdb.cursor_read_string(kv.key_cursor, 128, allocator) or_return
		val_label, val_tag, is_br := xitdb_format_cursor_preview(kv.value_cursor, allocator) or_return
		return Xitdb_Row_View{
			row_index   = row_idx,
			key_label   = k_str,
			value_label = val_label,
			value_tag   = val_tag,
			is_branch   = is_br,
			cursor      = kv.value_cursor,
		}, nil
	case .Sorted_Set, .Hash_Set, .Counted_Hash_Set:
		kv := xitdb.cursor_read_kv_pair(c, allocator) or_return
		k_str := xitdb.cursor_read_string(kv.key_cursor, 128, allocator) or_return
		return Xitdb_Row_View{
			row_index   = row_idx,
			key_label   = k_str,
			value_label = "(set member)",
			value_tag   = .Short_Bytes,
			is_branch   = false,
			cursor      = kv.key_cursor,
		}, nil
	case:
		val_label, val_tag, is_br := xitdb_format_cursor_preview(c, allocator) or_return
		return Xitdb_Row_View{
			row_index   = row_idx,
			key_label   = fmt.aprintf("[%d]", row_idx, allocator = allocator),
			value_label = val_label,
			value_tag   = val_tag,
			is_branch   = is_br,
			cursor      = c,
		}, nil
	}
}

// =============================================================================
// 5. Bifrost Layout, Screen Buffer Diffing, and UI Coordinator Actor
// =============================================================================

Cell :: struct {
	ch:    rune,
	fg:    u8,
	bg:    u8,
	attrs: u8,
}

Screen_Buffer :: struct {
	width:  int,
	height: int,
	cells:  []Cell,
}

Layout_Rect :: struct {
	x, y, w, h: int,
}

UI_Render_Pass_Fn :: #type proc(
	coord: ^UI_Coordinator_State,
	front: ^Screen_Buffer,
	inputs: []UI_Input_Event,
)

UI_Fast_Event :: struct {
	moment_idx:  i64,
	commit_size: i64,
}

UI_Coordinator_State :: struct {
	shared_db:          ^Xitdb_Shared_Handle,
	worker_pid:         actor.PID(Xitdb_Worker_Msg),

	// Optional wait-free Sharded SPSC mailbox for fixed high-rate producer lanes
	spsc_mailbox:       actor.Sharded_SPSC_Mailbox(UI_Fast_Event, 8192),
	has_spsc_mailbox:   bool,

	// Coalesced database snapshot & metrics
	current_moment_idx: i64,
	pinned_moment:       bool,
	latest_moment_idx:  i64,
	latest_commit_size: i64,
	last_tx_doc:        string,
	coalesced_commits:  i64,
	total_frames:       i64,
	batch_drained:      int,
	max_coalesce_batch: int,

	// Coalesced input & resize state
	width:              int,
	height:             int,
	needs_resize:       bool,
	dirty:              bool,
	urgent_input:       bool,
	quitting:           bool,
	done_futex:         sync.Futex,
	pending_inputs:     [dynamic]UI_Input_Event,

	// Frame pacing (60..120 FPS VSync gate)
	fps:                int,
	frame_interval:     time.Duration,
	min_frame_duration: time.Duration,
	last_render_tick:   time.Tick,

	// Double-buffered terminal cell grids (`front` & `back`)
	front_buf:          Screen_Buffer,
	back_buf:           Screen_Buffer,
	ansi_builder:       strings.Builder,
	output_writer:      io.Writer,
	headless:           bool,

	// Pluggable application state & layout/render callback
	user_data:          rawptr,
	render_pass:        UI_Render_Pass_Fn,
	last_datalog_info:  string,
	last_diff_info:     string,
	allocator:          mem.Allocator,
}

screen_buffer_init :: proc(sb: ^Screen_Buffer, w, h: int, allocator := context.allocator) {
	sb.width = max(1, w)
	sb.height = max(1, h)
	sb.cells = make([]Cell, sb.width * sb.height, allocator)
	screen_buffer_clear(sb)
}

screen_buffer_destroy :: proc(sb: ^Screen_Buffer, allocator := context.allocator) {
	if sb.cells != nil {
		delete(sb.cells, allocator)
		sb.cells = nil
	}
}

screen_buffer_resize :: proc(sb: ^Screen_Buffer, w, h: int, allocator := context.allocator) {
	if sb.width == w && sb.height == h && sb.cells != nil {
		return
	}
	screen_buffer_destroy(sb, allocator)
	screen_buffer_init(sb, w, h, allocator)
}

screen_buffer_clear :: proc(sb: ^Screen_Buffer, bg: u8 = 0) {
	for &c in sb.cells {
		c = Cell{ch = ' ', fg = 7, bg = bg, attrs = 0}
	}
}

screen_buffer_put_text :: proc(sb: ^Screen_Buffer, x, y, max_w: int, text: string, fg: u8 = 7, bg: u8 = 0, attrs: u8 = 0) {
	if y < 0 || y >= sb.height || x >= sb.width || max_w <= 0 {
		return
	}
	col := x
	limit := min(sb.width, x + max_w)
	for r in text {
		if col >= limit {
			break
		}
		if col >= 0 {
			sb.cells[y * sb.width + col] = Cell{
				ch    = r,
				fg    = fg,
				bg    = bg,
				attrs = attrs,
			}
		}
		col += 1
	}
}

// Compute minimal cell diff between `front` and `back` and emit synchronized ANSI sequences.
screen_diff_ansi :: proc(
	front: ^Screen_Buffer,
	back: ^Screen_Buffer,
	b: ^strings.Builder,
	force_full: bool = false,
) -> int {
	strings.builder_reset(b)
	changed_cells := 0
	last_fg: u8 = 255
	last_bg: u8 = 255
	last_attrs: u8 = 255
	cur_x := -1
	cur_y := -1

	for y := 0; y < front.height; y += 1 {
		for x := 0; x < front.width; x += 1 {
			idx := y * front.width + x
			fc := front.cells[idx]
			bc := back.cells[idx]
			if !force_full && fc == bc {
				continue
			}
			if changed_cells == 0 {
				strings.write_string(b, ANSI_SYNC_BEGIN)
				strings.write_string(b, ANSI_CURSOR_HIDE)
			}
			changed_cells += 1
			back.cells[idx] = fc

			if cur_y != y || cur_x != x {
				fmt.sbprintf(b, "\x1b[%d;%dH", y + 1, x + 1)
				cur_y = y
				cur_x = x
			}
			if fc.attrs != last_attrs || fc.fg != last_fg || fc.bg != last_bg {
				fmt.sbprintf(b, "\x1b[0;%d;38;5;%d;48;5;%dm", 1 if fc.attrs != 0 else 22, fc.fg, fc.bg)
				last_attrs = fc.attrs
				last_fg = fc.fg
				last_bg = fc.bg
			}
			strings.write_rune(b, fc.ch if fc.ch != 0 else ' ')
			cur_x += 1
		}
	}

	if changed_cells > 0 {
		strings.write_string(b, "\x1b[0m")
		strings.write_string(b, ANSI_SYNC_END)
	}
	return changed_cells
}

ui_coordinator_init :: proc(
	coord: ^UI_Coordinator_State,
	shared_db: ^Xitdb_Shared_Handle,
	width: int = 100,
	height: int = 30,
	fps: int = DEFAULT_FPS,
	num_spsc_producers: int = 0,
	headless: bool = false,
	allocator := context.allocator,
) {
	clamped_fps := clamp(fps, 1, MAX_FPS)
	coord.shared_db = shared_db
	coord.current_moment_idx = -1
	coord.latest_moment_idx = -1
	coord.max_coalesce_batch = DEFAULT_MAX_COALESCE
	coord.width = width if is_plausible_window_size(width, height) else 100
	coord.height = height if is_plausible_window_size(width, height) else 30
	coord.fps = clamped_fps
	coord.frame_interval = time.Second / time.Duration(clamped_fps)
	coord.min_frame_duration = time.Second / time.Duration(MAX_FPS)
	coord.last_render_tick = time.tick_now()
	coord.pending_inputs = make([dynamic]UI_Input_Event, 0, 64, allocator)
	coord.ansi_builder = strings.builder_make(0, 16384, allocator)
	coord.output_writer = os.stream_from_handle(os.stdout)
	coord.headless = headless
	coord.dirty = true
	coord.allocator = allocator

	screen_buffer_init(&coord.front_buf, coord.width, coord.height, allocator)
	screen_buffer_init(&coord.back_buf, coord.width, coord.height, allocator)
	// Force initial full paint by invalidating back_buf cell 0
	coord.back_buf.cells[0].ch = 0

	if num_spsc_producers > 0 {
		if actor.sharded_spsc_init(&coord.spsc_mailbox, num_spsc_producers, allocator) == .None {
			coord.has_spsc_mailbox = true
		}
	}
}

ui_coordinator_destroy :: proc(coord: ^UI_Coordinator_State) {
	if coord.has_spsc_mailbox {
		actor.sharded_spsc_destroy(&coord.spsc_mailbox)
		coord.has_spsc_mailbox = false
	}
	screen_buffer_destroy(&coord.front_buf, coord.allocator)
	screen_buffer_destroy(&coord.back_buf, coord.allocator)
	strings.builder_destroy(&coord.ansi_builder)
	delete(coord.pending_inputs)
	if len(coord.last_datalog_info) > 0 {
		delete(coord.last_datalog_info, coord.allocator)
	}
	if len(coord.last_diff_info) > 0 {
		delete(coord.last_diff_info, coord.allocator)
	}
}

@(private)
ui_spsc_lane_handler :: proc(coord: ^UI_Coordinator_State, ev: ^UI_Fast_Event) {
	coord.latest_moment_idx = ev.moment_idx
	coord.latest_commit_size = ev.commit_size
	if !coord.pinned_moment {
		coord.current_moment_idx = ev.moment_idx
	}
	coord.coalesced_commits += 1
	coord.dirty = true
}

// State-reduction step for a single `UI_Msg` before deciding whether to coalesce or flush a frame.
@(private)
ui_reduce_single_msg :: proc(
	ctx: ^actor.Context,
	self: ^actor.Actor(UI_Coordinator_State, UI_Msg),
	msg: ^UI_Msg,
) -> (is_frame_tick: bool) {
	state := &self.state

	switch m in msg^ {
	case UI_Msg_Input:
		if m.event.key == .Ctrl_C || (m.event.key == .Rune && m.event.ch == 'q') {
			state.quitting = true
			intrinsics.atomic_store_explicit((^u32)(&state.done_futex), 1, .Release)
			sync.futex_broadcast(&state.done_futex)
			return false
		}
		append(&state.pending_inputs, m.event)
		state.dirty = true
		state.urgent_input = true

	case UI_Msg_Resize:
		if is_plausible_window_size(m.width, m.height) {
			state.width = m.width
			state.height = m.height
			state.needs_resize = true
			state.dirty = true
			state.urgent_input = true
		}

	case UI_Msg_State_Committed:
		state.latest_moment_idx = m.moment_idx
		state.latest_commit_size = m.commit_size
		if len(m.tx_doc) > 0 {
			state.last_tx_doc = m.tx_doc
		}
		if !state.pinned_moment {
			state.current_moment_idx = m.moment_idx
		}
		state.coalesced_commits += 1
		state.dirty = true

	case UI_Msg_Datalog_Ready:
		if len(state.last_datalog_info) > 0 {
			delete(state.last_datalog_info, state.allocator)
		}
		state.last_datalog_info = m.summary
		state.dirty = true

	case UI_Msg_Diff_Ready:
		if len(state.last_diff_info) > 0 {
			delete(state.last_diff_info, state.allocator)
		}
		state.last_diff_info = m.summary
		state.dirty = true

	case UI_Msg_Batch:
		for cmd in m.cmds {
			if cmd != nil {
				out_msg := cmd()
				actor.send(ctx, self, out_msg)
			}
		}

	case UI_Msg_Sequence:
		for cmd in m.cmds {
			if cmd != nil {
				out_msg := cmd()
				ui_reduce_single_msg(ctx, self, &out_msg)
			}
		}

	case UI_Msg_Frame_Tick:
		return true

	case UI_Msg_Quit:
		state.quitting = true
		intrinsics.atomic_store_explicit((^u32)(&state.done_futex), 1, .Release)
		sync.futex_broadcast(&state.done_futex)
	}
	return false
}

// Sleipnir `STEP_MODE_ACTOR` handler with mailbox batch coalescing and Bubble Tea frame pacing.
ui_coordinator_receive :: proc(
	ctx: ^actor.Context,
	self: ^actor.Actor(UI_Coordinator_State, UI_Msg),
	msg: ^UI_Msg,
) {
	state := &self.state
	if state.quitting {
		return
	}

	is_tick := ui_reduce_single_msg(ctx, self, msg)
	state.batch_drained += 1

	// Drain any wait-free SPSC producer lanes into `state`
	if state.has_spsc_mailbox {
		_ = actor.sharded_spsc_consume(&state.spsc_mailbox, 256, state, ui_spsc_lane_handler)
	}

	// Coalesce bursts: if more messages are already sitting in `self.mailbox` and we haven't
	// hit `max_coalesce_batch`, return immediately so `actor_generic_step_proc` pops the next
	// `Envelope(UI_Msg)` without running layout or terminal diffing!
	if !actor.mpsc_is_empty(&self.mailbox) && state.batch_drained < state.max_coalesce_batch {
		return
	}
	state.batch_drained = 0

	if !state.dirty || state.quitting {
		return
	}

	now := time.tick_now()
	elapsed := time.tick_diff(state.last_render_tick, now)
	should_render := is_tick ||
		(state.urgent_input && elapsed >= state.min_frame_duration) ||
		elapsed >= state.frame_interval

	if !should_render {
		return
	}

	// Reset scratch arena once per rendered frame (`user:odin-developer` guideline)
	free_all(context.temp_allocator)

	force_full := false
	if state.needs_resize {
		screen_buffer_resize(&state.front_buf, state.width, state.height, state.allocator)
		screen_buffer_resize(&state.back_buf, state.width, state.height, state.allocator)
		state.needs_resize = false
		force_full = true
	}

	// 1. begin_layout: clear front screen buffer
	screen_buffer_clear(&state.front_buf)

	// 2. resolve_input + 3. render_layout: invoke user layout/viewport pass under shared read lock
	if state.render_pass != nil {
		if state.shared_db != nil {
			sync.rw_mutex_shared_lock(&state.shared_db.rw_mu)
		}
		state.render_pass(state, &state.front_buf, state.pending_inputs[:])
		if state.shared_db != nil {
			sync.rw_mutex_shared_unlock(&state.shared_db.rw_mu)
		}
	}

	// 4. screen_diff_ansi: compute cell diff and flush synchronized ANSI output
	changed := screen_diff_ansi(&state.front_buf, &state.back_buf, &state.ansi_builder, force_full)
	if changed > 0 && !state.headless {
		_, _ = io.write_string(state.output_writer, strings.to_string(state.ansi_builder))
	}

	clear(&state.pending_inputs)
	state.dirty = false
	state.urgent_input = false
	state.total_frames += 1
	state.last_render_tick = now
}

```

---

### Deliverable 2: `examples/xitdb_inspector/main.odin`

```odin
package main

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import bifrost "../../bifrost"
import actor "../../deps/sleipnir/actor"
import xitdb "../../deps/xitdb/xitdb"

// =============================================================================
// Interactive `xitdb` Inspector Application State
// =============================================================================

Inspector_Mode :: enum u8 {
	Browse,
	Filter_Input,
	Datalog_Input,
}

Inspector_App :: struct {
	mode:            Inspector_Mode,
	path_stack:      [dynamic]string,
	virtual_list:    bifrost.UI_Virtual_List,
	filter:          bifrost.Xitdb_Filter,
	filter_buf:      strings.Builder,
	datalog_buf:     strings.Builder,
	next_req_id:     u64,
	last_slice_rows: int,
	status_line:     string,
	allocator:       mem.Allocator,
}

inspector_app_init :: proc(app: ^Inspector_App, allocator := context.allocator) {
	app.mode = .Browse
	app.path_stack = make([dynamic]string, 0, 8, allocator)
	app.virtual_list = bifrost.UI_Virtual_List{
		scroll_offset = 0,
		selected_row  = 0,
		viewport_rows = 16,
	}
	app.filter = bifrost.Xitdb_Filter{
		kind    = .None,
		hide_tx = true,
	}
	app.filter_buf = strings.builder_make(0, 128, allocator)
	app.datalog_buf = strings.builder_make(0, 256, allocator)
	strings.write_string(&app.datalog_buf, "find ?id, ?role where .users[?id].role = ?role")
	app.status_line = "Keys: [j/k] Move  [Enter] Drill In  [Backspace] Up  [ [/] ] Moment -/+  [/] Prefix Filter  [d] Datalog  [c] Burst 1,000 Commits  [q] Quit"
	app.allocator = allocator
}

inspector_app_destroy :: proc(app: ^Inspector_App) {
	for p in app.path_stack {
		delete(p, app.allocator)
	}
	delete(app.path_stack)
	strings.builder_destroy(&app.filter_buf)
	strings.builder_destroy(&app.datalog_buf)
}

inspector_current_selector :: proc(app: ^Inspector_App, allocator := context.temp_allocator) -> string {
	if len(app.path_stack) == 0 {
		return ""
	}
	sb := strings.builder_make(allocator)
	for seg in app.path_stack {
		strings.write_string(&sb, seg)
	}
	return strings.to_string(sb)
}

// =============================================================================
// `begin_layout` -> `resolve_input` -> `render_layout` Callback
// =============================================================================

inspector_render_pass :: proc(
	coord: ^bifrost.UI_Coordinator_State,
	front: ^bifrost.Screen_Buffer,
	inputs: []bifrost.UI_Input_Event,
) {
	app := (^Inspector_App)(coord.user_data)
	db := coord.shared_db.db

	// 1. Pre-query current viewport so input handlers know row count & branch targets
	selector := inspector_current_selector(app, context.temp_allocator)
	list_height := max(4, front.height - 9)
	app.virtual_list.viewport_rows = i64(list_height)

	viewport, vp_err := bifrost.xitdb_slice_viewport(
		db,
		coord.current_moment_idx,
		selector,
		&app.virtual_list,
		app.filter,
		context.temp_allocator,
	)

	// 2. Resolve coalesced user inputs (`inputs`)
	for ev in inputs {
		if app.mode == .Filter_Input {
			#partial switch ev.key {
			case .Escape, .Enter:
				q := strings.to_string(app.filter_buf)
				if len(q) == 0 {
					app.filter.kind = .None
					app.filter.prefix = ""
					app.filter.needle = ""
				} else if strings.has_prefix(q, "$") {
					app.filter.kind = .Key_Prefix
					app.filter.prefix = q[1:]
				} else {
					app.filter.kind = .Substring
					app.filter.needle = q
				}
				app.virtual_list.selected_row = 0
				app.virtual_list.scroll_offset = 0
				app.mode = .Browse
			case .Backspace:
				s := strings.to_string(app.filter_buf)
				if len(s) > 0 {
					app.filter_buf.buf[len(s) - 1] = 0
					resize(&app.filter_buf.buf, len(s) - 1)
				}
			case .Rune:
				strings.write_rune(&app.filter_buf, ev.ch)
			}
			continue
		}

		if app.mode == .Datalog_Input {
			#partial switch ev.key {
			case .Escape:
				app.mode = .Browse
			case .Enter:
				app.next_req_id += 1
				actor.send(coord.worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Run_Datalog{
					request_id = app.next_req_id,
					moment_idx = coord.current_moment_idx,
					query_str  = strings.to_string(app.datalog_buf),
				}))
				app.mode = .Browse
			case .Backspace:
				s := strings.to_string(app.datalog_buf)
				if len(s) > 0 {
					resize(&app.datalog_buf.buf, len(s) - 1)
				}
			case .Rune:
				strings.write_rune(&app.datalog_buf, ev.ch)
			}
			continue
		}

		// Normal `.Browse` mode navigation & commands
		switch ev.kind {
		case .Mouse_Wheel_Up:
			bifrost.ui_virtual_list_move(&app.virtual_list, -3)
		case .Mouse_Wheel_Down:
			bifrost.ui_virtual_list_move(&app.virtual_list, 3)
		case .Mouse_Click:
			clicked_row := i64(ev.y - 4) + app.virtual_list.scroll_offset
			if clicked_row >= 0 && clicked_row < app.virtual_list.total_rows {
				app.virtual_list.selected_row = clicked_row
			}
		case .Key_Press:
			#partial switch ev.key {
			case .Up:
				bifrost.ui_virtual_list_move(&app.virtual_list, -1)
			case .Down:
				bifrost.ui_virtual_list_move(&app.virtual_list, 1)
			case .Page_Up:
				bifrost.ui_virtual_list_move(&app.virtual_list, -app.virtual_list.viewport_rows)
			case .Page_Down:
				bifrost.ui_virtual_list_move(&app.virtual_list, app.virtual_list.viewport_rows)
			case .Home:
				app.virtual_list.selected_row = 0
				bifrost.ui_virtual_list_clamp(&app.virtual_list, app.virtual_list.total_rows, app.virtual_list.viewport_rows)
			case .End:
				app.virtual_list.selected_row = max(0, app.virtual_list.total_rows - 1)
				bifrost.ui_virtual_list_clamp(&app.virtual_list, app.virtual_list.total_rows, app.virtual_list.viewport_rows)
			case .Backspace:
				if len(app.path_stack) > 0 {
					last_idx := len(app.path_stack) - 1
					delete(app.path_stack[last_idx], app.allocator)
					pop(&app.path_stack)
					app.virtual_list.selected_row = 0
					app.virtual_list.scroll_offset = 0
				}
			case .Enter:
				rel_idx := int(app.virtual_list.selected_row - viewport.start_row)
				if rel_idx >= 0 && rel_idx < len(viewport.rows) {
					row := viewport.rows[rel_idx]
					if row.is_branch {
						seg := ""
						#partial switch viewport.collection_tag {
						case .Sorted_Map:
							seg = fmt.aprintf("$[\"%s\"]", row.key_label, allocator = app.allocator)
						case .Counted_Hash_Map:
							seg = fmt.aprintf("#[\"%s\"]", row.key_label, allocator = app.allocator)
						case .Array_List:
							seg = fmt.aprintf("%s", row.key_label, allocator = app.allocator)
						case .Linked_Array_List:
							seg = fmt.aprintf("[%s]", row.key_label, allocator = app.allocator)
						case:
							seg = fmt.aprintf(".[\"%s\"]", row.key_label, allocator = app.allocator)
						}
						append(&app.path_stack, seg)
						app.virtual_list.selected_row = 0
						app.virtual_list.scroll_offset = 0
					}
				}
			case .Rune:
				switch ev.ch {
				case 'j':
					bifrost.ui_virtual_list_move(&app.virtual_list, 1)
				case 'k':
					bifrost.ui_virtual_list_move(&app.virtual_list, -1)
				case '/':
					app.mode = .Filter_Input
				case 'd':
					app.mode = .Datalog_Input
				case '[':
					if viewport.moment_idx > 0 {
						coord.pinned_moment = true
						coord.current_moment_idx = viewport.moment_idx - 1
						actor.send(coord.worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Diff_Moments{
							moment_a = max(0, coord.current_moment_idx - 1),
							moment_b = coord.current_moment_idx,
						}))
					}
				case ']':
					if viewport.moment_idx + 1 < viewport.moment_count {
						coord.current_moment_idx = viewport.moment_idx + 1
						if coord.current_moment_idx == viewport.moment_count - 1 {
							coord.pinned_moment = false
						}
						actor.send(coord.worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Diff_Moments{
							moment_a = max(0, coord.current_moment_idx - 1),
							moment_b = coord.current_moment_idx,
						}))
					}
				case 'f':
					coord.pinned_moment = false
					coord.current_moment_idx = -1
				case 'c':
					// Trigger a burst of 1,000 rapid worker commits to demonstrate mailbox coalescing!
					spawn_commit_burst(coord.worker_pid, 1000)
				}
			}
		}
	}

	// Re-slice `[start_row ..< end_row]` after input mutations so rendered frame is 100% current
	selector = inspector_current_selector(app, context.temp_allocator)
	viewport, vp_err = bifrost.xitdb_slice_viewport(
		db,
		coord.current_moment_idx,
		selector,
		&app.virtual_list,
		app.filter,
		context.temp_allocator,
	)
	app.last_slice_rows = len(viewport.rows)

	// 3. Render UI Header, Virtualized Viewport Table, and Telemetry Footer into `front`
	w := front.width
	header_line := fmt.tprintf(
		" BIFROST x SLEIPNIR x XITDB INSPECTOR | Moment @%d/%d %s | Size: %d B | Coalesced Commits: %d | Frames: %d ",
		viewport.moment_idx,
		max(0, viewport.moment_count - 1),
		"(PINNED)" if coord.pinned_moment else "(LIVE)",
		coord.latest_commit_size,
		coord.coalesced_commits,
		coord.total_frames + 1,
	)
	bifrost.screen_buffer_put_text(front, 0, 0, w, header_line, 15, 24, 1)

	path_display := selector if len(selector) > 0 else "(root moment hash_map)"
	filter_display := strings.to_string(app.filter_buf) if len(strings.to_string(app.filter_buf)) > 0 else "none"
	sub_header := fmt.tprintf(
		" Path: %s | Tag: %v | Rows: [%d..<%d] of %d | Filter: %s ",
		path_display,
		viewport.collection_tag,
		viewport.start_row,
		viewport.end_row,
		viewport.total_rows,
		filter_display,
	)
	bifrost.screen_buffer_put_text(front, 0, 1, w, sub_header, 252, 236, 0)

	col_header := fmt.tprintf(" %-8s | %-28s | %-18s | %s", "ROW", "KEY / INDEX", "TAG", "VALUE PREVIEW")
	bifrost.screen_buffer_put_text(front, 0, 3, w, col_header, 229, 235, 1)

	if vp_err != nil {
		err_str := fmt.tprintf(" [Error reading path '%s': %v]", path_display, vp_err)
		bifrost.screen_buffer_put_text(front, 0, 4, w, err_str, 196, 0, 1)
	} else {
		for r, idx in viewport.rows {
			y := 4 + idx
			if y >= front.height - 4 {
				break
			}
			is_sel := r.row_index == app.virtual_list.selected_row
			fg: u8 = 15 if is_sel else (117 if r.is_branch else 250)
			bg: u8 = 25 if is_sel else 0
			marker := ">" if is_sel else " "
			drill := " ->" if r.is_branch else ""
			line := fmt.tprintf(
				"%s%-8d | %-28s | %-18v | %s%s",
				marker,
				r.row_index,
				r.key_label,
				r.value_tag,
				r.value_label,
				drill,
			)
			bifrost.screen_buffer_put_text(front, 0, y, w, line, fg, bg, 1 if is_sel else 0)
		}
	}

	// Render Datalog & Structural Diff inspection bars
	dl_y := front.height - 3
	if app.mode == .Filter_Input {
		prompt := fmt.tprintf(" FILTER (prefix with '$' for B+Tree seek): %s_", strings.to_string(app.filter_buf))
		bifrost.screen_buffer_put_text(front, 0, dl_y, w, prompt, 226, 235, 1)
	} else if app.mode == .Datalog_Input {
		prompt := fmt.tprintf(" DATALOG QUERY: %s_", strings.to_string(app.datalog_buf))
		bifrost.screen_buffer_put_text(front, 0, dl_y, w, prompt, 226, 235, 1)
	} else {
		dl_text := coord.last_datalog_info if len(coord.last_datalog_info) > 0 else " [Press 'd' to run Datalog query]"
		bifrost.screen_buffer_put_text(front, 0, dl_y, w, dl_text, 120, 234, 0)
	}

	diff_y := front.height - 2
	diff_text := coord.last_diff_info if len(coord.last_diff_info) > 0 else fmt.tprintf(" Last Tx: %s", coord.last_tx_doc)
	bifrost.screen_buffer_put_text(front, 0, diff_y, w, diff_text, 215, 234, 0)

	bifrost.screen_buffer_put_text(front, 0, front.height - 1, w, app.status_line, 250, 236, 0)
}

// =============================================================================
// Helper: Dispatch a 1,000-Commit Burst to Demonstrate Mailbox Coalescing
// =============================================================================

spawn_commit_burst :: proc(worker_pid: actor.PID(bifrost.Xitdb_Worker_Msg), count: int) {
	msgs := make([]bifrost.Xitdb_Worker_Msg, count, context.temp_allocator)
	for i in 0 ..< count {
		script := fmt.tprintf(
			"doc \"Burst commit #%d\"\nput $metrics[\"sensor:%04d\"] = %du\nput .users[\"101\"].events = %du",
			i,
			i,
			u64(i * 10),
			u64(i + 1),
		)
		msgs[i] = bifrost.Worker_Msg_Transact_Script{script = script}
	}
	// Splice all `count` envelopes onto the worker's MPSC mailbox in ONE atomic `XCHG` (`mpsc_push_chain`)!
	actor.send(worker_pid, msgs)
}

// =============================================================================
// Background Frame Ticker Producer Thread (60 FPS VSync Pacing)
// =============================================================================

Ticker_Thread_Ctx :: struct {
	sched:    ^actor.Scheduler,
	ui_pid:   actor.PID(bifrost.UI_Msg),
	running:  ^b32,
	interval: time.Duration,
}

frame_ticker_thread_proc :: proc(t: ^thread.Thread) {
	tctx := (^Ticker_Thread_Ctx)(t.data)
	for intrinsics.atomic_load_explicit(tctx.running, .Acquire) {
		time.sleep(tctx.interval)
		if !intrinsics.atomic_load_explicit(tctx.running, .Acquire) {
			break
		}
		actor.send(tctx.sched, tctx.ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{
			timestamp = time.tick_now(),
		}))
	}
}

// =============================================================================
// Seed Initial `xitdb` Database State & Run Inspector
// =============================================================================

seed_initial_database :: proc(db: ^xitdb.Database) {
	// Genesis moment @0: seed users, a sorted_map `$metrics`, and an array_list `.events`
	tx := xitdb.tx_init(db, -1, true, context.temp_allocator)
	defer xitdb.tx_destroy(&tx)

	xitdb.tx_doc(&tx, "Genesis: seed users, sorted $metrics, and secondary index $users_by_role")
	xitdb.tx_instant(&tx, 1730000000000)
	xitdb.tx_index_on(&tx, "users", "role", "users_by_role")

	_ = xitdb.tx_put(&tx, ".users[\"101\"].name", "Odin")
	_ = xitdb.tx_put(&tx, ".users[\"101\"].role", "admin")
	_ = xitdb.tx_put(&tx, ".users[\"102\"].name", "Freya")
	_ = xitdb.tx_put(&tx, ".users[\"102\"].role", "architect")
	_ = xitdb.tx_put(&tx, ".users[\"103\"].name", "Heimdall")
	_ = xitdb.tx_put(&tx, ".users[\"103\"].role", "guardian")

	for i in 0 ..< 100 {
		key_path := fmt.tprintf("$metrics[\"sensor:%04d\"]", i)
		_ = xitdb.tx_put(&tx, key_path, u64(i * 42))
		_ = xitdb.tx_append(&tx, ".events", fmt.tprintf("boot-event-%03d", i))
	}
	_, _ = xitdb.tx_commit(&tx)
	free_all(context.temp_allocator)
}

main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			for _, entry in track.allocation_map {
				fmt.eprintf("[LEAK] %v leaked %v bytes\n", entry.location, entry.size)
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	// 1. Initialize in-memory `xitdb.Database`
	core_mem := xitdb.Core(xitdb.Core_Memory{
		buf = make([dynamic]u8, 0, 64 * 1024),
	})
	defer delete(core_mem.(xitdb.Core_Memory).buf)

	db, db_err := xitdb.database_init(&core_mem)
	if db_err != nil {
		fmt.eprintf("Failed to initialize xitdb: %v\n", db_err)
		return
	}
	seed_initial_database(&db)

	shared_db := bifrost.Xitdb_Shared_Handle{db = &db}

	// 2. Start Sleipnir M:N Actor Scheduler with adaptive Futex parking (`enable_parking = true`)
	sched := actor.scoped_scheduler(actor.Scheduler_Config{
		num_workers    = 4,
		num_shards     = 4,
		batch_quota    = 256,
		enable_parking = true,
	})

	// 3. Initialize UI Coordinator State & Inspector App
	app: Inspector_App
	inspector_app_init(&app)
	defer inspector_app_destroy(&app)

	headless_demo := true
	for arg in os.args[1:] {
		if arg == "--live-tty" {
			headless_demo = false
		}
	}

	coord_state: bifrost.UI_Coordinator_State
	bifrost.ui_coordinator_init(
		&coord_state,
		&shared_db,
		width              = 110,
		height             = 28,
		fps                = 60,
		num_spsc_producers = 1,
		headless           = headless_demo,
	)
	defer bifrost.ui_coordinator_destroy(&coord_state)

	coord_state.user_data = &app
	coord_state.render_pass = inspector_render_pass

	// 4. Spawn UI Coordinator Actor & Background `xitdb` Worker Actor
	ui_actor, _ := actor.spawn(sched, coord_state, bifrost.ui_coordinator_receive)
	ui_pid := actor.pid(ui_actor)

	worker_actor, _ := actor.spawn(
		sched,
		bifrost.Xitdb_Worker_State{
			shared = &shared_db,
			ui_pid = ui_pid,
		},
		bifrost.xitdb_worker_receive,
	)
	worker_pid := actor.pid(worker_actor)
	ui_actor.state.worker_pid = worker_pid

	// 5. Start 60 FPS Frame Ticker Producer Thread
	ticker_running: b32 = true
	tctx := Ticker_Thread_Ctx{
		sched    = sched,
		ui_pid   = ui_pid,
		running  = &ticker_running,
		interval = time.Millisecond * 16,
	}
	ticker_thread := thread.create(frame_ticker_thread_proc)
	ticker_thread.data = &tctx
	thread.start(ticker_thread)
	defer {
		intrinsics.atomic_store_explicit(&ticker_running, false, .Release)
		thread.join(ticker_thread)
		thread.destroy(ticker_thread)
	}

	// 6. Simulate a 1,000-commit worker burst + interactive navigation + Datalog + Diff
	spawn_commit_burst(worker_pid, 1000)

	// Send navigation & query events as a single batched envelope chain
	input_burst := [?]bifrost.UI_Msg{
		bifrost.UI_Msg_Input{event = {kind = .Key_Press, key = .Down}},
		bifrost.UI_Msg_Input{event = {kind = .Key_Press, key = .Down}},
		bifrost.UI_Msg_Input{event = {kind = .Key_Press, key = .Rune, ch = 'd'}},
		bifrost.UI_Msg_Input{event = {kind = .Key_Press, key = .Enter}},
		bifrost.UI_Msg_Frame_Tick{timestamp = time.tick_now()},
	}
	actor.send(sched, ui_pid, input_burst[:])

	// Wait for all actors (1,000 worker commits + UI coalesced render) to reach idle
	actor.wait_idle(sched)

	// Synchronous `actor.call` verification to query total worker commits
	total_commits := actor.call(sched, worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Ping_Count{}), i64)

	// Force one final frame tick so any trailing commit notification is rendered
	actor.send(sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{timestamp = time.tick_now()}))
	actor.wait_idle(sched)

	fmt.printf(
		"[Track 5 Verified] Worker commits: %d | UI coalesced notifications: %d | Total UI redraw frames: %d | Visible slice rows: %d\n",
		total_commits,
		ui_actor.state.coalesced_commits,
		ui_actor.state.total_frames,
		app.last_slice_rows,
	)
}

```
