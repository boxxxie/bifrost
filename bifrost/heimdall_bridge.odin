package bifrost

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import oa "../deps/heimdall/deps/OdinArrow/src"
import "../deps/heimdall/heimdall"

// =============================================================================
// 1. Canonical Bifrost Telemetry Scope & Metric Constants
// =============================================================================

TELEMETRY_SCOPE_COORDINATOR :: "bifrost.coordinator"
TELEMETRY_SCOPE_LAYOUT      :: "bifrost.layout"
TELEMETRY_SCOPE_RENDERER    :: "bifrost.renderer"
TELEMETRY_SCOPE_INPUT       :: "bifrost.input"
TELEMETRY_SCOPE_XITDB       :: "bifrost.xitdb"

// Thread-local fallback recorder override for parallel test isolation (`odin test` runs
// tests concurrently on worker threads; binding a thread-local default recorder avoids
// mutating `heimdall`'s process-global `g_default_recorder` or causing cross-test races).
@(private)
@(thread_local)
tls_test_default_recorder: ^heimdall.Recorder

// Sets or clears a thread-local default `^heimdall.Recorder` on the calling OS thread.
// Used by unit and ATDD tests so fallback telemetry resolution (`resolve_recorder(nil)`)
// is isolated per test thread under concurrent `odin test` execution.
set_thread_default_recorder :: proc "contextless" (rec: ^heimdall.Recorder) {
	tls_test_default_recorder = rec
}

// Disabled sentinel recorder pointer: when passed as `explicit` to `resolve_recorder`,
// suppresses telemetry (including any default recorder fallback) for that call.
@(private)
g_disabled_recorder_sentinel: heimdall.Recorder

disabled_recorder :: #force_inline proc "contextless" () -> ^heimdall.Recorder {
	return &g_disabled_recorder_sentinel
}

// Resolves the effective `^heimdall.Recorder` from an explicit struct pointer
// (`coord.recorder`, `ctx.recorder`, `scr.recorder`, `inp.recorder`, `worker.recorder`),
// falling back to `tls_test_default_recorder` and then `heimdall.default_recorder()` when `explicit == nil`.
resolve_recorder :: #force_inline proc(explicit: ^heimdall.Recorder = nil) -> ^heimdall.Recorder {
	if explicit == &g_disabled_recorder_sentinel {
		return nil
	}
	if explicit != nil {
		return explicit
	}
	if tls_test_default_recorder != nil {
		return tls_test_default_recorder
	}
	return heimdall.default_recorder()
}

// =============================================================================
// 2. Live Recorder Diagnostics Snapshot
// =============================================================================

Heimdall_Recorder_Stats :: struct {
	enabled:           bool,
	saturated:         bool,
	backend:           heimdall.Backend_Mode,
	policy:            heimdall.Backpressure_Policy,
	ring_pages:        int,
	batches_per_file:  int,
	waiting_producers: int,
	flushed_segments:  u64,
	dropped_records:   u64,
	failed_segments:   u64,
}

heimdall_snapshot_recorder_stats :: proc(rec: ^heimdall.Recorder = nil) -> Heimdall_Recorder_Stats {
	r := resolve_recorder(rec)
	if r == nil {
		return {}
	}
	flushed, dropped := heimdall.recorder_diagnostics(r)
	active_backend := r.cfg.backend
	if active_backend == .Auto {
		if r._flusher_actor != nil {
			active_backend = .Sleipnir_Actor
		} else if r._worker != nil {
			active_backend = .Dedicated_Thread
		}
	}
	return Heimdall_Recorder_Stats{
		enabled           = heimdall.recorder_is_enabled(r),
		saturated         = heimdall.recorder_is_saturated(r),
		backend           = active_backend,
		policy            = r.cfg.policy,
		ring_pages        = r.cfg.ring_page_count,
		batches_per_file  = r.cfg.batches_per_file,
		waiting_producers = heimdall.recorder_waiting_producers(r),
		flushed_segments  = flushed,
		dropped_records   = dropped,
		failed_segments   = heimdall.recorder_failed_segments(r),
	}
}

heimdall_kind_label :: proc "contextless" (k: heimdall.Kind) -> string {
	switch k {
	case .Span:      return "SPAN"
	case .Counter:   return "COUNTER"
	case .Gauge:     return "GAUGE"
	case .Histogram: return "HISTOGRAM"
	case .Event:     return "EVENT"
	}
	return "UNKNOWN"
}

heimdall_status_label :: proc "contextless" (s: heimdall.Status) -> string {
	switch s {
	case .Ok:    return "OK"
	case .Error: return "ERR"
	}
	return "UNKNOWN"
}

heimdall_backend_label :: proc "contextless" (b: heimdall.Backend_Mode) -> string {
	switch b {
	case .Auto:             return "Auto"
	case .Dedicated_Thread: return "Thread"
	case .Sleipnir_Actor:   return "Actor"
	}
	return "UNKNOWN"
}

heimdall_filter_kind_label :: proc "contextless" (fk: Heimdall_Filter_Kind) -> string {
	switch fk {
	case .All:          return "ALL"
	case .Spans_Only:   return "SPANS"
	case .Metrics_Only: return "METRICS"
	case .Events_Only:  return "EVENTS"
	case .Errors_Only:  return "ERRORS"
	}
	return "ALL"
}

heimdall_format_record_value :: proc(rec: heimdall.Record, allocator := context.temp_allocator) -> string {
	switch rec.kind {
	case .Span:
		return fmt.aprintf(
			"dur=%5dus | span=%04d<-%04d | attr=%d",
			rec.duration_ns / 1_000,
			rec.span_id,
			rec.parent_id,
			rec.attr_i64,
			allocator = allocator,
		)
	case .Counter, .Gauge, .Histogram:
		return fmt.aprintf("val=%7.1f | attr=%d", rec.value_f64, rec.attr_i64, allocator = allocator)
	case .Event:
		return fmt.aprintf("attr=%d | status=%s", rec.attr_i64, heimdall_status_label(rec.status), allocator = allocator)
	}
	return ""
}

// =============================================================================
// 3. Zero-Copy Columnar OdinArrow Segment Store & Filter/Analytics Engine
// =============================================================================

MAX_HEIMDALL_SEGMENTS :: 4096

Heimdall_Arrow_Segment :: struct {
	loaded:   bool,
	filename: string,
	schema:   ^oa.Schema,
	batches:  []oa.Record_Batch,
	readers:  []heimdall.Record_Batch_Reader,
	row_cnt:  int,
}

Heimdall_Filter_Kind :: enum u8 {
	All = 0,
	Spans_Only,
	Metrics_Only,
	Events_Only,
	Errors_Only,
}

Heimdall_Op_Stat :: struct {
	name:  string,
	count: int,
}

