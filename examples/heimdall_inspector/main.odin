package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "../../bifrost"
import actor "../../deps/heimdall/deps/sleipnir/actor"
import heimdall "../../deps/heimdall/heimdall"
import xitdb "../../deps/xitdb/xitdb"

// =============================================================================
// Specialized Heimdall Telemetry Studio Actions
// =============================================================================

Heimdall_Inspector_Action :: enum u8 {
	None = 0,
	Reload,
	Cycle_Kind,
	Cycle_Scope,
	Tab_Records,
	Tab_Waterfall,
	Tab_Scopes,
	Inject_Burst,
}

Heimdall_Inspector_Actions :: struct {
	reload:        Heimdall_Inspector_Action `bifrost:"action=heimdall.reload,chord=r|<C-r>,policy=global,allow_in_edit=true,category=Telemetry,label=Flush & Reload Heimdall .arrow Segments,desc=Reload (r/^R)"`,
	cycle_kind:    Heimdall_Inspector_Action `bifrost:"action=heimdall.cycle_kind,chord=k|<C-k>,policy=global,allow_in_edit=true,category=Filter,label=Cycle Record Kind Filter (ALL/SPANS/METRICS/EVENTS/ERRORS),desc=Kind (k/^K)"`,
	cycle_scope:   Heimdall_Inspector_Action `bifrost:"action=heimdall.cycle_scope,chord=s,policy=root,category=Filter,label=Cycle Telemetry Scope Filter,desc=Scope (s)"`,
	tab_records:   Heimdall_Inspector_Action `bifrost:"action=heimdall.tab_records,chord=1|<M-1>,policy=global,allow_in_edit=true,category=View,label=Switch to Arrow IPC Records Table,desc=Records (1)"`,
	tab_waterfall: Heimdall_Inspector_Action `bifrost:"action=heimdall.tab_waterfall,chord=2|<M-2>,policy=global,allow_in_edit=true,category=View,label=Switch to Span Call-Tree & Latency Waterfall,desc=Waterfall (2)"`,
	tab_scopes:    Heimdall_Inspector_Action `bifrost:"action=heimdall.tab_scopes,chord=3|<M-3>,policy=global,allow_in_edit=true,category=View,label=Switch to Scope & Operation Latency Breakdown,desc=Scopes (3)"`,
	inject_burst:  Heimdall_Inspector_Action `bifrost:"action=heimdall.inject_burst,chord=w|<C-b>,policy=global,allow_in_edit=true,category=Workload,label=Inject Synthetic Nested Span & Metric Burst,desc=Burst (w)"`,
}

Heimdall_Inspector_App :: struct {
	prefix:          string,
	recorder:        ^heimdall.Recorder,
	track:           ^mem.Tracking_Allocator,
	store:           bifrost.Heimdall_Segment_Store,
	perf:            bifrost.Heimdall_Runtime_Metrics,
	filter_kind:     bifrost.Heimdall_Filter_Kind,
	scope_buf:       [64]u8, // Stored by value (not zero-copy pointer) so reloads across new scopes remain stable
	scope_len:       int,
	query_buf:       [64]u8,
	query_len:       int,
	burst_seq:       int,
	last_reload_tick: time.Tick,
	pending_reload:  bool,   // Deferred reload flag so `recorder_flush` runs outside `actor_turn` / `flush_frame` spans
}

active_inspector_scope :: proc "contextless" (app: ^Heimdall_Inspector_App) -> string {
	if app == nil || app.scope_len <= 0 {
		return ""
	}
	return string(app.scope_buf[:app.scope_len])
}

set_inspector_scope :: proc "contextless" (app: ^Heimdall_Inspector_App, scope: string) {
	if app == nil || len(scope) == 0 {
		if app != nil {
			app.scope_len = 0
		}
		return
	}
	n := min(len(scope), len(app.scope_buf))
	copy(app.scope_buf[:n], scope[:n])
	app.scope_len = n
}

active_inspector_query :: proc "contextless" (app: ^Heimdall_Inspector_App) -> string {
	if app == nil || app.query_len <= 0 {
		return ""
	}
	return string(app.query_buf[:app.query_len])
}

set_inspector_query :: proc "contextless" (app: ^Heimdall_Inspector_App, q: string) {
	if app == nil || len(q) == 0 {
		if app != nil {
			app.query_len = 0
		}
		return
	}
	n := min(len(q), len(app.query_buf))
	copy(app.query_buf[:n], q[:n])
	app.query_len = n
}

filter_kind_name :: proc "contextless" (k: bifrost.Heimdall_Filter_Kind) -> string {
	switch k {
	case .All:          return "ALL"
	case .Spans_Only:   return "SPANS"
	case .Metrics_Only: return "METRICS"
	case .Events_Only:  return "EVENTS"
	case .Errors_Only:  return "ERRORS"
	}
	return "ALL"
}

refresh_inspector_store :: proc(app: ^Heimdall_Inspector_App, force_full := false) {
	if app == nil || app.recorder == nil {
		return
	}
	heimdall.recorder_flush(app.recorder)
	if force_full {
		_, _ = bifrost.heimdall_store_load_prefix(&app.store, app.prefix)
	} else {
		_, _ = bifrost.heimdall_store_load_prefix_incremental(&app.store, app.prefix)
	}

	scope_filter := active_inspector_scope(app)
	if len(scope_filter) > 0 {
		found := false
		for stat in app.store.scope_stats {
			if stat.scope == scope_filter {
				found = true
				break
			}
		}
		if !found {
			app.scope_len = 0
			scope_filter  = ""
		}
	}
	// `heimdall_store_load_file` already appends newly loaded matching records to `store.filtered_idxs`.
	// Only re-scan `store.records` when `force_full` is true.
	if force_full {
		_ = bifrost.heimdall_store_apply_filter(
			&app.store,
			app.filter_kind,
			scope_filter,
			active_inspector_query(app),
		)
	}
}

inject_synthetic_telemetry_burst :: proc(app: ^Heimdall_Inspector_App) {
	if app == nil || app.recorder == nil {
		return
	}
	app.burst_seq += 1
	seq := app.burst_seq
	rec := app.recorder

	{
		heimdall.scoped_span(rec, "bifrost.coordinator", "synthetic_burst_turn", i64(seq))
		heimdall.counter_add(rec, "bifrost.coordinator", "bursts_injected", 1.0, i64(seq))
		{
			heimdall.scoped_span(rec, "bifrost.worker", "xitdb_batch_commit", i64(seq * 10))
			heimdall.gauge_set(rec, "bifrost.worker", "pending_tx_slots", f64(16 + (seq % 8) * 4), i64(seq))
			{
				heimdall.scoped_span(rec, "bifrost.layout", "end_layout", 48)
				heimdall.gauge_set(rec, "bifrost.layout", "layout_nodes", 48.0, i64(seq))
			}
			{
				heimdall.scoped_span(rec, "bifrost.renderer", "render_layout", 1920)
				heimdall.histogram_record(rec, "bifrost.renderer", "ansi_diff_bytes", f64(4200 + (seq % 7) * 650), i64(seq))
			}
		}
		if seq % 2 == 0 {
			heimdall.event_emit(rec, "bifrost.worker", "btree_compaction_checkpoint", i64(seq), .Ok)
		} else {
			heimdall.event_emit(rec, "bifrost.worker", "slow_leaf_split_warning", i64(seq), .Error)
		}
	}
}

format_selected_record_detail :: proc(app: ^Heimdall_Inspector_App, coord: ^bifrost.UI_Coordinator_State, active_tab: int, alloc := context.temp_allocator) -> string {
	if app == nil || coord == nil {
		return " Selected: none"
	}
	switch active_tab {
	case 0:
		sel_row := int(bifrost.get_selected_row(&coord.input, "records_pane"))
		rec, ok := bifrost.heimdall_store_get_filtered_record(&app.store, sel_row)
		if !ok {
			return " Selected Record: <none matching active filter>"
		}
		parent_info := "root (parent=0)"
		if rec.parent_id != 0 {
			parent_ops := ""
			for cand in app.store.records {
				if cand.kind == .Span && cand.span_id == rec.parent_id {
					parent_ops = cand.name
					break
				}
			}
			if len(parent_ops) > 0 {
				parent_info = fmt.aprintf("parent=#%d (%s)", rec.parent_id, parent_ops, allocator = alloc)
			} else {
				parent_info = fmt.aprintf("parent=#%d", rec.parent_id, allocator = alloc)
			}
		}
		return fmt.aprintf(
			" Selected [%04d]: %s %s.%s | status=%s | span=#%d (%s) | ts=%dns | dur=%dus (%dns) | val=%.2f | attr=%d",
			sel_row,
			bifrost.heimdall_kind_label(rec.kind),
			rec.scope,
			rec.name,
			bifrost.heimdall_status_label(rec.status),
			rec.span_id,
			parent_info,
			rec.timestamp_ns,
			max(i64(0), rec.duration_ns) / 1000,
			rec.duration_ns,
			rec.value_f64,
			rec.attr_i64,
			allocator = alloc,
		)
	case 1:
		sel_row := int(bifrost.get_selected_row(&coord.input, "waterfall_pane"))
		if sel_row < 0 || sel_row >= len(app.store.span_tree_items) {
			return " Selected Call-Tree Span: <none>"
		}
		item := app.store.span_tree_items[sel_row]
		rec  := item.record
		pct: f64 = 0
		if app.store.max_duration_ns > 0 {
			pct = (f64(max(i64(0), rec.duration_ns)) * 100.0) / f64(app.store.max_duration_ns)
		}
		return fmt.aprintf(
			" Call-Tree Span [%04d]: depth=%d children=%d | %s.%s (#%d <- #%d) | dur=%dus (%.1f%% of max) | attr=%d",
			sel_row,
			item.depth,
			item.child_cnt,
			rec.scope,
			rec.name,
			rec.span_id,
			rec.parent_id,
			max(i64(0), rec.duration_ns) / 1000,
			pct,
			rec.attr_i64,
			allocator = alloc,
		)
	case 2:
		sel_row := int(bifrost.get_selected_row(&coord.input, "scope_stats_pane"))
		if sel_row < 0 || sel_row >= len(app.store.scope_stats) {
			return " Selected Scope: <none>"
		}
		st := app.store.scope_stats[sel_row]
		avg_us: i64 = 0
		if st.span_count > 0 {
			avg_us = (st.total_dur_ns / i64(st.span_count)) / 1000
		}
		return fmt.aprintf(
			" Scope [%s]: records=%d spans=%d metrics=%d events=%d errors=%d | avg_span=%dus max_span=%dus total_span=%dus",
			st.scope,
			st.total_records,
			st.span_count,
			st.metric_count,
			st.event_count,
			st.error_count,
			avg_us,
			st.max_dur_ns / 1000,
			st.total_dur_ns / 1000,
			allocator = alloc,
		)
	}
	return ""
}