Heimdall_Scope_Stat :: struct {
	scope:         string,
	total_records: int,
	span_count:    int,
	metric_count:  int,
	event_count:   int,
	error_count:   int,
	total_dur_ns:  i64,
	max_dur_ns:    i64,
	ops:           [dynamic]Heimdall_Op_Stat,
}

Heimdall_Span_Tree_Item :: struct {
	record:     heimdall.Record,
	row_index:  int,
	depth:      int,
	child_cnt:  int,
}

// Zero-Copy Lifetime Invariant:
// `Heimdall_Segment_Store.records` and `Heimdall_Scope_Stat.scope` store zero-copy string slices
// pointing directly into the Arrow IPC `oa.Record_Batch` buffers owned by `store.segments`.
// Any `heimdall.Record` or `scope` / `name` string slice read from `store` is valid ONLY until
// the next `heimdall_store_clear_segments`, `heimdall_store_load_prefix` (if cleared), or `heimdall_store_destroy` call.
// Callers persisting a selected scope name or record across reloads MUST copy it into their own buffer.
Heimdall_Segment_Store :: struct {
	allocator:       mem.Allocator,
	segments:        [dynamic]Heimdall_Arrow_Segment,
	segment_count:   int,
	next_seg_idx:    int, // Incremental segment scan cursor so `heimdall_store_load_prefix` only reads newly flushed `.arrow` files
	records:         [dynamic]heimdall.Record,
	filtered_idxs:   [dynamic]int,
	scope_stats:     [dynamic]Heimdall_Scope_Stat,
	span_tree_items: [dynamic]Heimdall_Span_Tree_Item,
	cached_tree:     [dynamic]Tree_Node, // Cached `ui_tree` slice rebuilt only when new segments load

	// Aggregate summary counters
	total_spans:     int,
	total_counters:  int,
	total_gauges:    int,
	total_hists:     int,
	total_events:    int,
	total_errors:    int,
	max_duration_ns: i64,

	// Active filter state preserved across incremental `heimdall_store_load_file` calls
	active_filter_kind:  Heimdall_Filter_Kind,
	active_scope_buf:    [64]u8,
	active_scope_len:    int,
	active_query_buf:    [64]u8,
	active_query_len:    int,
}

heimdall_store_init :: proc(
	store: ^Heimdall_Segment_Store,
	allocator := context.allocator,
) -> (err: mem.Allocator_Error) {
	if store == nil {
		return nil
	}
	store^ = {}
	store.allocator = allocator
	defer if err != nil {
		heimdall_store_destroy(store)
	}
	store.segments        = make([dynamic]Heimdall_Arrow_Segment, 0, 64, allocator) or_return
	store.records         = make([dynamic]heimdall.Record, 0, 256, allocator) or_return
	store.filtered_idxs   = make([dynamic]int, 0, 256, allocator) or_return
	store.scope_stats     = make([dynamic]Heimdall_Scope_Stat, 0, 16, allocator) or_return
	store.span_tree_items = make([dynamic]Heimdall_Span_Tree_Item, 0, 128, allocator) or_return
	store.cached_tree     = make([dynamic]Tree_Node, 0, 32, allocator) or_return
	return nil
}

@(private)
heimdall_clear_cached_tree :: proc(store: ^Heimdall_Segment_Store) {
	if store == nil {
		return
	}
	for n in store.cached_tree {
		delete(n.id, store.allocator)
		delete(n.label, store.allocator)
	}
	clear(&store.cached_tree)
}

heimdall_store_clear_segments :: proc(store: ^Heimdall_Segment_Store) {
	if store == nil {
		return
	}
	prev_alloc := context.allocator
	context.allocator = store.allocator
	defer context.allocator = prev_alloc

	heimdall_clear_cached_tree(store)
	for &st in store.scope_stats {
		delete(st.ops)
	}

	for &seg in store.segments {
		if seg.loaded {
			for &b in seg.batches {
				oa.record_batch_free(&b)
			}
			delete(seg.batches, store.allocator)
			delete(seg.readers, store.allocator)
			if seg.schema != nil {
				oa.schema_free(seg.schema)
				free(seg.schema, store.allocator)
			}
			delete(seg.filename, store.allocator)
			seg = {}
		}
	}
	clear(&store.segments)
	store.segment_count   = 0
	store.next_seg_idx    = 0
	store.total_spans     = 0
	store.total_counters  = 0
	store.total_gauges    = 0
	store.total_hists     = 0
	store.total_events    = 0
	store.total_errors    = 0
	store.max_duration_ns = 0
	clear(&store.records)
	clear(&store.filtered_idxs)
	clear(&store.scope_stats)
	clear(&store.span_tree_items)
}

heimdall_store_destroy :: proc(store: ^Heimdall_Segment_Store) {
	if store == nil {
		return
	}
	heimdall_store_clear_segments(store)
	delete(store.cached_tree)
	delete(store.span_tree_items)
	delete(store.scope_stats)
	delete(store.filtered_idxs)
	delete(store.records)
	delete(store.segments)
	store^ = {}
}

// Loads a single `.arrow` IPC file into `store` and resolves `heimdall.Record_Batch_Reader`
// views over each batch without copying string payload bytes.
heimdall_store_load_file :: proc(
	store: ^Heimdall_Segment_Store,
	filename: string,
	rebuild_tree: bool = true,
) -> (rows_loaded: int, ok: bool) {
	if store == nil || len(filename) == 0 {
		return 0, false
	}
	if !os.exists(filename) {
		return 0, false
	}
	prev_alloc := context.allocator
	context.allocator = store.allocator
	defer context.allocator = prev_alloc

	sc, batches, read_ok := oa.ipc_read_file(filename)
	if !read_ok {
		return 0, false
	}

	readers, r_err := make([]heimdall.Record_Batch_Reader, len(batches), store.allocator)
	if r_err != nil {
		for &b in batches {
			oa.record_batch_free(&b)
		}
		delete(batches, store.allocator)
		oa.schema_free(sc)
		free(sc, store.allocator)
		return 0, false
	}

	seg_rows := 0
	any_resolved := false
	active_scope := string(store.active_scope_buf[:store.active_scope_len])
	active_query := string(store.active_query_buf[:store.active_query_len])
	for &b, b_idx in batches {
		reader, cols_ok := heimdall.record_batch_reader_resolve(&b)
		if !cols_ok {
			continue
		}
		any_resolved = true
		readers[b_idx] = reader
		for r_idx := 0; r_idx < b.length; r_idx += 1 {
			rec := heimdall.record_batch_reader_decode_row(&reader, r_idx)
			row_pos := len(store.records)
			if _, a_err := append(&store.records, rec); a_err != nil {
				break
			}
			if heimdall_record_matches_filter(rec, store.active_filter_kind, active_scope, active_query) {
				_, _ = append(&store.filtered_idxs, row_pos)
			}
			heimdall_accumulate_record_stats(store, rec)
			seg_rows += 1
		}
	}

	if !any_resolved || seg_rows == 0 {
		for &b in batches {
			oa.record_batch_free(&b)
		}
		delete(batches, store.allocator)
		delete(readers, store.allocator)
		oa.schema_free(sc)
		free(sc, store.allocator)
		return 0, false
	}

	cloned_name, c_err := strings.clone(filename, store.allocator)
	if c_err != nil {
		cloned_name = ""
	}
	if _, seg_err := append(&store.segments, Heimdall_Arrow_Segment{
		loaded   = true,
		filename = cloned_name,
		schema   = sc,
		batches  = batches,
		readers  = readers,
		row_cnt  = seg_rows,
	}); seg_err != nil {
		delete(cloned_name, store.allocator)
		for &b in batches {
			oa.record_batch_free(&b)
		}
		delete(batches, store.allocator)
		delete(readers, store.allocator)
		oa.schema_free(sc)
		free(sc, store.allocator)
		return 0, false
	}
	store.segment_count = len(store.segments)
	heimdall_clear_cached_tree(store)
	if rebuild_tree {
		heimdall_rebuild_span_tree(store)
	}
	return seg_rows, true
}