render_heimdall_inspector_pass :: proc(coord: ^bifrost.UI_Coordinator_State) {
	app := (^Heimdall_Inspector_App)(coord.user_ptr)
	if app == nil {
		return
	}

	coord.use_widget_pipeline = true
	bg_dark  := bifrost.rgb(16, 20, 28)
	panel_bg := bifrost.rgb(22, 28, 40)
	bar_bg   := bifrost.rgb(26, 36, 54)
	text_fg  := bifrost.rgb(215, 225, 240)
	muted_fg := bifrost.rgb(140, 160, 185)
	accent   := bifrost.rgb(120, 200, 255)

	bifrost.begin_frame(&coord.screen, bg_dark)
	bifrost.begin_layout(&coord.layout_ctx, i32(coord.cols), i32(coord.rows))

	// Synchronize live substring search box into `app.store` filter when edited
	if bifrost.was_text_changed(&coord.input, "hm_search_box") {
		q_txt := bifrost.get_text(&coord.input, "hm_search_box")
		set_inspector_query(app, q_txt)
		_ = bifrost.heimdall_store_apply_filter(
			&app.store,
			app.filter_kind,
			active_inspector_scope(app),
			active_inspector_query(app),
		)
		slot := bifrost.get_scroll_slot(&coord.input, bifrost.hash_id("records_pane"))
		if slot != nil {
			slot.selected_row = 0
			slot.offset       = 0
		}
	}

	rec_stats := bifrost.heimdall_snapshot_recorder_stats(app.recorder)
	scope_filter := active_inspector_scope(app)
	if len(scope_filter) == 0 {
		scope_filter = "ALL SCOPES"
	}

	// Sample FPS, frame time, CPU %, RSS (MB), and Heap (KB/MB)
	latest_frame_dur_ns: i64 = 0
	for i := len(app.store.records) - 1; i >= 0; i -= 1 {
		r := app.store.records[i]
		if r.kind == .Span && (r.name == "flush_frame" || r.name == "render_layout") {
			latest_frame_dur_ns = r.duration_ns
			break
		}
	}
	bifrost.heimdall_sample_runtime_metrics(
		&app.perf,
		u64(coord.total_frames + 1),
		latest_frame_dur_ns,
		app.track,
	)

	if bifrost.container(
		&coord.layout_ctx,
		"hm_inspector_root",
		bifrost.Box_Config{
			dir         = .Column,
			width       = bifrost.fixed(i32(coord.cols)),
			height      = bifrost.fixed(i32(coord.rows)),
			focus_flags = {.Focus_Scope},
			focus_scope = true,
		},
	) {
		// 1. Header Bar
		header_str := fmt.tprintf(
			"BIFROST x HEIMDALL TELEMETRY INSPECTOR | backend=%s segs=%d rows=%d (filtered=%d) | filter=%s scope=%s",
			bifrost.heimdall_backend_label(rec_stats.backend),
			app.store.segment_count,
			len(app.store.records),
			len(app.store.filtered_idxs),
			filter_kind_name(app.filter_kind),
			scope_filter,
		)
		coord.screen.paints[bifrost.hash_id("hm_header")] = bifrost.Paint_Spec{
			text    = header_str,
			fg      = bifrost.rgb(230, 245, 255),
			bg      = bifrost.rgb(22, 34, 56),
			style   = {.Bold},
			fill_bg = true,
		}
		_ = bifrost.leaf(&coord.layout_ctx, "hm_header", 24, 1, bifrost.Box_Config{
			width  = bifrost.grow(1),
			height = bifrost.fixed(1),
		})

		// 1b. Live App Performance & Resource Strip (FPS, Frame Time, CPU %, RSS MB, Heap KB/MB, Segments)
		rss_mb   := f64(app.perf.rss_kb) / 1024.0
		heap_kb  := f64(app.perf.heap_bytes) / 1024.0
		peak_kb  := f64(app.perf.peak_heap_bytes) / 1024.0
		perf_str := fmt.tprintf(
			" Perf: %.1f FPS (frame=%dus) | CPU: %.1f%% | RSS: %.1f MB | Heap: %.0f KB (peak %.0f KB) | Store: %d segs (%d rows, %d tree)",
			app.perf.fps,
			app.perf.frame_time_us,
			app.perf.cpu_percent,
			rss_mb,
			heap_kb,
			peak_kb,
			app.store.segment_count,
			len(app.store.records),
			len(app.store.span_tree_items),
		)
		perf_fg := bifrost.rgb(135, 230, 170)
		if app.perf.cpu_percent >= 50.0 || app.perf.fps < 25.0 {
			perf_fg = bifrost.rgb(255, 205, 110)
		}
		coord.screen.paints[bifrost.hash_id("hm_perf_strip")] = bifrost.Paint_Spec{
			text    = perf_str,
			fg      = perf_fg,
			bg      = bifrost.rgb(20, 28, 42),
			style   = {.Bold},
			fill_bg = true,
		}
		_ = bifrost.leaf(&coord.layout_ctx, "hm_perf_strip", 24, 1, bifrost.Box_Config{
			width  = bifrost.grow(1),
			height = bifrost.fixed(1),
		})

		// 2. Top Analytics Row (Sparkline of Span Durations + Braille Canvas of Diff Bytes)
		chart_h: i32 = 4
		if bifrost.container(
			&coord.layout_ctx,
			"hm_charts_row",
			bifrost.Box_Config{
				dir    = .Row,
				width  = bifrost.grow(1),
				height = bifrost.fixed(chart_h),
			},
		) {
			raw_scope_filter := active_inspector_scope(app)
			durs := bifrost.heimdall_store_extract_span_durations_us(&app.store, 36, raw_scope_filter)
			max_dur_ns := app.store.max_duration_ns
			if len(raw_scope_filter) > 0 {
				for st in app.store.scope_stats {
					if st.scope == raw_scope_filter {
						max_dur_ns = st.max_dur_ns
						break
					}
				}
			}
			_ = bifrost.ui_sparkline(
				&coord.layout_ctx,
				&coord.screen,
				"hm_span_spark",
				durs,
				bifrost.Sparkline_Config{
					title     = fmt.tprintf("Span Durations us (max %d us)", max_dur_ns / 1000),
					width     = bifrost.grow(1),
					height    = bifrost.fixed(chart_h),
					border    = .Plain,
					fg        = bifrost.rgb(110, 225, 165),
					bg        = panel_bg,
					border_fg = bifrost.rgb(75, 100, 130),
					title_fg  = accent,
					fill_bg   = true,
				},
			)

			_ = bifrost.ui_canvas(
				&coord.layout_ctx,
				&coord.screen,
				"hm_metric_canvas",
				bifrost.Canvas_Config{
					title     = "Metric Series (Braille)",
					width     = bifrost.fixed(38),
					height    = bifrost.fixed(chart_h),
					border    = .Plain,
					fg        = bifrost.rgb(120, 195, 255),
					bg        = panel_bg,
					border_fg = bifrost.rgb(75, 100, 130),
					title_fg  = accent,
					userdata  = app,
					draw_fn   = proc(c: ^bifrost.Braille_Canvas, ud: rawptr) {
						a := (^Heimdall_Inspector_App)(ud)
						if a == nil {
							return
						}
						series, min_v, max_v := bifrost.heimdall_store_extract_metric_series(&a.store, "", 36)
						if len(series) > 0 {
							bifrost.canvas_draw_series(c, series, min_v, max_v, bifrost.rgb(120, 195, 255))
						}
					},
				},
			)
		}

		// 3. Main Body Split (Left: Scope/Op Tree + Controls | Right: 3-Tab Heimdall Workspace)
		body_h := max(i32(6), i32(coord.rows) - (chart_h + 5))
		cur_tab := 0
		if bifrost.ui_scope(
			&coord.layout_ctx,
			&coord.screen,
			"hm_body_scope",
			bifrost.Scope_Config{
				dir    = .Row,
				width  = bifrost.grow(1),
				height = bifrost.fixed(body_h),
			},
		) {
			sidebar_w := bifrost.get_split_size(&coord.input, "hm_main_split", 30, 24, max(28, i32(coord.cols) - 44))

			if bifrost.ui_scope(
				&coord.layout_ctx,
				&coord.screen,
				"hm_left_sidebar",
				bifrost.Scope_Config{
					dir    = .Column,
					width  = bifrost.fixed(sidebar_w),
					height = bifrost.grow(1),
				},
			) {
				// Live search box + quick action buttons
				bifrost.ui_text_input(
					&coord.layout_ctx,
					&coord.screen,
					&coord.input,
					"hm_search_box",
					bifrost.Text_Input_Config{
						placeholder    = "Filter op/scope (/ to edit)...",
						linked_list_id = "records_pane",
						width          = bifrost.grow(1),
						height         = bifrost.fixed(1),
						fg             = text_fg,
						bg             = bar_bg,
						placeholder_fg = muted_fg,
					},
				)

				tree_nodes := bifrost.heimdall_store_get_cached_scope_tree(&app.store)
				tslice: bifrost.Tree_Slice
				_ = bifrost.ui_tree(
					&coord.layout_ctx,
					&coord.screen,
					&coord.input,
					"hm_scope_tree",
					tree_nodes,
					bifrost.Tree_Config{
						title     = "Telemetry Scopes & Ops",
						width     = bifrost.grow(1),
						height    = bifrost.grow(1),
						border    = .Plain,
						fg        = bifrost.rgb(210, 225, 240),
						bg        = panel_bg,
						border_fg = bifrost.rgb(80, 105, 135),
						title_fg  = accent,
					},
					&tslice,
				)
			}

			bifrost.ui_splitter(
				&coord.layout_ctx,
				&coord.screen,
				&coord.input,
				"hm_main_split",
				bifrost.Splitter_Config{
					dir          = .Row,
					default_size = 30,
					min_first    = 24,
					min_second   = 40,
					fg           = muted_fg,
					bg           = bg_dark,
					active_fg    = accent,
				},
			)

			// Right Workspace Tabs:
			//   1: Arrow IPC Records (9-column `ui_table`)
			//   2: Span Call-Tree & Latency Waterfall (8-column `ui_table` with heatbars)
			//   3: Scope & Operation Breakdown (8-column `ui_table` with Avg/Max latency)
			tab_specs := [3]bifrost.Tab_Item_Spec{
				{label = "Arrow IPC Records",      badge = "IPC",  key_hint = "1:"},
				{label = "Span Call-Tree & Heat",  badge = "TREE", key_hint = "2:"},
				{label = "Scope Latency Stats",    badge = "STAT", key_hint = "3:"},
			}

			if bifrost.ui_tabs(
				&coord.layout_ctx,
				&coord.screen,
				&coord.input,
				"hm_workspace_tabs",
				tab_specs[:],
				bifrost.Tabs_Config{
					width            = bifrost.grow(1),
					height           = bifrost.grow(1),
					body_dir         = .Column,
					body_padding     = bifrost.pad_xy(0, 0),
					body_gap         = 0,
					body_border      = .None,
					fg               = text_fg,
					bg               = panel_bg,
					header_bg        = bar_bg,
					active_fg        = bifrost.rgb(255, 245, 155),
					active_bg        = bifrost.rgb(42, 60, 90),
					inactive_fg      = muted_fg,
					inactive_bg      = bar_bg,
					badge_fg         = accent,
					sep_fg           = bifrost.rgb(75, 100, 130),
					show_index_hints = true,
				},
				&cur_tab,
			) {
				visible_rows := max(1, int(body_h) - 5)

				switch cur_tab {
				case 0:
					total_filtered := len(app.store.filtered_idxs)
					bifrost.ui_sync_vlist_to_slot(coord, "records_pane", total_filtered, visible_rows)

					vslice: bifrost.Virtual_Slice
					ins_cols := bifrost.heimdall_inspector_table_columns(context.temp_allocator)
					if bifrost.ui_table(
						&coord.layout_ctx,
						&coord.screen,
						&coord.input,
						"records_pane",
						ins_cols,
						i32(total_filtered),
						bifrost.Table_Config{
							title         = fmt.tprintf("Arrow Telemetry Records (%d shown / %d total)", total_filtered, len(app.store.records)),
							width         = bifrost.grow(1),
							height        = bifrost.grow(1),
							border        = .Plain,
							fg            = text_fg,
							bg            = panel_bg,
							border_fg     = bifrost.rgb(80, 105, 135),
							title_fg      = accent,
							header_fg     = accent,
							header_bg     = bar_bg,
							sep_fg        = bifrost.rgb(80, 105, 135),
							sel_fg        = bifrost.rgb(255, 255, 185),
							sel_bg        = bifrost.rgb(45, 68, 102),
							fallback_rows = i32(visible_rows),
							focus_flags   = {.Focusable, .Default_Focus},
						},
						&vslice,
					) {
						for vis_row := vslice.start_row; vis_row < vslice.end_row; vis_row += 1 {
							rec, r_ok := bifrost.heimdall_store_get_filtered_record(&app.store, int(vis_row))
							if !r_ok {
								continue
							}
							cells := bifrost.heimdall_inspector_record_cells(vis_row, rec, context.temp_allocator)
							row_fg := bifrost.rgb(255, 135, 135) if rec.status == .Error else bifrost.Color{}
							bifrost.ui_table_row(&coord.layout_ctx, &coord.screen, vis_row, cells[:], fg = row_fg)
						}
					}

				case 1:
					total_tree := i32(len(app.store.span_tree_items))
					wf_vslice: bifrost.Virtual_Slice
					wf_cols := bifrost.heimdall_waterfall_table_columns(context.temp_allocator)
					if bifrost.ui_table(
						&coord.layout_ctx,
						&coord.screen,
						&coord.input,
						"waterfall_pane",
						wf_cols,
						total_tree,
						bifrost.Table_Config{
							title         = fmt.tprintf("Hierarchical Span Call-Tree & Latency Waterfall (%d spans, max %d us)", total_tree, app.store.max_duration_ns / 1000),
							width         = bifrost.grow(1),
							height        = bifrost.grow(1),
							border        = .Plain,
							fg            = text_fg,
							bg            = panel_bg,
							border_fg     = bifrost.rgb(80, 105, 135),
							title_fg      = accent,
							header_fg     = accent,
							header_bg     = bar_bg,
							sep_fg        = bifrost.rgb(80, 105, 135),
							sel_fg        = bifrost.rgb(255, 255, 185),
							sel_bg        = bifrost.rgb(45, 68, 102),
							fallback_rows = i32(visible_rows),
							focus_flags   = {.Focusable, .Default_Focus},
						},
						&wf_vslice,
					) {
						for r_idx := wf_vslice.start_row; r_idx < wf_vslice.end_row; r_idx += 1 {
							if int(r_idx) < 0 || int(r_idx) >= len(app.store.span_tree_items) {
								continue
							}
							item := app.store.span_tree_items[r_idx]
							cells := bifrost.heimdall_waterfall_row_cells(r_idx, item, app.store.max_duration_ns, context.temp_allocator)
							bifrost.ui_table_row(&coord.layout_ctx, &coord.screen, r_idx, cells[:])
						}
					}

				case 2:
					total_scopes := i32(len(app.store.scope_stats))
					sc_vslice: bifrost.Virtual_Slice
					sc_cols := bifrost.heimdall_scope_stats_table_columns(context.temp_allocator)
					if bifrost.ui_table(
						&coord.layout_ctx,
						&coord.screen,
						&coord.input,
						"scope_stats_pane",
						sc_cols,
						total_scopes,
						bifrost.Table_Config{
							title         = fmt.tprintf("Telemetry Scope Latency & Volume Breakdown (%d scopes)", total_scopes),
							width         = bifrost.grow(1),
							height        = bifrost.grow(1),
							border        = .Plain,
							fg            = text_fg,
							bg            = panel_bg,
							border_fg     = bifrost.rgb(80, 105, 135),
							title_fg      = accent,
							header_fg     = accent,
							header_bg     = bar_bg,
							sep_fg        = bifrost.rgb(80, 105, 135),
							sel_fg        = bifrost.rgb(255, 255, 185),
							sel_bg        = bifrost.rgb(45, 68, 102),
							fallback_rows = i32(visible_rows),
							focus_flags   = {.Focusable, .Default_Focus},
						},
						&sc_vslice,
					) {
						for r_idx := sc_vslice.start_row; r_idx < sc_vslice.end_row; r_idx += 1 {
							if int(r_idx) < 0 || int(r_idx) >= len(app.store.scope_stats) {
								continue
							}
							stat := app.store.scope_stats[r_idx]
							cells := bifrost.heimdall_scope_stat_row_cells(stat, context.temp_allocator)
							bifrost.ui_table_row(&coord.layout_ctx, &coord.screen, r_idx, cells[:])
						}
					}
				}
			}
		}

		// 4. Live Selected Record / Span / Scope Detail Inspector Bar
		detail_str := format_selected_record_detail(app, coord, cur_tab, context.temp_allocator)
		coord.screen.paints[bifrost.hash_id("hm_detail_bar")] = bifrost.Paint_Spec{
			text    = detail_str,
			fg      = bifrost.rgb(255, 235, 145),
			bg      = bar_bg,
			style   = {.Bold},
			fill_bg = true,
		}
		_ = bifrost.leaf(&coord.layout_ctx, "hm_detail_bar", 24, 1, bifrost.Box_Config{
			width  = bifrost.grow(1),
			height = bifrost.fixed(1),
		})

		// 5. Footer Status & Shortcut Bar
		footer_str := fmt.tprintf(
			"Spans=%d Tree=%d Counters=%d Gauges=%d Hists=%d Events=%d Errs=%d Drop=%d | [1-3] Views  [r] Reload  [k] Kind  [s] Scope  [w] Burst  [q] Quit",
			app.store.total_spans,
			len(app.store.span_tree_items),
			app.store.total_counters,
			app.store.total_gauges,
			app.store.total_hists,
			app.store.total_events,
			app.store.total_errors,
			rec_stats.dropped_records,
		)
		coord.screen.paints[bifrost.hash_id("hm_footer")] = bifrost.Paint_Spec{
			text    = footer_str,
			fg      = bifrost.rgb(185, 205, 225),
			bg      = bifrost.rgb(18, 25, 38),
			fill_bg = true,
		}
		_ = bifrost.leaf(&coord.layout_ctx, "hm_footer", 24, 1, bifrost.Box_Config{
			width  = bifrost.grow(1),
			height = bifrost.fixed(1),
		})

		bifrost.ui_key_hint_bar(&coord.layout_ctx, &coord.screen, &coord.input, "hm_hint_bar")
	}

	coord.palette.is_open = coord.palette_open
	if coord.palette.is_open {
		bifrost.ui_command_palette(&coord.layout_ctx, &coord.screen, &coord.input, &coord.palette, 60, 5)
	}

	bifrost.end_layout(&coord.layout_ctx)
}