// Reloads `<file_prefix>_000000.arrow`, `<file_prefix>_000001.arrow`, ... segment files.
// Supports both zero-indexed contiguous segments and rolling retention policies where older
// low-numbered segment files may have been deleted while newer higher-numbered segments exist.
heimdall_store_load_prefix :: proc(
	store: ^Heimdall_Segment_Store,
	file_prefix: string,
	max_segments: int = 0,
) -> (segments_loaded: int, total_rows: int) {
	if store == nil || len(file_prefix) == 0 {
		return 0, 0
	}
	heimdall_store_clear_segments(store)
	limit := max_segments > 0 ? max_segments : 1_000_000
	name_buf: [512]u8
	for seg_idx := 0; seg_idx < limit; seg_idx += 1 {
		fname := fmt.bprintf(name_buf[:], "%s_%06d.arrow", file_prefix, seg_idx)
		if !os.exists(fname) {
			if segments_loaded > 0 {
				break
			}
			if max_segments <= 0 && seg_idx >= MAX_HEIMDALL_SEGMENTS {
				break
			}
			continue
		}
		rows, ok := heimdall_store_load_file(store, fname, rebuild_tree = false)
		if ok {
			segments_loaded += 1
			total_rows += rows
			store.next_seg_idx = seg_idx + 1
		}
	}
	if segments_loaded > 0 {
		heimdall_rebuild_span_tree(store)
	}
	return segments_loaded, total_rows
}

// Incrementally loads only newly flushed `<file_prefix>_NNNNNN.arrow` segment files starting
// at `store.next_seg_idx`, avoiding tearing down and re-parsing already loaded segments when
// flushing repeatedly at high frequency. Falls back to `heimdall_store_load_prefix` if the first
// loaded segment was rotated/deleted on disk.
heimdall_store_load_prefix_incremental :: proc(
	store: ^Heimdall_Segment_Store,
	file_prefix: string,
	max_segments: int = 0,
) -> (new_segments: int, total_rows: int) {
	if store == nil || len(file_prefix) == 0 {
		return 0, 0
	}
	if len(store.segments) == 0 {
		return heimdall_store_load_prefix(store, file_prefix, max_segments)
	}
	if !os.exists(store.segments[0].filename) {
		return heimdall_store_load_prefix(store, file_prefix, max_segments)
	}

	limit := max_segments > 0 ? max_segments : 1_000_000
	name_buf: [512]u8
	for len(store.segments) < limit {
		fname := fmt.bprintf(name_buf[:], "%s_%06d.arrow", file_prefix, store.next_seg_idx)
		if !os.exists(fname) {
			break
		}
		rows, ok := heimdall_store_load_file(store, fname, rebuild_tree = false)
		store.next_seg_idx += 1
		if ok {
			new_segments += 1
		} else {
			_ = rows
		}
	}
	if new_segments > 0 {
		heimdall_rebuild_span_tree(store)
	}
	return new_segments, len(store.records)
}

@(private)
heimdall_accumulate_record_stats :: proc(store: ^Heimdall_Segment_Store, rec: heimdall.Record) {
	clamped_dur := max(i64(0), rec.duration_ns)
	switch rec.kind {
	case .Span:
		store.total_spans += 1
		if clamped_dur > store.max_duration_ns {
			store.max_duration_ns = clamped_dur
		}
	case .Counter:
		store.total_counters += 1
	case .Gauge:
		store.total_gauges += 1
	case .Histogram:
		store.total_hists += 1
	case .Event:
		store.total_events += 1
	}
	if rec.status == .Error {
		store.total_errors += 1
	}

	found_idx := -1
	for s, idx in store.scope_stats {
		if s.scope == rec.scope {
			found_idx = idx
			break
		}
	}
	if found_idx < 0 {
		found_idx = len(store.scope_stats)
		ops_dyn := make([dynamic]Heimdall_Op_Stat, 0, 8, store.allocator)
		append(&store.scope_stats, Heimdall_Scope_Stat{
			scope = rec.scope,
			ops   = ops_dyn,
		})
	}
	stat := &store.scope_stats[found_idx]
	stat.total_records += 1
	if rec.status == .Error {
		stat.error_count += 1
	}
	switch rec.kind {
	case .Span:
		stat.span_count += 1
		stat.total_dur_ns += clamped_dur
		if clamped_dur > stat.max_dur_ns {
			stat.max_dur_ns = clamped_dur
		}
	case .Counter, .Gauge, .Histogram:
		stat.metric_count += 1
	case .Event:
		stat.event_count += 1
	}

	op_idx := -1
	for op, idx in stat.ops {
		if op.name == rec.name {
			op_idx = idx
			break
		}
	}
	if op_idx < 0 {
		append(&stat.ops, Heimdall_Op_Stat{name = rec.name, count = 1})
	} else {
		stat.ops[op_idx].count += 1
	}
}

@(private)
heimdall_rebuild_span_tree :: proc(store: ^Heimdall_Segment_Store) {
	clear(&store.span_tree_items)
	if len(store.records) == 0 {
		return
	}

	// Collect all `.Span` record indices and sort them by start timestamp (`timestamp_ns - max(0, duration_ns)`) ascending
	span_idxs := make([dynamic]int, 0, store.total_spans, context.temp_allocator)
	for rec, idx in store.records {
		if rec.kind == .Span && rec.span_id != 0 {
			append(&span_idxs, idx)
		}
	}
	if len(span_idxs) == 0 {
		return
	}

	// Sort span indices by (`timestamp_ns - max(0, duration_ns)`, `span_id`, `row_idx`)
	Span_Sort_Entry :: struct {
		start_ns: i64,
		span_id:  u64,
		row_idx:  int,
	}
	entries := make([]Span_Sort_Entry, len(span_idxs), context.temp_allocator)
	for r_idx, i in span_idxs {
		rec := store.records[r_idx]
		clamped_dur := max(i64(0), rec.duration_ns)
		entries[i] = Span_Sort_Entry{
			start_ns = rec.timestamp_ns - clamped_dur,
			span_id  = rec.span_id,
			row_idx  = r_idx,
		}
	}
	slice.sort_by(entries, proc(a, b: Span_Sort_Entry) -> bool {
		if a.start_ns != b.start_ns {
			return a.start_ns < b.start_ns
		}
		if a.span_id != b.span_id {
			return a.span_id < b.span_id
		}
		return a.row_idx < b.row_idx
	})
	for e, i in entries {
		span_idxs[i] = e.row_idx
	}

	// Build O(S) lookup structures keyed by unique `row_idx` on `context.temp_allocator` so duplicate
	// `span_id` values across segments (e.g. after recorder re-init) attach each child to the most
	// recent preceding parent instance rather than duplicating subtrees across all colliding spans.
	latest_span_row := make(map[u64]int, len(span_idxs), context.temp_allocator)
	all_span_rows   := make(map[u64][dynamic]int, len(span_idxs), context.temp_allocator)
	parent_row_map  := make(map[int]int, len(span_idxs), context.temp_allocator)
	children_map    := make(map[int][dynamic]int, len(span_idxs), context.temp_allocator)

	for r_idx in span_idxs {
		rec := store.records[r_idx]
		if rec.parent_id != 0 && rec.parent_id != rec.span_id {
			if p_row, has_p := latest_span_row[rec.parent_id]; has_p && p_row != r_idx {
				parent_row_map[r_idx] = p_row
				list := children_map[p_row]
				if list.allocator.procedure == nil {
					list = make([dynamic]int, 0, 4, context.temp_allocator)
				}
				append(&list, r_idx)
				children_map[p_row] = list
			}
		}
		latest_span_row[rec.span_id] = r_idx
		rows_for_id := all_span_rows[rec.span_id]
		if rows_for_id.allocator.procedure == nil {
			rows_for_id = make([dynamic]int, 0, 2, context.temp_allocator)
		}
		append(&rows_for_id, r_idx)
		all_span_rows[rec.span_id] = rows_for_id
	}
	// Second pass for out-of-order parent spans whose start timestamp sorted after a child's start timestamp:
	// pick the closest candidate parent row by `abs(cand_row - r_idx)` so colliding `span_id`s in later
	// segments never steal out-of-order children from earlier segments.
	for r_idx in span_idxs {
		if r_idx in parent_row_map {
			continue
		}
		rec := store.records[r_idx]
		if rec.parent_id != 0 && rec.parent_id != rec.span_id {
			if cand_rows, has_p := all_span_rows[rec.parent_id]; has_p {
				best_p_row := -1
				best_dist  := max(int)
				for cand_row in cand_rows {
					if cand_row == r_idx {
						continue
					}
					dist := abs(cand_row - r_idx)
					if dist < best_dist {
						best_dist  = dist
						best_p_row = cand_row
					}
				}
				if best_p_row >= 0 {
					parent_row_map[r_idx] = best_p_row
					list := children_map[best_p_row]
					if list.allocator.procedure == nil {
						list = make([dynamic]int, 0, 4, context.temp_allocator)
					}
					append(&list, r_idx)
					children_map[best_p_row] = list
				}
			}
		}
	}

	// Pre-order walk from root spans (`!(r_idx in parent_row_map)`) in O(S) time,
	// followed by a second pass to recover any remaining cyclic subtrees (`A <-> B`) so no span is silently dropped.
	visited := make(map[int]bool, len(span_idxs), context.temp_allocator)
	for r_idx in span_idxs {
		if !(r_idx in parent_row_map) {
			_ = heimdall_append_span_subtree_fast(store, &children_map, &visited, r_idx, 0)
		}
	}
	for r_idx in span_idxs {
		if !(r_idx in visited) {
			_ = heimdall_append_span_subtree_fast(store, &children_map, &visited, r_idx, 0)
		}
	}
}

@(private)
heimdall_append_span_subtree_fast :: proc(
	store: ^Heimdall_Segment_Store,
	children_map: ^map[int][dynamic]int,
	visited: ^map[int]bool,
	row_idx: int,
	depth: int,
) -> bool {
	if depth > 16 || (row_idx in visited^) {
		return false
	}
	visited^[row_idx] = true
	rec := store.records[row_idx]
	item_pos := len(store.span_tree_items)
	append(&store.span_tree_items, Heimdall_Span_Tree_Item{
		record    = rec,
		row_index = row_idx,
		depth     = depth,
	})
	children := 0
	if depth < 16 {
		if child_list, ok := children_map^[row_idx]; ok {
			for cand_idx in child_list {
				if cand_idx == row_idx || (cand_idx in visited^) {
					continue
				}
				if heimdall_append_span_subtree_fast(store, children_map, visited, cand_idx, depth + 1) {
					children += 1
				}
			}
		}
	}
	store.span_tree_items[item_pos].child_cnt = children
	return true
}

@(private)
heimdall_contains_ascii_fold :: proc "contextless" (haystack, needle: string) -> bool {
	n_len := len(needle)
	h_len := len(haystack)
	if n_len == 0 {
		return true
	}
	if n_len > h_len {
		return false
	}
	limit := h_len - n_len
	for i := 0; i <= limit; i += 1 {
		matched := true
		for j := 0; j < n_len; j += 1 {
			hc := haystack[i + j]
			nc := needle[j]
			if hc >= 'A' && hc <= 'Z' {
				hc += 32
			}
			if nc >= 'A' && nc <= 'Z' {
				nc += 32
			}
			if hc != nc {
				matched = false
				break
			}
		}
		if matched {
			return true
		}
	}
	return false
}

@(private)
heimdall_record_matches_filter :: proc(
	rec: heimdall.Record,
	kind_filter: Heimdall_Filter_Kind,
	scope_filter: string,
	query: string,
) -> bool {
	switch kind_filter {
	case .All:
	case .Spans_Only:
		if rec.kind != .Span {
			return false
		}
	case .Metrics_Only:
		if rec.kind != .Counter && rec.kind != .Gauge && rec.kind != .Histogram {
			return false
		}
	case .Events_Only:
		if rec.kind != .Event {
			return false
		}
	case .Errors_Only:
		if rec.status != .Error {
			return false
		}
	}

	if len(scope_filter) > 0 && rec.scope != scope_filter {
		return false
	}

	if len(query) > 0 {
		if !heimdall_contains_ascii_fold(rec.scope, query) &&
		   !heimdall_contains_ascii_fold(rec.name, query) &&
		   !heimdall_contains_ascii_fold(heimdall_kind_label(rec.kind), query) &&
		   !heimdall_contains_ascii_fold(heimdall_status_label(rec.status), query) {
			return false
		}
	}

	return true
}