on_action_reload :: proc(coord: ^bifrost.UI_Coordinator_State, _: string, userdata: rawptr) {
	app := (^Heimdall_Inspector_App)(userdata)
	if app == nil {
		return
	}
	// Coalesce rapid auto-repeat 'r' presses to at most one disk flush + incremental reload
	// per 40ms window, and defer the actual `recorder_flush` + `refresh_inspector_store` to
	// the outer loop after `ui_coordinator_receive`'s `actor_turn` and `flush_frame` spans close.
	now := time.tick_now()
	if app.last_reload_tick._nsec != 0 && time.tick_diff(app.last_reload_tick, now) < 40 * time.Millisecond {
		app.pending_reload = true
		return
	}
	app.last_reload_tick = now
	app.pending_reload   = true
	coord.dirty          = true
}

on_action_cycle_kind :: proc(coord: ^bifrost.UI_Coordinator_State, _: string, userdata: rawptr) {
	app := (^Heimdall_Inspector_App)(userdata)
	if app == nil {
		return
	}
	next_ord := (int(app.filter_kind) + 1) % len(bifrost.Heimdall_Filter_Kind)
	app.filter_kind = bifrost.Heimdall_Filter_Kind(next_ord)
	_ = bifrost.heimdall_store_apply_filter(
		&app.store,
		app.filter_kind,
		active_inspector_scope(app),
		active_inspector_query(app),
	)
	coord.vlist.selected_row  = 0
	coord.vlist.scroll_offset = 0
	bifrost.ui_sync_vlist_to_slot(coord, "records_pane", len(app.store.filtered_idxs), max(1, coord.vlist.viewport_rows))
	coord.dirty               = true
}