// Filters `store.records` by `kind_filter`, optional `scope_filter`, and case-insensitive substring `query`.
heimdall_store_apply_filter :: proc(
	store: ^Heimdall_Segment_Store,
	kind_filter: Heimdall_Filter_Kind = .All,
	scope_filter: string = "",
	query: string = "",
) -> int {
	if store == nil {
		return 0
	}
	store.active_filter_kind = kind_filter
	s_len := min(len(scope_filter), len(store.active_scope_buf))
	if s_len > 0 {
		copy(store.active_scope_buf[:s_len], scope_filter[:s_len])
	}
	store.active_scope_len = s_len

	q_len := min(len(query), len(store.active_query_buf))
	if q_len > 0 {
		copy(store.active_query_buf[:q_len], query[:q_len])
	}
	store.active_query_len = q_len

	clear(&store.filtered_idxs)
	for rec, idx in store.records {
		if heimdall_record_matches_filter(rec, kind_filter, scope_filter, query) {
			append(&store.filtered_idxs, idx)
		}
	}
	return len(store.filtered_idxs)
}

// Returns the filtered `heimdall.Record` at `filtered_row` in `0 ..< len(store.filtered_idxs)`.
heimdall_store_get_filtered_record :: proc "contextless" (
	store: ^Heimdall_Segment_Store,
	filtered_row: int,
) -> (rec: heimdall.Record, ok: bool) {
	if store == nil || filtered_row < 0 || filtered_row >= len(store.filtered_idxs) {
		return {}, false
	}
	raw_idx := store.filtered_idxs[filtered_row]
	if raw_idx < 0 || raw_idx >= len(store.records) {
		return {}, false
	}
	return store.records[raw_idx], true
}

// Extracts recent span durations (in microseconds, clamped >= 1) for `ui_sparkline` / `ui_canvas`.
// Honors the store's active scope and substring query filters (or an explicit `scope_filter` override).
heimdall_store_extract_span_durations_us :: proc(
	store: ^Heimdall_Segment_Store,
	max_samples: int = 32,
	scope_filter: string = "",
	allocator := context.temp_allocator,
) -> []int {
	if store == nil || max_samples <= 0 {
		return nil
	}
	eff_scope := scope_filter if len(scope_filter) > 0 else string(store.active_scope_buf[:store.active_scope_len])
	eff_query := string(store.active_query_buf[:store.active_query_len])
	only_err  := store.active_filter_kind == .Errors_Only

	samples := make([dynamic]int, 0, max_samples, allocator)
	for i := len(store.records) - 1; i >= 0 && len(samples) < max_samples; i -= 1 {
		rec := store.records[i]
		if rec.kind != .Span {
			continue
		}
		if only_err && rec.status != .Error {
			continue
		}
		if len(eff_scope) > 0 && rec.scope != eff_scope {
			continue
		}
		if len(eff_query) > 0 && !heimdall_record_matches_filter(rec, .All, "", eff_query) {
			continue
		}
		clamped_dur := max(i64(0), rec.duration_ns)
		us := max(1, int((clamped_dur + 500) / 1000))
		append(&samples, us)
	}
	slice.reverse(samples[:])
	return samples[:]
}

// Extracts recent metric values (`value_f64` cast to `f32`) for `canvas_draw_series`.
// By default (`metric_name == ""`), extracts all `.Counter`, `.Gauge`, and `.Histogram` metric records,
// honoring the store's active scope and query filters when `metric_name == ""`.
heimdall_store_extract_metric_series :: proc(
	store: ^Heimdall_Segment_Store,
	metric_name: string = "",
	max_samples: int = 32,
	allocator := context.temp_allocator,
) -> (values: []f32, min_val, max_val: f32) {
	if store == nil || max_samples <= 0 {
		return nil, 0, 1
	}
	eff_scope := string(store.active_scope_buf[:store.active_scope_len])
	eff_query := string(store.active_query_buf[:store.active_query_len])
	only_err  := store.active_filter_kind == .Errors_Only

	samples := make([dynamic]f32, 0, max_samples, allocator)
	min_v: f32 = 0
	max_v: f32 = 0
	first := true
	for i := len(store.records) - 1; i >= 0 && len(samples) < max_samples; i -= 1 {
		rec := store.records[i]
		is_metric := rec.kind == .Counter || rec.kind == .Gauge || rec.kind == .Histogram
		if len(metric_name) > 0 {
			if rec.name != metric_name || (!is_metric && rec.kind != .Span) {
				continue
			}
		} else {
			if !is_metric {
				continue
			}
			if len(eff_scope) > 0 && rec.scope != eff_scope {
				continue
			}
			if len(eff_query) > 0 && !heimdall_record_matches_filter(rec, .All, "", eff_query) {
				continue
			}
		}
		if only_err && rec.status != .Error {
			continue
		}
		clamped_dur := max(i64(0), rec.duration_ns)
		v := f32(clamped_dur) / 1_000.0 if rec.kind == .Span else f32(rec.value_f64)
		if first {
			min_v = v
			max_v = v
			first = false
		} else {
			min_v = min(min_v, v)
			max_v = max(max_v, v)
		}
		append(&samples, v)
	}
	slice.reverse(samples[:])
	if max_v <= min_v {
		max_v = max(min_v + 1.0, min_v + math.abs(min_v) * 1e-5)
	}
	return samples[:], min_v, max_v
}

// Frees a `[]Tree_Node` slice and its formatted `id`/`label` strings allocated by
// `heimdall_store_build_scope_tree` when called with a general heap allocator.
heimdall_free_scope_tree :: proc(nodes: []Tree_Node, allocator := context.allocator) {
	for n in nodes {
		delete(n.id, allocator)
		delete(n.label, allocator)
	}
	delete(nodes, allocator)
}

// Builds a flattened `[]Tree_Node` hierarchy (Scopes at depth 0 -> Operations at depth 1) onto `allocator`
// suitable for passing directly to `ui_tree`. Uses the pre-aggregated `stat.ops` per scope in O(Scopes + Ops)
// time (independent of `len(store.records)`).
// When called with a general heap allocator (rather than `context.temp_allocator`), free with `heimdall_free_scope_tree`.
heimdall_store_build_scope_tree :: proc(
	store: ^Heimdall_Segment_Store,
	allocator := context.temp_allocator,
) -> []Tree_Node {
	if store == nil || len(store.scope_stats) == 0 {
		return nil
	}

	nodes := make([dynamic]Tree_Node, 0, len(store.scope_stats) * 4, allocator)
	for stat in store.scope_stats {
		children := make([dynamic]Tree_Node, 0, max(4, len(stat.ops)), allocator)
		defer delete(children)
		for op in stat.ops {
			child_id := fmt.aprintf("hm_op_%s_%s", stat.scope, op.name, allocator = allocator)
			child_lbl := fmt.aprintf("%s (%d)", op.name, op.count, allocator = allocator)
			append(&children, Tree_Node{
				id         = child_id,
				label      = child_lbl,
				depth      = 1,
				parent_idx = -1,
			})
		}
		// Sort child operations alphabetically for deterministic tree rendering
		slice.sort_by(children[:], proc(a, b: Tree_Node) -> bool {
			return a.label < b.label
		})
		scope_idx := i32(len(nodes))
		scope_id := fmt.aprintf("hm_scope_%s", stat.scope, allocator = allocator)
		scope_lbl := fmt.aprintf(
			"%s [%d rows, %d spans]",
			stat.scope,
			stat.total_records,
			stat.span_count,
			allocator = allocator,
		)
		append(&nodes, Tree_Node{
			id           = scope_id,
			label        = scope_lbl,
			depth        = 0,
			parent_idx   = -1,
			expanded     = true,
			has_children = len(children) > 0,
		})
		for c in children {
			child_node := c
			child_node.parent_idx = scope_idx
			append(&nodes, child_node)
		}
	}
	return nodes[:]
}

// Returns a cached `[]Tree_Node` slice owned by `store.cached_tree`, rebuilding it only when
// new segments have been loaded since the last call. Zero per-frame allocations during rendering.
heimdall_store_get_cached_scope_tree :: proc(store: ^Heimdall_Segment_Store) -> []Tree_Node {
	if store == nil || len(store.scope_stats) == 0 {
		return nil
	}
	if len(store.cached_tree) > 0 {
		return store.cached_tree[:]
	}
	built := heimdall_store_build_scope_tree(store, store.allocator)
	for n in built {
		append(&store.cached_tree, n)
	}
	delete(built, store.allocator)
	return store.cached_tree[:]
}

// =============================================================================
// 4. Runtime Performance & Process Resource Monitor (FPS, CPU %, RSS / Heap MB)
// =============================================================================

Heimdall_Runtime_Metrics :: struct {
	last_sample_tick: time.Tick,
	last_cpu_jiffies: u64,
	last_frame_count: u64,
	fps:              f32,
	frame_time_us:    int,
	cpu_percent:      f32,
	rss_kb:           i64,
	heap_bytes:       i64,
	peak_heap_bytes:  i64,
}

@(private)
heimdall_parse_leading_int :: proc "contextless" (s: string) -> (val: i64, ok: bool) {
	started := false
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c >= '0' && c <= '9' {
			val = val * 10 + i64(c - '0')
			started = true
		} else if started {
			break
		}
	}
	return val, started
}

// Samples `/proc/self/stat` (user + system CPU jiffies) and `/proc/self/status` (`VmRSS`) on Linux,
// along with smoothed FPS, latest `flush_frame` duration in microseconds, and optional `Tracking_Allocator` heap usage.
// Throttles `/proc` reads to at most once every `min_interval_ms` (default 250ms) so calling every frame is O(1).
heimdall_sample_runtime_metrics :: proc(
	m: ^Heimdall_Runtime_Metrics,
	total_frames: u64,
	latest_frame_dur_ns: i64 = 0,
	track: ^mem.Tracking_Allocator = nil,
	min_interval_ms: i64 = 200,
) {
	if m == nil {
		return
	}
	if latest_frame_dur_ns > 0 {
		m.frame_time_us = int((latest_frame_dur_ns + 500) / 1000)
	}
	if track != nil {
		m.heap_bytes      = track.current_memory_allocated
		m.peak_heap_bytes = track.peak_memory_allocated
	}

	now := time.tick_now()
	if m.last_sample_tick._nsec == 0 {
		m.last_sample_tick = now
		m.last_frame_count = total_frames
		m.fps              = 0.0
	} else {
		elapsed_ns := i64(time.tick_diff(m.last_sample_tick, now))
		if elapsed_ns < min_interval_ms * 1_000_000 {
			return
		}
		elapsed_s := f32(elapsed_ns) / 1e9
		if elapsed_s > 0.001 {
			df := total_frames - m.last_frame_count if total_frames >= m.last_frame_count else 0
			inst_fps := f32(df) / elapsed_s
			m.fps = m.fps * 0.5 + inst_fps * 0.5
			if m.fps < 0.05 {
				m.fps = 0.0
			}
		}
		m.last_sample_tick = now
		m.last_frame_count = total_frames

		// Sample `/proc/self/stat` for utime (field 14) + stime (field 15) in 100Hz clock ticks
		if stat_bytes, s_err := os.read_entire_file("/proc/self/stat", context.temp_allocator); s_err == nil {
			stat_str := string(stat_bytes)
			if rparen := strings.last_index_byte(stat_str, ')'); rparen >= 0 && rparen + 2 < len(stat_str) {
				rest := stat_str[rparen + 2:]
				field_idx := 3 // field 3 is state ('R'/'S') immediately after ") "
				utime_j: i64 = 0
				stime_j: i64 = 0
				tok_start := 0
				for i := 0; i <= len(rest); i += 1 {
					if i == len(rest) || rest[i] == ' ' {
						if i > tok_start {
							tok := rest[tok_start:i]
							if field_idx == 14 {
								utime_j, _ = heimdall_parse_leading_int(tok)
							} else if field_idx == 15 {
								stime_j, _ = heimdall_parse_leading_int(tok)
								break
							}
							field_idx += 1
						}
						tok_start = i + 1
					}
				}
				total_j := u64(max(i64(0), utime_j + stime_j))
				if m.last_cpu_jiffies > 0 && total_j >= m.last_cpu_jiffies && elapsed_s > 0.001 {
					dj := f32(total_j - m.last_cpu_jiffies)
					// Linux USER_HZ is 100 jiffies/sec -> (dj / 100.0) / elapsed_s * 100.0 == dj / elapsed_s
					inst_cpu := clamp(dj / elapsed_s, 0.0, 800.0)
					m.cpu_percent = m.cpu_percent * 0.4 + inst_cpu * 0.6
					if m.cpu_percent < 0.05 {
						m.cpu_percent = 0.0
					}
				}
				m.last_cpu_jiffies = total_j
			}
		}
	}

	// Sample `/proc/self/status` for `VmRSS:` (resident set size in KB)
	if status_bytes, st_err := os.read_entire_file("/proc/self/status", context.temp_allocator); st_err == nil {
		status_str := string(status_bytes)
		if idx := strings.index(status_str, "VmRSS:"); idx >= 0 {
			line_rest := status_str[idx + 6:]
			if nl := strings.index_byte(line_rest, '\n'); nl >= 0 {
				line_rest = line_rest[:nl]
			}
			if rss, ok := heimdall_parse_leading_int(line_rest); ok && rss > 0 {
				m.rss_kb = rss
			}
		}
	}
}

// =============================================================================
// Declarative `ui_table` Column Presets & Row Cell Builders for Heimdall Records
// =============================================================================