on_action_cycle_scope :: proc(coord: ^bifrost.UI_Coordinator_State, _: string, userdata: rawptr) {
	app := (^Heimdall_Inspector_App)(userdata)
	if app == nil {
		return
	}
	cur_scope := active_inspector_scope(app)
	cur_idx := -1
	for stat, idx in app.store.scope_stats {
		if stat.scope == cur_scope {
			cur_idx = idx
			break
		}
	}
	if len(app.store.scope_stats) == 0 || cur_idx + 1 >= len(app.store.scope_stats) {
		set_inspector_scope(app, "")
	} else {
		set_inspector_scope(app, app.store.scope_stats[cur_idx + 1].scope)
	}
	_ = bifrost.heimdall_store_apply_filter(
		&app.store,
		app.filter_kind,
		active_inspector_scope(app),
		active_inspector_query(app),
	)
	coord.vlist.selected_row  = 0
	coord.vlist.scroll_offset = 0
	bifrost.ui_sync_vlist_to_slot(coord, "records_pane", len(app.store.filtered_idxs), max(1, coord.vlist.viewport_rows))
	coord.dirty               = true
}

on_action_switch_tab :: proc(coord: ^bifrost.UI_Coordinator_State, action_name: string, _: rawptr) {
	switch action_name {
	case "heimdall.tab_records":
		bifrost.set_active_tab(&coord.input, "hm_workspace_tabs", 0, true)
		coord.input.wants_focus_id = bifrost.hash_id("records_pane")
	case "heimdall.tab_waterfall":
		bifrost.set_active_tab(&coord.input, "hm_workspace_tabs", 1, true)
		coord.input.wants_focus_id = bifrost.hash_id("waterfall_pane")
	case "heimdall.tab_scopes":
		bifrost.set_active_tab(&coord.input, "hm_workspace_tabs", 2, true)
		coord.input.wants_focus_id = bifrost.hash_id("scope_stats_pane")
	}
	coord.dirty = true
}

on_action_inject_burst :: proc(coord: ^bifrost.UI_Coordinator_State, _: string, userdata: rawptr) {
	app := (^Heimdall_Inspector_App)(userdata)
	if app == nil {
		return
	}
	inject_synthetic_telemetry_burst(app)
	app.pending_reload = true
	coord.dirty        = true
}

extract_row_text :: proc(coord: ^bifrost.UI_Coordinator_State, row: int, alloc := context.temp_allocator) -> string {
	if coord == nil || row < 0 || row >= coord.rows {
		return ""
	}
	b := strings.builder_make(0, coord.cols, alloc)
	for x := 0; x < coord.cols; x += 1 {
		cell := coord.front_buf[row * coord.cols + x]
		if cell.width == 0 || cell.ch == 0 {
			continue
		}
		strings.write_rune(&b, cell.ch)
	}
	return strings.trim_right_space(strings.to_string(b))
}

run_heimdall_inspector :: proc(live_tty: bool, track: ^mem.Tracking_Allocator = nil) -> bool {
	defer free_all(context.temp_allocator)

	tmp_dir := ".tmp/heimdall_inspector_demo"
	_ = os.remove_all(tmp_dir)
	if os.make_directory_all(tmp_dir) != nil {
		fmt.eprintln("Failed to create temporary directory for Heimdall segments")
		return false
	}
	defer {
		_ = os.remove_all(tmp_dir)
	}
	prefix := ".tmp/heimdall_inspector_demo/telemetry"

	rec: heimdall.Recorder
	if heimdall.recorder_init(&rec, heimdall.Config{
		file_prefix      = prefix,
		batches_per_file = 4,
		ring_page_count  = 4,
	}, context.allocator) != nil {
		fmt.eprintln("Failed to initialize Heimdall recorder")
		return false
	}
	defer heimdall.recorder_destroy(&rec)

	app: Heimdall_Inspector_App
	app.prefix   = prefix
	app.recorder = &rec
	app.track    = track
	if bifrost.heimdall_store_init(&app.store, context.allocator) != nil {
		return false
	}
	defer bifrost.heimdall_store_destroy(&app.store)

	core := xitdb.core_memory_init(context.allocator)
	defer _ = xitdb.core_destroy(&core)

	db, db_err := xitdb.database_init(&core)
	if db_err != nil {
		return false
	}
	shared := bifrost.Xitdb_Shared_Handle{db = &db}

	sched: actor.Scheduler
	if actor.scheduler_init(&sched, actor.Scheduler_Config{
		num_workers    = 2,
		num_shards     = 2,
		batch_quota    = 2048,
		enable_parking = true,
	}, context.allocator) != nil {
		return false
	}
	ui_actor: ^actor.Actor(bifrost.UI_Coordinator_State, bifrost.UI_Msg)
	defer {
		actor.scheduler_wait_idle(&sched)
		ui_state: bifrost.UI_Coordinator_State
		has_ui := ui_actor != nil
		if has_ui {
			ui_state = ui_actor.state
			ui_actor.state = {}
		}
		actor.scheduler_stop_and_destroy(&sched)
		if has_ui {
			bifrost.ui_coordinator_destroy(&ui_state)
		}
	}

	cols := 116
	rows := 28
	term: bifrost.Terminal
	if live_tty {
		if bifrost.terminal_init(&term) != .None {
			return false
		}
		if ws, ws_err := bifrost.terminal_get_winsize(term.out_fd); ws_err == .None {
			cols = max(60, int(ws.width))
			rows = max(16, int(ws.height))
		}
	}
	defer if live_tty {
		bifrost.terminal_deinit(&term)
	}

	ui_ok: bool
	ui_actor, ui_ok = bifrost.spawn_ui_coordinator(
		&sched,
		cols,
		rows,
		&shared,
		render_heimdall_inspector_pass,
		context.allocator,
	)
	if !ui_ok {
		return false
	}
	ui_actor.state.user_ptr = &app
	ui_actor.state.primary_list_id = "records_pane"
	ui_actor.state.input.wants_focus_id = bifrost.hash_id("records_pane")
	bifrost.ui_coordinator_set_recorder(&ui_actor.state, &rec)
	_ = bifrost.register_actions_struct(&ui_actor.state.input, &ui_actor.state.palette, Heimdall_Inspector_Actions{})
	ui_pid := actor.pid(ui_actor)

	_ = bifrost.on_ui_action(&ui_actor.state, "heimdall.reload",        on_action_reload,       &app)
	_ = bifrost.on_ui_action(&ui_actor.state, "heimdall.cycle_kind",    on_action_cycle_kind,   &app)
	_ = bifrost.on_ui_action(&ui_actor.state, "heimdall.cycle_scope",   on_action_cycle_scope,  &app)
	_ = bifrost.on_ui_action(&ui_actor.state, "heimdall.tab_records",   on_action_switch_tab,   &app)
	_ = bifrost.on_ui_action(&ui_actor.state, "heimdall.tab_waterfall", on_action_switch_tab,   &app)
	_ = bifrost.on_ui_action(&ui_actor.state, "heimdall.tab_scopes",    on_action_switch_tab,   &app)
	_ = bifrost.on_ui_action(&ui_actor.state, "heimdall.inject_burst",  on_action_inject_burst, &app)

	worker_actor, w_err := actor.spawn(
		&sched,
		bifrost.Xitdb_Worker_State{
			shared   = &shared,
			ui_pid   = ui_pid,
			recorder = &rec,
		},
		bifrost.xitdb_worker_receive,
		2,
		context.allocator,
	)
	if w_err != nil {
		return false
	}
	worker_pid := actor.pid(worker_actor)

	actor.scheduler_start(&sched)

	// Seed workload so Heimdall captures actor turns, xitdb commits, Datalog queries, diffs, and UI frames
	actor.send(&sched, worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Commit_Batch{
		map_name   = "$services",
		key_prefix = "svc",
		start_id   = 1,
		count      = 25,
		sorted     = true,
		tag_name   = "v1",
	}))
	actor.send(&sched, worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Commit_Batch{
		map_name   = "$services",
		key_prefix = "svc",
		start_id   = 26,
		count      = 25,
		sorted     = true,
		tag_name   = "v2",
	}))
	actor.send(&sched, worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Run_Datalog{
		query_source = "find ?k, ?v where $services[?k] = ?v",
	}))
	actor.send(&sched, worker_pid, bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Diff_Moments{
		moment_a = 0,
		moment_b = 1,
	}))
	actor.scheduler_wait_idle(&sched)
	inject_synthetic_telemetry_burst(&app)

	if live_tty {
		refresh_inspector_store(&app)
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 1}))
		actor.scheduler_wait_idle(&sched)
		if ui_actor.state.last_ansi_bytes > 0 {
			_, _ = os.write_string(os.stdout, strings.to_string(ui_actor.state.ansi_builder))
		}

		boot_tick  := time.tick_now()
		last_tick  := boot_tick
		last_pulse := boot_tick
		target_frame_interval := 33 * time.Millisecond  // 30 FPS cap
		heartbeat_interval    := 500 * time.Millisecond // 2 Hz idle heartbeat so FPS/CPU/RSS HUD stays live when idle
		queued_inputs         := make([dynamic]bifrost.Input_Event, 0, 64, context.allocator)
		defer delete(queued_inputs)
		for !ui_actor.state.quit_requested {
			elapsed_since_frame := time.tick_diff(last_tick, time.tick_now())
			wait_ms := max(i32(1), i32((target_frame_interval - elapsed_since_frame) / time.Millisecond))
			ev, has_ev, _ := bifrost.poll_next_event(&term, wait_ms)
			if has_ev {
				append(&queued_inputs, ev)
				for drain := 0; drain < 128; drain += 1 {
					ev2, has_ev2, _ := bifrost.poll_next_event(&term, 0)
					if !has_ev2 {
						break
					}
					if m2, is_m2 := ev2.(bifrost.Mouse_Event); is_m2 && (m2.action == .Move || m2.action == .Drag) && len(queued_inputs) > 0 {
						if m1, is_m1 := queued_inputs[len(queued_inputs) - 1].(bifrost.Mouse_Event); is_m1 && m1.action == m2.action {
							queued_inputs[len(queued_inputs) - 1] = ev2
							continue
						}
					}
					append(&queued_inputs, ev2)
				}
			}
			now := time.tick_now()
			is_heartbeat := time.tick_diff(last_pulse, now) >= heartbeat_interval
			if is_heartbeat {
				last_pulse = now
				ui_actor.state.dirty = true
			}
			if time.tick_diff(last_tick, now) >= target_frame_interval || app.pending_reload || is_heartbeat {
				last_tick = now
				for q_ev in queued_inputs {
					actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Input{event = q_ev}))
				}
				clear(&queued_inputs)
				actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{
					tick_ns = max(1, i64(time.tick_diff(boot_tick, now))),
				}))
				actor.scheduler_wait_idle(&sched)
				if app.pending_reload {
					app.pending_reload = false
					refresh_inspector_store(&app)
					ui_actor.state.dirty = true
					actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{
						tick_ns = max(1, i64(time.tick_since(boot_tick))),
					}))
					actor.scheduler_wait_idle(&sched)
				}
				if ui_actor.state.last_ansi_bytes > 0 {
					_, _ = os.write_string(os.stdout, strings.to_string(ui_actor.state.ansi_builder))
				}
			}
			free_all(context.temp_allocator)
		}
	} else {
		// Headless verification:
		// 1. Render Frame 1 so UI Coordinator + Layout + Input + Renderer emit spans & metrics
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 1}))
		actor.scheduler_wait_idle(&sched)

		// 2. Press 'r' to reload segments, then complete the deferred post-turn flush so Frame 1's
		//    closed `actor_turn` and `flush_frame` spans are also captured in `.arrow` segments
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = 'r'}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 2}))
		actor.scheduler_wait_idle(&sched)
		if app.pending_reload {
			app.pending_reload = false
			refresh_inspector_store(&app)
		}

		// 3. Press 'k' to filter to SPANS only, then render Frame 3 (Tab 1: Arrow IPC Records)
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = 'k'}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 3}))
		actor.scheduler_wait_idle(&sched)

		header_line := extract_row_text(&ui_actor.state, 0)
		footer_line := extract_row_text(&ui_actor.state, rows - 2)
		fmt.printf(
			"[Bifrost x Heimdall Inspector — Tab 1 (Records)] segments=%d total_records=%d filtered_spans=%d scopes=%d frames=%d\n",
			app.store.segment_count,
			len(app.store.records),
			len(app.store.filtered_idxs),
			len(app.store.scope_stats),
			ui_actor.state.total_frames,
		)
		fmt.printf("  Header: %s\n", header_line)
		fmt.printf("  Footer: %s\n", footer_line)
		for r := 0; r < ui_actor.state.rows; r += 1 {
			fmt.printf("  %s\n", extract_row_text(&ui_actor.state, r))
		}

		// 4. Switch to Tab 2 (`2` -> Span Call-Tree & Latency Waterfall) and render Frame 4
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = '2'}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 4}))
		actor.scheduler_wait_idle(&sched)

		fmt.printf(
			"\n[Bifrost x Heimdall Inspector — Tab 2 (Span Call-Tree & Waterfall)] tree_spans=%d max_dur_us=%d\n",
			len(app.store.span_tree_items),
			app.store.max_duration_ns / 1000,
		)
		for r := 0; r < ui_actor.state.rows; r += 1 {
			fmt.printf("  %s\n", extract_row_text(&ui_actor.state, r))
		}

		// 5. Switch to Tab 3 (`3` -> Scope Latency Breakdown) and render Frame 5
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = '3'}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 5}))
		actor.scheduler_wait_idle(&sched)

		fmt.printf(
			"\n[Bifrost x Heimdall Inspector — Tab 3 (Scope Latency Breakdown)] scopes=%d\n",
			len(app.store.scope_stats),
		)
		for r := 0; r < ui_actor.state.rows; r += 1 {
			fmt.printf("  %s\n", extract_row_text(&ui_actor.state, r))
		}

		if app.store.segment_count < 1 || len(app.store.records) < 10 || len(app.store.filtered_idxs) < 5 {
			return false
		}
	}

	return true
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	live_tty := false
	for arg in os.args[1:] {
		if arg == "--live-tty" {
			live_tty = true
		}
	}

	ok := run_heimdall_inspector(live_tty, &track)

	leaks := 0
	for _, entry in track.allocation_map {
		fmt.eprintf("LEAK: %v bytes allocated at %v\n", entry.size, entry.location)
		leaks += 1
	}
	for entry in track.bad_free_array {
		fmt.eprintf("BAD FREE: %p at %v\n", entry.memory, entry.location)
		leaks += 1
	}
	mem.tracking_allocator_destroy(&track)

	if !ok || leaks > 0 {
		os.exit(1)
	}
}