@(rodata)
HEIMDALL_TABLE_COLUMNS := [7]Table_Column_Spec{
	0 = {header = "Kind",      kind = .Fixed,        value = 7, min_width = 7, max_width = 9,  align = .Left},
	1 = {header = "St",        kind = .Fixed,        value = 2, min_width = 2, max_width = 3,  align = .Center},
	2 = {header = "Scope",     kind = .Auto_Content,            min_width = 11, max_width = 20, align = .Left},
	3 = {header = "Operation", kind = .Fill,         value = 2, min_width = 11,                 align = .Left},
	4 = {header = "Span",      kind = .Fixed,        value = 5, min_width = 5, max_width = 7,  align = .Right},
	5 = {header = "Dur/Val",   kind = .Fixed,        value = 7, min_width = 7, max_width = 9,  align = .Right},
	6 = {header = "Attr",      kind = .Fixed,        value = 4, min_width = 4, max_width = 6,  align = .Right},
}

@(rodata)
HEIMDALL_INSPECTOR_TABLE_COLUMNS := [9]Table_Column_Spec{
	0 = {header = "#",         kind = .Fixed,        value = 4, min_width = 4, max_width = 4,  align = .Right},
	1 = {header = "Kind",      kind = .Fixed,        value = 7, min_width = 7, max_width = 9,  align = .Left},
	2 = {header = "St",        kind = .Fixed,        value = 2, min_width = 2, max_width = 3,  align = .Center},
	3 = {header = "Scope",     kind = .Auto_Content,            min_width = 11, max_width = 17, align = .Left},
	4 = {header = "Operation", kind = .Fill,         value = 2, min_width = 11,                 align = .Left},
	5 = {header = "Span",      kind = .Fixed,        value = 5, min_width = 5, max_width = 7,  align = .Right},
	6 = {header = "Time",      kind = .Fixed,        value = 7, min_width = 7, max_width = 7,  align = .Right},
	7 = {header = "Dur/Val",   kind = .Fixed,        value = 7, min_width = 7, max_width = 9,  align = .Right},
	8 = {header = "Attr",      kind = .Fixed,        value = 4, min_width = 4, max_width = 6,  align = .Right},
}

heimdall_kind_color :: proc "contextless" (kind: heimdall.Kind) -> Color {
	switch kind {
	case .Span:      return rgb(125, 205, 255)
	case .Counter:   return rgb(140, 230, 170)
	case .Gauge:     return rgb(255, 205, 115)
	case .Histogram: return rgb(215, 165, 255)
	case .Event:     return rgb(255, 165, 145)
	}
	return rgb(200, 210, 225)
}

heimdall_status_color :: proc "contextless" (status: heimdall.Status) -> Color {
	return rgb(255, 120, 120) if status == .Error else rgb(135, 225, 165)
}

heimdall_table_columns :: proc(alloc := context.temp_allocator) -> []Table_Column_Spec {
	cols := make([]Table_Column_Spec, len(HEIMDALL_TABLE_COLUMNS), alloc)
	for i in 0 ..< len(HEIMDALL_TABLE_COLUMNS) {
		cols[i] = HEIMDALL_TABLE_COLUMNS[i]
	}
	return cols
}

heimdall_inspector_table_columns :: proc(alloc := context.temp_allocator) -> []Table_Column_Spec {
	cols := make([]Table_Column_Spec, len(HEIMDALL_INSPECTOR_TABLE_COLUMNS), alloc)
	for i in 0 ..< len(HEIMDALL_INSPECTOR_TABLE_COLUMNS) {
		cols[i] = HEIMDALL_INSPECTOR_TABLE_COLUMNS[i]
	}
	return cols
}

// Formats a `heimdall.Record` into 7 aligned `Table_Cell` columns (`HEIMDALL_TABLE_COLUMNS`)
// for `log_monitor` and `widget_showcase`.
heimdall_record_table_cells :: proc(rec: heimdall.Record, alloc := context.temp_allocator) -> [7]Table_Cell {
	span_str := "—"
	val_str  := "—"
	switch rec.kind {
	case .Span:
		dur_us := max(i64(0), rec.duration_ns) / 1000
		span_str = fmt.aprintf("%02d<%02d", rec.span_id % 100, rec.parent_id % 100, allocator = alloc)
		val_str  = fmt.aprintf("%dus", dur_us, allocator = alloc)
	case .Counter, .Gauge, .Histogram:
		if rec.value_f64 == f64(i64(rec.value_f64)) {
			val_str = fmt.aprintf("%d", i64(rec.value_f64), allocator = alloc)
		} else {
			val_str = fmt.aprintf("%.1f", rec.value_f64, allocator = alloc)
		}
	case .Event:
		val_str = "event"
	}
	attr_str := fmt.aprintf("%d", rec.attr_i64, allocator = alloc)

	return [7]Table_Cell{
		0 = {text = heimdall_kind_label(rec.kind), fg = heimdall_kind_color(rec.kind), style = {.Bold}},
		1 = {text = heimdall_status_label(rec.status), fg = heimdall_status_color(rec.status)},
		2 = {text = rec.scope},
		3 = {text = rec.name},
		4 = {text = span_str},
		5 = {text = val_str},
		6 = {text = attr_str},
	}
}

// Formats a `heimdall.Record` into 9 aligned `Table_Cell` columns (`HEIMDALL_INSPECTOR_TABLE_COLUMNS`)
// for `heimdall_inspector`.
heimdall_inspector_record_cells :: proc(
	row_idx: i32,
	rec: heimdall.Record,
	alloc := context.temp_allocator,
) -> [9]Table_Cell {
	base := heimdall_record_table_cells(rec, alloc)
	ts_ms := (max(i64(0), rec.timestamp_ns) / 1_000_000) % 100_000
	idx_str := fmt.aprintf("%04d", row_idx, allocator = alloc)
	ts_str  := fmt.aprintf("+%05dms", ts_ms, allocator = alloc)

	return [9]Table_Cell{
		0 = {text = idx_str},
		1 = base[0],
		2 = base[1],
		3 = base[2],
		4 = base[3],
		5 = base[4],
		6 = {text = ts_str},
		7 = base[5],
		8 = base[6],
	}
}

@(rodata)
HEIMDALL_WATERFALL_TABLE_COLUMNS := [8]Table_Column_Spec{
	0 = {header = "#",                        kind = .Fixed,        value = 4, min_width = 4, max_width = 4,  align = .Right},
	1 = {header = "St",                       kind = .Fixed,        value = 2, min_width = 2, max_width = 3,  align = .Center},
	2 = {header = "Scope",                    kind = .Auto_Content,            min_width = 11, max_width = 18, align = .Left},
	3 = {header = "Span Hierarchy (Call Tree)", kind = .Fill,       value = 2, min_width = 18,                 align = .Left},
	4 = {header = "Span",                     kind = .Fixed,        value = 5, min_width = 5, max_width = 7,  align = .Right},
	5 = {header = "Dur",                      kind = .Fixed,        value = 7, min_width = 7, max_width = 9,  align = .Right},
	6 = {header = "Heat",                     kind = .Fixed,        value = 8, min_width = 8, max_width = 8,  align = .Left},
	7 = {header = "Kids",                     kind = .Fixed,        value = 4, min_width = 4, max_width = 4,  align = .Right},
}

@(rodata)
HEIMDALL_SCOPE_STATS_TABLE_COLUMNS := [8]Table_Column_Spec{
	0 = {header = "Scope",     kind = .Fill,  value = 2, min_width = 16,                align = .Left},
	1 = {header = "Records",   kind = .Fixed, value = 7, min_width = 7, max_width = 8,  align = .Right},
	2 = {header = "Spans",     kind = .Fixed, value = 6, min_width = 6, max_width = 7,  align = .Right},
	3 = {header = "Metrics",   kind = .Fixed, value = 7, min_width = 7, max_width = 8,  align = .Right},
	4 = {header = "Events",    kind = .Fixed, value = 6, min_width = 6, max_width = 7,  align = .Right},
	5 = {header = "Errs",      kind = .Fixed, value = 4, min_width = 4, max_width = 5,  align = .Right},
	6 = {header = "Avg us",    kind = .Fixed, value = 8, min_width = 8, max_width = 9,  align = .Right},
	7 = {header = "Max us",    kind = .Fixed, value = 8, min_width = 8, max_width = 9,  align = .Right},
}

heimdall_waterfall_table_columns :: proc(alloc := context.temp_allocator) -> []Table_Column_Spec {
	cols := make([]Table_Column_Spec, len(HEIMDALL_WATERFALL_TABLE_COLUMNS), alloc)
	for i in 0 ..< len(HEIMDALL_WATERFALL_TABLE_COLUMNS) {
		cols[i] = HEIMDALL_WATERFALL_TABLE_COLUMNS[i]
	}
	return cols
}

heimdall_scope_stats_table_columns :: proc(alloc := context.temp_allocator) -> []Table_Column_Spec {
	cols := make([]Table_Column_Spec, len(HEIMDALL_SCOPE_STATS_TABLE_COLUMNS), alloc)
	for i in 0 ..< len(HEIMDALL_SCOPE_STATS_TABLE_COLUMNS) {
		cols[i] = HEIMDALL_SCOPE_STATS_TABLE_COLUMNS[i]
	}
	return cols
}

// Formats a `Heimdall_Span_Tree_Item` into 8 aligned `Table_Cell` columns (`HEIMDALL_WATERFALL_TABLE_COLUMNS`)
// with indented tree connectors (`├─ `, `│  `) and proportional latency heatbar (`████░░░░`).
heimdall_waterfall_row_cells :: proc(
	row_idx: i32,
	item: Heimdall_Span_Tree_Item,
	max_dur_ns: i64,
	alloc := context.temp_allocator,
) -> [8]Table_Cell {
	rec := item.record
	idx_str  := fmt.aprintf("%04d", row_idx, allocator = alloc)
	span_str := fmt.aprintf("%02d<%02d", rec.span_id % 100, rec.parent_id % 100, allocator = alloc)
	dur_us   := max(i64(0), rec.duration_ns) / 1000
	dur_str  := fmt.aprintf("%dus", dur_us, allocator = alloc)
	kids_str := fmt.aprintf("%d", item.child_cnt, allocator = alloc)

	// Indented call-tree label
	tree_b := strings.builder_make(0, 32, alloc)
	clamped_depth := clamp(item.depth, 0, 8)
	for d := 0; d < clamped_depth; d += 1 {
		if d + 1 == clamped_depth {
			strings.write_string(&tree_b, "├─ ")
		} else {
			strings.write_string(&tree_b, "│  ")
		}
	}
	if item.child_cnt > 0 {
		strings.write_string(&tree_b, "▾ ")
	} else if clamped_depth == 0 {
		strings.write_string(&tree_b, "• ")
	}
	strings.write_string(&tree_b, rec.name)

	// 8-cell proportional latency heat bar (`█` vs `░`)
	denom := max(i64(1), max_dur_ns)
	clamped_dur := max(i64(0), rec.duration_ns)
	filled := int((clamped_dur * 8 + denom - 1) / denom)
	if clamped_dur > 0 {
		filled = clamp(filled, 1, 8)
	} else {
		filled = 0
	}
	heat_b := strings.builder_make(0, 24, alloc)
	for i := 0; i < 8; i += 1 {
		strings.write_rune(&heat_b, '█' if i < filled else '░')
	}
	heat_fg := rgb(125, 225, 165)
	if filled >= 7 {
		heat_fg = rgb(255, 125, 125)
	} else if filled >= 4 {
		heat_fg = rgb(255, 205, 110)
	}

	return [8]Table_Cell{
		0 = {text = idx_str},
		1 = {text = heimdall_status_label(rec.status), fg = heimdall_status_color(rec.status)},
		2 = {text = rec.scope},
		3 = {text = strings.to_string(tree_b), fg = rgb(140, 215, 255) if item.depth == 0 else rgb(215, 225, 240), style = {.Bold} if item.depth == 0 else {}},
		4 = {text = span_str},
		5 = {text = dur_str, fg = heat_fg},
		6 = {text = strings.to_string(heat_b), fg = heat_fg},
		7 = {text = kids_str},
	}
}

// Formats a `Heimdall_Scope_Stat` into 8 aligned `Table_Cell` columns (`HEIMDALL_SCOPE_STATS_TABLE_COLUMNS`).
heimdall_scope_stat_row_cells :: proc(
	stat: Heimdall_Scope_Stat,
	alloc := context.temp_allocator,
) -> [8]Table_Cell {
	avg_us: i64 = 0
	if stat.span_count > 0 {
		avg_us = (stat.total_dur_ns / i64(stat.span_count)) / 1000
	}
	max_us := stat.max_dur_ns / 1000

	err_fg := rgb(255, 120, 120) if stat.error_count > 0 else rgb(135, 225, 165)
	return [8]Table_Cell{
		0 = {text = stat.scope, fg = rgb(130, 205, 255), style = {.Bold}},
		1 = {text = fmt.aprintf("%d", stat.total_records, allocator = alloc)},
		2 = {text = fmt.aprintf("%d", stat.span_count, allocator = alloc), fg = heimdall_kind_color(.Span)},
		3 = {text = fmt.aprintf("%d", stat.metric_count, allocator = alloc), fg = heimdall_kind_color(.Gauge)},
		4 = {text = fmt.aprintf("%d", stat.event_count, allocator = alloc), fg = heimdall_kind_color(.Event)},
		5 = {text = fmt.aprintf("%d", stat.error_count, allocator = alloc), fg = err_fg},
		6 = {text = fmt.aprintf("%dus", avg_us, allocator = alloc)},
		7 = {text = fmt.aprintf("%dus", max_us, allocator = alloc), fg = rgb(255, 205, 115) if max_us >= 250 else Color{}},
	}
}


