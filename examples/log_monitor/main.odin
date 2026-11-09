package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "../../bifrost"
import heimdall "../../deps/heimdall/heimdall"
import actor "../../deps/heimdall/deps/sleipnir/actor"
import xitdb "../../deps/xitdb/xitdb"

Service_Info :: struct {
	name:   string,
	rps:    int,
	p99_ms: int,
	status: string,
}

@(rodata)
SERVICES := [4]Service_Info{
	{name = "api-gateway", rps = 4820, p99_ms = 4,  status = "HEALTHY"},
	{name = "auth-rebac",  rps = 3190, p99_ms = 7,  status = "HEALTHY"},
	{name = "xitdb-store", rps = 8450, p99_ms = 2,  status = "OPTIMAL"},
	{name = "actor-pool",  rps = 12600, p99_ms = 1, status = "HEALTHY"},
}

@(rodata)
LOG_LEVELS := [4]string{
	"INFO",
	"INFO",
	"WARN",
	"ERROR",
}

@(rodata)
LOG_MESSAGES := [8]string{
	"accepted TLS 1.3 session and routed RPC batch",
	"evaluated Zanzibar ReBAC check in 180us",
	"committed B+Tree copy-on-write root slot",
	"drained Vyukov MPSC mailbox burst (coalesced)",
	"high tail latency detected on shard replica #2",
	"retrying transient peer heartbeat timeout",
	"completed Datalog fixed-point join evaluation",
	"checkpointed immutable moment snapshot",
}

// =============================================================================
// Declarative Monitor Actions (Merged onto Built-In `UI_Inspector_Actions`)
// =============================================================================

Log_Monitor_Action :: enum u8 {
	None = 0,
	Filter_All,
	Filter_Warn,
	Filter_Error,
	Stream_Burst,
	Tab_Logs,
	Tab_Heimdall,
	Heimdall_Flush,
	Heimdall_Kind_Cycle,
	Heimdall_Scope_Cycle,
}

Log_Monitor_Actions :: struct {
	filter_all:    Log_Monitor_Action `bifrost:"action=filter.all,chord=1,policy=root,group=lvl_filter,group_desc=Level Filter,category=Filter,label=Show All Structured Logs,desc=All Logs"`,
	filter_warn:   Log_Monitor_Action `bifrost:"action=filter.warn,chord=2,policy=root,group=lvl_filter,group_desc=Level Filter,category=Filter,label=Filter WARN Logs Only,desc=WARN Only"`,
	filter_error:  Log_Monitor_Action `bifrost:"action=filter.error,chord=3,policy=root,group=lvl_filter,group_desc=Level Filter,category=Filter,label=Filter ERROR Logs Only,desc=ERROR Only"`,
	stream_burst:  Log_Monitor_Action `bifrost:"action=stream.burst,chord=<C-b>,policy=root,allow_in_edit=true,category=Stream,label=Inject 20 Live Log Events,desc=Burst +20"`,
	tab_logs:      Log_Monitor_Action `bifrost:"action=tab.logs,chord=<M-1>,policy=global,allow_in_edit=true,category=View,label=Switch to Structured Log Stream Tab,desc=Logs (Alt+1)"`,
	tab_heimdall:  Log_Monitor_Action `bifrost:"action=tab.heimdall,chord=4|<M-2>,policy=global,allow_in_edit=true,category=View,label=Toggle Heimdall IPC Viewer Tab,desc=Heimdall (4)"`,
	hd_flush:      Log_Monitor_Action `bifrost:"action=heimdall.flush,chord=<C-r>,policy=global,allow_in_edit=true,category=Telemetry,label=Flush & Reload Heimdall .arrow Segments,desc=Flush IPC (^R)"`,
	hd_kind:       Log_Monitor_Action `bifrost:"action=heimdall.kind,chord=<C-k>,policy=global,allow_in_edit=true,category=Telemetry,label=Cycle Heimdall Kind Filter,desc=Kind (^K)"`,
	hd_scope:      Log_Monitor_Action `bifrost:"action=heimdall.scope,chord=s,policy=root,category=Telemetry,label=Cycle Heimdall Scope Filter,desc=Scope (s)"`,
}

MONITOR_HEIMDALL_DIR    :: ".tmp/log_monitor_heimdall"
MONITOR_HEIMDALL_PREFIX :: ".tmp/log_monitor_heimdall/seg"

Monitor_Telemetry_Ctx :: struct {
	recorder:    heimdall.Recorder,
	store:       bifrost.Heimdall_Segment_Store,
	perf:        bifrost.Heimdall_Runtime_Metrics,
	filter_kind: bifrost.Heimdall_Filter_Kind,
	scope_buf:   [64]u8,
	scope_len:   int,
}

active_monitor_scope_filter :: proc(tctx: ^Monitor_Telemetry_Ctx) -> string {
	if tctx == nil || tctx.scope_len <= 0 {
		return ""
	}
	return string(tctx.scope_buf[:tctx.scope_len])
}

set_monitor_scope_filter :: proc(tctx: ^Monitor_Telemetry_Ctx, scope: string) {
	if tctx == nil {
		return
	}
	if len(scope) == 0 {
		tctx.scope_len = 0
		return
	}
	n := min(len(scope), len(tctx.scope_buf))
	copy(tctx.scope_buf[:n], scope[:n])
	tctx.scope_len = n
}

flush_and_reload_monitor_heimdall :: proc(tctx: ^Monitor_Telemetry_Ctx) {
	if tctx == nil {
		return
	}
	heimdall.recorder_flush(&tctx.recorder)
	_, _ = bifrost.heimdall_store_load_prefix_incremental(&tctx.store, MONITOR_HEIMDALL_PREFIX)
	scope_filter := active_monitor_scope_filter(tctx)
	if len(scope_filter) > 0 {
		found := false
		for st in tctx.store.scope_stats {
			if st.scope == scope_filter {
				found = true
				break
			}
		}
		if !found {
			tctx.scope_len = 0
			scope_filter   = ""
			_ = bifrost.heimdall_store_apply_filter(&tctx.store, tctx.filter_kind, "", "")
		}
	}
}

// =============================================================================
// Background Sleipnir Log Producer Actor
// =============================================================================

Log_Batch_Request :: struct {
	start_seq: int,
	count:     int,
	tag_name:  string,
}

Log_Producer_Msg :: union {
	Log_Batch_Request,
}

Log_Producer_State :: struct {
	shared:       ^bifrost.Xitdb_Shared_Handle,
	ui_pid:       actor.PID(bifrost.UI_Msg),
	recorder:     ^heimdall.Recorder,
	batches_sent: int,
	logs_written: int,
}

Stream_Burst_Cursor :: struct {
	next_seq: int,
}

log_producer_receive :: proc(
	ctx: ^actor.Context,
	self: ^actor.Actor(Log_Producer_State, Log_Producer_Msg),
	msg: ^Log_Producer_Msg,
) {
	defer free_all(context.temp_allocator)
	state := &self.state
	if state.shared == nil || state.shared.db == nil || msg == nil {
		return
	}

	switch m in msg^ {
	case Log_Batch_Request:
		rec := bifrost.resolve_recorder(state.recorder)
		heimdall.scoped_span(rec, "bifrost.log_producer", "commit_log_batch", i64(m.count))
		sync.rw_mutex_lock(&state.shared.rw_lock)
		tx := xitdb.tx_init(state.shared.db, -1, false, context.temp_allocator)
		if len(m.tag_name) > 0 {
			xitdb.tx_doc(&tx, m.tag_name)
		}
		map_step := xitdb.hm("logs")
		for i := 0; i < m.count; i += 1 {
			seq := m.start_seq + i
			lvl := LOG_LEVELS[seq % len(LOG_LEVELS)]
			svc := SERVICES[seq % len(SERVICES)].name
			txt := LOG_MESSAGES[seq % len(LOG_MESSAGES)]

			k_str := fmt.aprintf("log:%06d", seq, allocator = context.temp_allocator)
			v_str := fmt.aprintf("%-5s | %-11s | %s", lvl, svc, txt, allocator = context.temp_allocator)
			steps := [2]xitdb.Path_Step{map_step, xitdb.sm(k_str)}
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
			state.batches_sent += 1
			state.logs_written += m.count
			heimdall.counter_add(rec, "bifrost.log_producer", "logs_written", f64(m.count))
			if state.ui_pid.ref != nil {
				actor.send(
					ctx,
					state.ui_pid,
					bifrost.UI_Msg(bifrost.UI_Msg_Commit_Notification{
						moment_idx = latest_idx,
						slot_ptr   = slot_val,
						tx_id      = latest_idx + 1,
						tag_name   = m.tag_name,
					}),
				)
			}
		}
	}
}

// =============================================================================
// Declarative Action Callbacks & Dynamic Actor Payload Builders
// =============================================================================

apply_monitor_level_filter :: proc(coord: ^bifrost.UI_Coordinator_State, action_name: string, _: rawptr) {
	switch action_name {
	case "filter.all":
		coord.filter.kind   = .None
		coord.filter.needle = ""
		coord.filter.prefix = ""
		coord.search_len    = 0
		bifrost.set_text(&coord.input, "search_box", "")
	case "filter.warn":
		coord.filter.kind   = .Substring
		coord.filter.needle = "WARN"
		coord.filter.prefix = ""
		copy(coord.search_buf[:4], "WARN")
		coord.search_len = 4
		bifrost.set_text(&coord.input, "search_box", "WARN")
	case "filter.error":
		coord.filter.kind   = .Substring
		coord.filter.needle = "ERROR"
		coord.filter.prefix = ""
		copy(coord.search_buf[:5], "ERROR")
		coord.search_len = 5
		bifrost.set_text(&coord.input, "search_box", "ERROR")
	}
}

on_monitor_tab_switch :: proc(coord: ^bifrost.UI_Coordinator_State, action_name: string, ud: rawptr) {
	tctx := (^Monitor_Telemetry_Ctx)(ud)
	switch action_name {
	case "tab.logs":
		bifrost.set_active_tab(&coord.input, "monitor_tabs", 0, true)
		coord.input.wants_focus_id = bifrost.hash_id("log_stream_pane")
	case "tab.heimdall":
		cur := bifrost.get_active_tab(&coord.input, "monitor_tabs")
		next_tab := 1 if cur == 0 else 0
		bifrost.set_active_tab(&coord.input, "monitor_tabs", next_tab, true)
		if next_tab == 1 {
			flush_and_reload_monitor_heimdall(tctx)
			coord.input.wants_focus_id = bifrost.hash_id("monitor_heimdall_pane")
		} else {
			coord.input.wants_focus_id = bifrost.hash_id("log_stream_pane")
		}
	}
	coord.dirty = true
}

on_monitor_heimdall_flush :: proc(coord: ^bifrost.UI_Coordinator_State, _: string, ud: rawptr) {
	tctx := (^Monitor_Telemetry_Ctx)(ud)
	flush_and_reload_monitor_heimdall(tctx)
	coord.dirty = true
}

on_monitor_heimdall_kind :: proc(coord: ^bifrost.UI_Coordinator_State, _: string, ud: rawptr) {
	tctx := (^Monitor_Telemetry_Ctx)(ud)
	if tctx == nil {
		return
	}
	next_ord := (int(tctx.filter_kind) + 1) % len(bifrost.Heimdall_Filter_Kind)
	tctx.filter_kind = bifrost.Heimdall_Filter_Kind(next_ord)
	_ = bifrost.heimdall_store_apply_filter(
		&tctx.store,
		tctx.filter_kind,
		active_monitor_scope_filter(tctx),
		"",
	)
	slot := bifrost.get_scroll_slot(&coord.input, bifrost.hash_id("monitor_heimdall_pane"))
	if slot != nil {
		slot.selected_row = 0
		slot.offset       = 0
	}
	coord.dirty = true
}

on_monitor_heimdall_scope :: proc(coord: ^bifrost.UI_Coordinator_State, _: string, ud: rawptr) {
	tctx := (^Monitor_Telemetry_Ctx)(ud)
	if tctx == nil {
		return
	}
	cur_scope := active_monitor_scope_filter(tctx)
	next_scope := ""
	if len(tctx.store.scope_stats) > 0 {
		if len(cur_scope) == 0 {
			next_scope = tctx.store.scope_stats[0].scope
		} else {
			for st, idx in tctx.store.scope_stats {
				if st.scope == cur_scope {
					if idx + 1 < len(tctx.store.scope_stats) {
						next_scope = tctx.store.scope_stats[idx + 1].scope
					}
					break
				}
			}
		}
	}
	set_monitor_scope_filter(tctx, next_scope)
	_ = bifrost.heimdall_store_apply_filter(
		&tctx.store,
		tctx.filter_kind,
		active_monitor_scope_filter(tctx),
		"",
	)
	slot := bifrost.get_scroll_slot(&coord.input, bifrost.hash_id("monitor_heimdall_pane"))
	if slot != nil {
		slot.selected_row = 0
		slot.offset       = 0
	}
	coord.dirty = true
}

build_monitor_diff_msg :: proc(coord: ^bifrost.UI_Coordinator_State, _: rawptr) -> (bifrost.Xitdb_Worker_Msg, bool) {
	return bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Diff_Moments{
		moment_a = coord.active_moment_idx,
		moment_b = coord.latest_moment_idx,
	}), true
}

build_stream_burst_msg :: proc(_: ^bifrost.UI_Coordinator_State, ud: rawptr) -> (Log_Producer_Msg, bool) {
	cursor := (^Stream_Burst_Cursor)(ud)
	if cursor == nil {
		return nil, false
	}
	start := cursor.next_seq
	cursor.next_seq += 20
	return Log_Producer_Msg(Log_Batch_Request{
		start_seq = start,
		count     = 20,
		tag_name  = "manual-burst",
	}), true
}

// =============================================================================
// Custom Immediate-Mode Render Pass for UI_Coordinator_State
// =============================================================================

render_log_monitor_frame :: proc(coord: ^bifrost.UI_Coordinator_State) {
	coord.use_widget_pipeline = true

	w := i32(coord.cols)
	h := i32(coord.rows)
	bg_dark  := bifrost.rgb(18, 22, 30)
	panel_bg := bifrost.rgb(24, 30, 42)
	bar_bg   := bifrost.rgb(30, 40, 58)
	text_fg  := bifrost.rgb(215, 225, 240)
	muted_fg := bifrost.rgb(135, 155, 180)
	accent   := bifrost.rgb(115, 195, 255)

	bifrost.begin_frame(&coord.screen, bg_dark)
	bifrost.begin_layout(&coord.layout_ctx, w, h)

	if bifrost.container(&coord.layout_ctx, "monitor_root", bifrost.Box_Config{
		dir         = .Column,
		width       = bifrost.fixed(w),
		height      = bifrost.fixed(h),
		focus_flags = {.Focus_Scope},
		focus_scope = true,
	}) {
		// 1. Top Header Bar
		tctx_hdr := (^Monitor_Telemetry_Ctx)(coord.user_ptr)
		if tctx_hdr != nil {
			bifrost.heimdall_sample_runtime_metrics(&tctx_hdr.perf, u64(coord.total_frames + 1))
		}
		fps_val := tctx_hdr.perf.fps if tctx_hdr != nil else 60.0
		cpu_val := tctx_hdr.perf.cpu_percent if tctx_hdr != nil else 0.0
		rss_mb  := f64(tctx_hdr.perf.rss_kb) / 1024.0 if tctx_hdr != nil else 0.0
		mode_str := "PINNED" if coord.pinned_moment else "LIVE STREAM"
		header_str := fmt.tprintf(
			" BIFROST LOG & METRICS MONITOR | %s @%d | %.0f FPS | CPU %.1f%% | RSS %.1fMB | Coalesced: %d | Frames: %d",
			mode_str,
			coord.active_moment_idx,
			fps_val,
			cpu_val,
			rss_mb,
			coord.coalesced_commits,
			coord.total_frames + 1,
		)
		bifrost.set_paint(&coord.screen, "header_bar", bifrost.Paint_Spec{
			text    = header_str,
			fg      = bifrost.rgb(255, 225, 120) if coord.pinned_moment else accent,
			bg      = bar_bg,
			style   = {.Bold},
			fill_bg = true,
		})
		bifrost.leaf(&coord.layout_ctx, "header_bar", w, 1, bifrost.Box_Config{
			width  = bifrost.grow(1),
			height = bifrost.fixed(1),
			text   = header_str,
		})

		// 2. Service Telemetry Strip (4 Grow(1) cards)
		if bifrost.container(&coord.layout_ctx, "telemetry_row", bifrost.Box_Config{
			dir    = .Row,
			width  = bifrost.grow(1),
			height = bifrost.fixed(3),
			gap    = 1,
		}) {
			for svc, idx in SERVICES {
				card_id := fmt.tprintf("svc_card_%d", idx)
				rps_val := svc.rps + int(coord.active_moment_idx) * 35
				card_txt := fmt.tprintf("%d req/s | p99:%dms", rps_val, svc.p99_ms)
				bifrost.set_paint(&coord.screen, card_id, bifrost.Paint_Spec{
					title       = fmt.tprintf("%s [%s]", svc.name, svc.status),
					text        = card_txt,
					fg          = text_fg,
					bg          = panel_bg,
					border_fg   = bifrost.rgb(80, 145, 115),
					title_fg    = bifrost.rgb(130, 230, 165),
					title_style = {.Bold},
					fill_bg     = true,
				})
				bifrost.leaf(&coord.layout_ctx, card_id, 16, 3, bifrost.Box_Config{
					width       = bifrost.grow(1),
					height      = bifrost.fixed(3),
					border      = .Rounded,
					main_align  = .Center,
					cross_align = .Center,
				})
			}
		}

		// 3. Main Split Body (Filter Sidebar + Interactive Splitter + Virtualized Log Stream)
		body_h := max(i32(6), h - 6)
		if bifrost.ui_scope(&coord.layout_ctx, &coord.screen, "monitor_body", bifrost.Scope_Config{
			dir    = .Row,
			width  = bifrost.grow(1),
			height = bifrost.fixed(body_h),
		}) {
			sidebar_w := bifrost.get_split_size(&coord.input, "monitor_split", 28, 22, max(26, w - 36))

			if bifrost.ui_scope(&coord.layout_ctx, &coord.screen, "filter_sidebar", bifrost.Scope_Config{
				dir       = .Column,
				width     = bifrost.fixed(sidebar_w),
				height    = bifrost.grow(1),
				padding   = bifrost.pad_xy(1, 0),
				gap       = 1,
				border    = .Plain,
				title     = "Stream Controls",
				fg        = text_fg,
				bg        = panel_bg,
				border_fg = bifrost.rgb(75, 95, 125),
				title_fg  = accent,
				fill_bg   = true,
			}) {
				bifrost.ui_label(&coord.layout_ctx, &coord.screen, "lbl_q", "Filter (^prefix or text):", muted_fg)
				bifrost.ui_text_input(&coord.layout_ctx, &coord.screen, &coord.input, "search_box", bifrost.Text_Input_Config{
					placeholder    = "e.g. ERROR or auth-rebac...",
					linked_list_id = "log_stream_pane",
					width          = bifrost.grow(1),
					height         = bifrost.fixed(1),
					fg             = text_fg,
					bg             = bar_bg,
					placeholder_fg = muted_fg,
				})

				bifrost.ui_button(&coord.layout_ctx, &coord.screen, "btn_lvl_all", bifrost.Button_Spec{
					label  = "Show ALL Logs (1)",
					width  = bifrost.grow(1),
					height = bifrost.fixed(1),
					fg     = text_fg,
					bg     = bar_bg,
				})
				bifrost.ui_button(&coord.layout_ctx, &coord.screen, "btn_lvl_warn", bifrost.Button_Spec{
					label  = "Filter: WARN Only (2)",
					width  = bifrost.grow(1),
					height = bifrost.fixed(1),
					fg     = bifrost.rgb(250, 200, 95),
					bg     = bar_bg,
				})
				bifrost.ui_button(&coord.layout_ctx, &coord.screen, "btn_lvl_err", bifrost.Button_Spec{
					label  = "Filter: ERROR Only (3)",
					width  = bifrost.grow(1),
					height = bifrost.fixed(1),
					fg     = bifrost.rgb(250, 115, 120),
					bg     = bar_bg,
				})
				bifrost.ui_button(&coord.layout_ctx, &coord.screen, "btn_pin_toggle", bifrost.Button_Spec{
					label  = "Follow Live Head (f)",
					width  = bifrost.grow(1),
					height = bifrost.fixed(1),
					fg     = bifrost.rgb(130, 230, 165),
					bg     = bar_bg,
				})

				// Track 14: Live Vertical Block Sparkline (`▁▂▃▄▅▆▇█`) + Unicode Braille Telemetry Canvas (`U+2800..U+28FF`)
				m_off := int(coord.active_moment_idx)
				rps_samples := [16]int{
					320 + m_off * 20, 380 + m_off * 20, 440 + m_off * 20, 510 + m_off * 20,
					490 + m_off * 20, 620 + m_off * 20, 710 + m_off * 20, 680 + m_off * 20,
					790 + m_off * 20, 860 + m_off * 20, 810 + m_off * 20, 920 + m_off * 20,
					880 + m_off * 20, 960 + m_off * 20, 910 + m_off * 20, 990 + m_off * 20,
				}
				bifrost.ui_sparkline(&coord.layout_ctx, &coord.screen, "sidebar_sparkline", rps_samples[:], bifrost.Sparkline_Config{
					width  = bifrost.grow(1),
					height = bifrost.fixed(1),
					fg     = bifrost.rgb(130, 230, 165),
					bg     = bar_bg,
				})

				bifrost.ui_canvas(&coord.layout_ctx, &coord.screen, "sidebar_braille_chart", bifrost.Canvas_Config{
					title     = "Braille p99",
					width     = bifrost.grow(1),
					height    = bifrost.fixed(4),
					border    = .Rounded,
					fg        = accent,
					bg        = bar_bg,
					border_fg = bifrost.rgb(75, 95, 125),
					title_fg  = accent,
					draw_fn   = proc(c: ^bifrost.Braille_Canvas, _: rawptr) {
						p99_series := [8]f32{2.1, 3.4, 2.8, 5.2, 4.1, 6.8, 3.9, 2.4}
						bifrost.canvas_draw_series(c, p99_series[:], 1.0, 8.0, bifrost.rgb(115, 195, 255))
					},
				})
			}

			bifrost.ui_splitter(&coord.layout_ctx, &coord.screen, &coord.input, "monitor_split", bifrost.Splitter_Config{
				dir          = .Row,
				default_size = 28,
				min_first    = 22,
				min_second   = 30,
				fg           = muted_fg,
				bg           = bg_dark,
				active_fg    = accent,
			})

			// Right Pane: Focus-Scope-Integrated Tab Bar (`ui_tabs`) switching between:
			//   - Tab 1 (`Alt+1`): Zero-Copy xitdb Structured Log Stream
			//   - Tab 2 (`Alt+2`): Heimdall Arrow IPC Telemetry Viewer
			tctx := (^Monitor_Telemetry_Ctx)(coord.user_ptr)
			if bifrost.was_tab_changed(&coord.input, "monitor_tabs") {
				if bifrost.get_active_tab(&coord.input, "monitor_tabs") == 1 {
					flush_and_reload_monitor_heimdall(tctx)
				}
			}

			tab_specs := [2]bifrost.Tab_Item_Spec{
				{label = "Structured Log Stream", badge = "XITDB", key_hint = "1:"},
				{label = "Heimdall IPC Viewer",   badge = "ARROW", key_hint = "2:"},
			}

			cur_tab := 0
			if bifrost.ui_tabs(
				&coord.layout_ctx,
				&coord.screen,
				&coord.input,
				"monitor_tabs",
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
					active_fg        = bifrost.rgb(255, 240, 150),
					active_bg        = bifrost.rgb(42, 56, 82),
					inactive_fg      = muted_fg,
					inactive_bg      = bar_bg,
					badge_fg         = accent,
					sep_fg           = bifrost.rgb(75, 95, 125),
					show_index_hints = true,
				},
				&cur_tab,
			) {
				switch cur_tab {
				case 0:
					// Zero-Copy xitdb Structured Log Stream Table
					visible_rows := max(1, int(body_h) - 5)
					slice := bifrost.ui_coordinator_slice_viewport(coord, "log_stream_pane", visible_rows)

					log_cols := [4]bifrost.Table_Column_Spec{
						0 = {header = "Key",     kind = .Fixed,        value = 10, min_width = 10, max_width = 12, align = .Left},
						1 = {header = "Level",   kind = .Fixed,        value = 5,  min_width = 5,  max_width = 6,  align = .Left},
						2 = {header = "Service", kind = .Auto_Content,             min_width = 11, max_width = 14, align = .Left},
						3 = {header = "Message", kind = .Fill,         value = 2,  min_width = 16,                 align = .Left},
					}

					vslice: bifrost.Virtual_Slice
					if bifrost.ui_table(
						&coord.layout_ctx,
						&coord.screen,
						&coord.input,
						"log_stream_pane",
						log_cols[:],
						i32(slice.total_rows),
						bifrost.Table_Config{
							title         = fmt.tprintf("Structured Log Stream (%d total in %s, showing %d)", slice.total_rows, coord.active_collection, len(slice.rows)),
							width         = bifrost.grow(1),
							height        = bifrost.grow(1),
							border        = .Plain,
							fg            = text_fg,
							bg            = panel_bg,
							border_fg     = bifrost.rgb(75, 95, 125),
							title_fg      = accent,
							header_fg     = accent,
							header_bg     = bar_bg,
							sep_fg        = bifrost.rgb(75, 95, 125),
							sel_fg        = bifrost.rgb(255, 240, 150),
							sel_bg        = bifrost.rgb(42, 56, 82),
							fallback_rows = i32(visible_rows),
							focus_flags   = {.Focusable, .Default_Focus},
						},
						&vslice,
					) {
						for row_i in 0 ..< len(slice.rows) {
							rv := slice.rows[row_i]
							lvl_txt := "INFO"
							svc_txt := ""
							msg_txt := rv.val_text
							if p1 := strings.index(rv.val_text, " | "); p1 >= 0 {
								lvl_txt = strings.trim_space(rv.val_text[:p1])
								rest    := rv.val_text[p1 + 3:]
								if p2 := strings.index(rest, " | "); p2 >= 0 {
									svc_txt = strings.trim_space(rest[:p2])
									msg_txt = strings.trim_space(rest[p2 + 3:])
								} else {
									msg_txt = strings.trim_space(rest)
								}
							}

							lvl_fg := bifrost.rgb(130, 230, 165)
							row_fg := text_fg
							if lvl_txt == "ERROR" {
								lvl_fg = bifrost.rgb(255, 120, 125)
								row_fg = bifrost.rgb(255, 120, 125)
							} else if lvl_txt == "WARN" {
								lvl_fg = bifrost.rgb(250, 205, 100)
								row_fg = bifrost.rgb(250, 205, 100)
							}

							cells := [4]bifrost.Table_Cell{
								0 = {text = rv.key_text, fg = accent},
								1 = {text = lvl_txt,     fg = lvl_fg, style = {.Bold}},
								2 = {text = svc_txt,     fg = bifrost.rgb(185, 205, 235)},
								3 = {text = msg_txt,     fg = row_fg},
							}
							bifrost.ui_table_row(&coord.layout_ctx, &coord.screen, i32(rv.view_index), cells[:], fg = row_fg)
						}
					}

				case 1:
					// Heimdall Arrow IPC Telemetry Viewer
					if tctx != nil {
						rec_stats := bifrost.heimdall_snapshot_recorder_stats(&tctx.recorder)
						scope_lbl := active_monitor_scope_filter(tctx)
						if len(scope_lbl) == 0 {
							scope_lbl = "ALL SCOPES"
						}
						hd_summary := fmt.tprintf(
							" Segs: %d | Records: %d/%d | Spans: %d | Cnt: %d | Gauges: %d | Hists: %d | Drop: %d | Kind: %s (^K) | Scope: %s (s) | Flush (^R)",
							tctx.store.segment_count,
							len(tctx.store.filtered_idxs),
							len(tctx.store.records),
							tctx.store.total_spans,
							tctx.store.total_counters,
							tctx.store.total_gauges,
							tctx.store.total_hists,
							rec_stats.dropped_records,
							bifrost.heimdall_filter_kind_label(tctx.filter_kind),
							scope_lbl,
						)
						bifrost.set_paint(&coord.screen, "monitor_hd_summary", bifrost.Paint_Spec{
							text    = hd_summary,
							fg      = accent,
							bg      = bar_bg,
							style   = {.Bold},
							fill_bg = true,
						})
						bifrost.leaf(&coord.layout_ctx, "monitor_hd_summary", 24, 1, bifrost.Box_Config{
							width  = bifrost.grow(1),
							height = bifrost.fixed(1),
						})

						span_durs := bifrost.heimdall_store_extract_span_durations_us(&tctx.store, 32)
						bifrost.ui_sparkline(&coord.layout_ctx, &coord.screen, "monitor_hd_spark", span_durs, bifrost.Sparkline_Config{
							title     = fmt.tprintf("Span Durations us (max %d us)", tctx.store.max_duration_ns / 1_000),
							width     = bifrost.grow(1),
							height    = bifrost.fixed(3),
							border    = .Plain,
							fg        = bifrost.rgb(130, 230, 165),
							bg        = bg_dark,
							border_fg = bifrost.rgb(75, 95, 125),
							title_fg  = accent,
							fill_bg   = true,
						})

						hd_vslice: bifrost.Virtual_Slice
						total_hd := i32(len(tctx.store.filtered_idxs))
						hd_rows  := max(i32(4), body_h - 9)
						hd_cols  := bifrost.heimdall_table_columns(context.temp_allocator)
						if bifrost.ui_table(
							&coord.layout_ctx,
							&coord.screen,
							&coord.input,
							"monitor_heimdall_pane",
							hd_cols,
							total_hd,
							bifrost.Table_Config{
								title         = fmt.tprintf("Heimdall Zero-Copy Arrow IPC Records (%d matching)", total_hd),
								width         = bifrost.grow(1),
								height        = bifrost.grow(1),
								border        = .Plain,
								fg            = text_fg,
								bg            = panel_bg,
								border_fg     = bifrost.rgb(75, 95, 125),
								title_fg      = accent,
								header_fg     = accent,
								header_bg     = bar_bg,
								sep_fg        = bifrost.rgb(75, 95, 125),
								sel_fg        = bifrost.rgb(255, 240, 150),
								sel_bg        = bifrost.rgb(42, 56, 82),
								fallback_rows = hd_rows,
								focus_flags   = {.Focusable, .Default_Focus},
							},
							&hd_vslice,
						) {
							for row_idx := hd_vslice.start_row; row_idx < hd_vslice.end_row; row_idx += 1 {
								rec, rec_ok := bifrost.heimdall_store_get_filtered_record(&tctx.store, int(row_idx))
								if !rec_ok {
									continue
								}
								cells := bifrost.heimdall_record_table_cells(rec, context.temp_allocator)
								bifrost.ui_table_row(&coord.layout_ctx, &coord.screen, row_idx, cells[:])
							}
						}
					}
				}
			}
		}

		// 4. Worker Telemetry Row (Datalog Audit + Moment Diff) + Live Contextual Key-Hint Bar
		footer_str := fmt.tprintf(
			" Datalog: %s | Diff(@%d->@%d): +%d ~%d -%d",
			coord.last_datalog_summary if len(coord.last_datalog_summary) > 0 else "ready",
			coord.last_diff_summary.from_moment,
			coord.last_diff_summary.to_moment,
			coord.last_diff_summary.added,
			coord.last_diff_summary.modified,
			coord.last_diff_summary.removed,
		)
		bifrost.set_paint(&coord.screen, "footer_bar", bifrost.Paint_Spec{
			text    = footer_str,
			fg      = muted_fg,
			bg      = bar_bg,
			fill_bg = true,
		})
		bifrost.leaf(&coord.layout_ctx, "footer_bar", w, 1, bifrost.Box_Config{
			width  = bifrost.grow(1),
			height = bifrost.fixed(1),
			text   = footer_str,
		})

		bifrost.ui_key_hint_bar(&coord.layout_ctx, &coord.screen, &coord.input, "monitor_hint_bar", bifrost.Key_Hint_Bar_Config{
			bg = bifrost.rgb(22, 28, 40),
		})
	}

	// 5. Optional Command Palette (`z_layer = 30`)
	coord.palette.is_open = coord.palette_open
	if coord.palette.is_open {
		bifrost.ui_command_palette(&coord.layout_ctx, &coord.screen, &coord.input, &coord.palette, 56, 6)
	}

	bifrost.end_layout(&coord.layout_ctx)
}

extract_monitor_row :: proc(coord: ^bifrost.UI_Coordinator_State, row: int, alloc := context.temp_allocator) -> string {
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

run_log_monitor :: proc(live_tty: bool) -> bool {
	defer free_all(context.temp_allocator)

	core := xitdb.core_memory_init(context.allocator)
	defer _ = xitdb.core_destroy(&core)

	db, db_err := xitdb.database_init(&core)
	if db_err != nil {
		fmt.eprintf("Failed to initialize xitdb database: %v\n", db_err)
		return false
	}

	shared := bifrost.Xitdb_Shared_Handle{db = &db}

	_ = os.remove_all(MONITOR_HEIMDALL_DIR)
	_ = os.make_directory_all(MONITOR_HEIMDALL_DIR)
	tctx: Monitor_Telemetry_Ctx
	if heimdall.recorder_init(&tctx.recorder, heimdall.Config{
		file_prefix      = MONITOR_HEIMDALL_PREFIX,
		batches_per_file = 8,
		ring_page_count  = 4,
	}, context.allocator) != nil {
		fmt.eprintln("Failed to initialize Heimdall recorder")
		return false
	}
	defer {
		bifrost.heimdall_store_destroy(&tctx.store)
		heimdall.recorder_destroy(&tctx.recorder)
		_ = os.remove_all(MONITOR_HEIMDALL_DIR)
	}
	if bifrost.heimdall_store_init(&tctx.store, context.allocator) != nil {
		fmt.eprintln("Failed to initialize Heimdall segment store")
		return false
	}

	sched: actor.Scheduler
	if actor.scheduler_init(&sched, actor.Scheduler_Config{
		num_workers    = 2,
		num_shards     = 2,
		batch_quota    = 2048,
		enable_parking = true,
	}, context.allocator) != nil {
		fmt.eprintln("Failed to initialize sleipnir scheduler")
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

	cols := 104
	rows := 24
	term: bifrost.Terminal
	if live_tty {
		if bifrost.terminal_init(&term) != .None {
			fmt.eprintln("Failed to initialize raw terminal")
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
		render_log_monitor_frame,
		context.allocator,
	)
	if !ui_ok {
		return false
	}
	bifrost.ui_coordinator_set_recorder(&ui_actor.state, &tctx.recorder)
	ui_actor.state.user_ptr          = &tctx
	ui_actor.state.active_collection = "$logs"
	ui_actor.state.primary_list_id   = "log_stream_pane"
	ui_actor.state.input.wants_focus_id = bifrost.hash_id("log_stream_pane")
	_ = bifrost.register_actions_struct(&ui_actor.state.input, &ui_actor.state.palette, Log_Monitor_Actions{})
	ui_pid := actor.pid(ui_actor)

	// Spawn xitdb analytics worker actor (Datalog & Moment Diffs)
	worker_actor, w_err := actor.spawn(
		&sched,
		bifrost.Xitdb_Worker_State{shared = &shared, ui_pid = ui_pid, recorder = &tctx.recorder},
		bifrost.xitdb_worker_receive,
		2,
		context.allocator,
	)
	if w_err != nil {
		return false
	}
	worker_pid := actor.pid(worker_actor)

	// Spawn Sleipnir Log Producer actor
	producer_actor, p_err := actor.spawn(
		&sched,
		Log_Producer_State{shared = &shared, ui_pid = ui_pid, recorder = &tctx.recorder},
		log_producer_receive,
		2,
		context.allocator,
	)
	if p_err != nil {
		return false
	}
	producer_pid := actor.pid(producer_actor)

	burst_cursor := Stream_Burst_Cursor{next_seq = 1001}

	// Declaratively wire widget activations, local filter callbacks, and Sleipnir worker/producer sinks
	_ = bifrost.bind_button_action(&ui_actor.state, "btn_lvl_all",    "filter.all")
	_ = bifrost.bind_button_action(&ui_actor.state, "btn_lvl_warn",   "filter.warn")
	_ = bifrost.bind_button_action(&ui_actor.state, "btn_lvl_err",    "filter.error")
	_ = bifrost.bind_button_action(&ui_actor.state, "btn_pin_toggle", "moment.follow")

	_ = bifrost.on_ui_action(&ui_actor.state, "filter.all",     apply_monitor_level_filter)
	_ = bifrost.on_ui_action(&ui_actor.state, "filter.warn",    apply_monitor_level_filter)
	_ = bifrost.on_ui_action(&ui_actor.state, "filter.error",   apply_monitor_level_filter)
	_ = bifrost.on_ui_action(&ui_actor.state, "tab.logs",       on_monitor_tab_switch,     &tctx)
	_ = bifrost.on_ui_action(&ui_actor.state, "tab.heimdall",   on_monitor_tab_switch,     &tctx)
	_ = bifrost.on_ui_action(&ui_actor.state, "heimdall.flush", on_monitor_heimdall_flush, &tctx)
	_ = bifrost.on_ui_action(&ui_actor.state, "heimdall.kind",  on_monitor_heimdall_kind,  &tctx)
	_ = bifrost.on_ui_action(&ui_actor.state, "heimdall.scope", on_monitor_heimdall_scope, &tctx)

	_ = bifrost.bind_actor_action(
		&ui_actor.state,
		"query.datalog",
		worker_pid,
		bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Run_Datalog{
			query_source = "find ?k, ?v where $logs[?k] = ?v",
		}),
	)
	_ = bifrost.bind_actor_action(&ui_actor.state, "query.diff", worker_pid, build_monitor_diff_msg)
	_ = bifrost.bind_actor_action(&ui_actor.state, "stream.burst", producer_pid, build_stream_burst_msg, &burst_cursor)

	actor.scheduler_start(&sched)

	// Seed 3 streaming batches of structured logs via background producer actor
	actor.send(&sched, producer_pid, Log_Producer_Msg(Log_Batch_Request{
		start_seq = 1,
		count     = 40,
		tag_name  = "boot-stream",
	}))
	actor.send(&sched, producer_pid, Log_Producer_Msg(Log_Batch_Request{
		start_seq = 41,
		count     = 40,
		tag_name  = "steady-stream",
	}))
	actor.send(&sched, producer_pid, Log_Producer_Msg(Log_Batch_Request{
		start_seq = 81,
		count     = 40,
		tag_name  = "spike-stream",
	}))
	actor.scheduler_wait_idle(&sched)

	if live_tty {
		_ = bifrost.load_ui_workspace_from_xitdb(&shared, &ui_actor.state, "monitor_default")
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 1}))
		actor.scheduler_wait_idle(&sched)
		if ui_actor.state.last_ansi_bytes > 0 {
			_, _ = os.write_string(os.stdout, strings.to_string(ui_actor.state.ansi_builder))
		}

		next_seq := 121
		frame_counter := 0
		boot_tick := time.tick_now()
		last_tick := boot_tick
		target_frame_interval := 33 * time.Millisecond // 30 FPS cap
		queued_inputs         := make([dynamic]bifrost.Input_Event, 0, 64, context.allocator)
		defer delete(queued_inputs)
		for !ui_actor.state.quit_requested {
			elapsed_since_frame := time.tick_diff(last_tick, time.tick_now())
			wait_ms := max(i32(1), i32((target_frame_interval - elapsed_since_frame) / time.Millisecond))
			ev, has_ev, _ := bifrost.poll_next_event(&term, wait_ms)
			if has_ev {
				_ = bifrost.append_or_coalesce_input_event(&queued_inputs, ev, &ui_actor.state.input)
				for drain := 0; drain < 128; drain += 1 {
					ev2, has_ev2, _ := bifrost.poll_next_event(&term, 0)
					if !has_ev2 {
						break
					}
					_ = bifrost.append_or_coalesce_input_event(&queued_inputs, ev2, &ui_actor.state.input)
				}
			}

			now := time.tick_now()
			if time.tick_diff(last_tick, now) >= target_frame_interval {
				last_tick = now
				// Periodically stream new log batches in the background every ~30 ticks (~1s at 30 FPS)
				frame_counter += 1
				if frame_counter % 15 == 0 {
					// 2 Hz HUD heartbeat so FPS / CPU / RSS in the header stay live between log batches
					ui_actor.state.dirty        = true
					ui_actor.state.layout_dirty = true
				}
				if frame_counter % 30 == 0 {
					actor.send(&sched, producer_pid, Log_Producer_Msg(Log_Batch_Request{
						start_seq = next_seq,
						count     = 10,
						tag_name  = "live-tick",
					}))
					next_seq += 10
				}

				if len(queued_inputs) > 0 || ui_actor.state.dirty || ui_actor.state.input.pending_chord.active || frame_counter % 30 == 0 {
					bifrost.ui_send_inputs_and_tick(
						&sched,
						ui_pid,
						queued_inputs[:],
						max(1, i64(time.tick_since(boot_tick))),
						context.temp_allocator,
					)
					clear(&queued_inputs)
					actor.scheduler_wait_idle(&sched)
					if ui_actor.state.last_ansi_bytes > 0 {
						_, _ = os.write_string(os.stdout, strings.to_string(ui_actor.state.ansi_builder))
					}
					free_all(context.temp_allocator)
				}
			}
		}
		_ = bifrost.save_ui_workspace_to_xitdb(&shared, &ui_actor.state, "monitor_default")
	} else {
		// Deterministic headless verification workflow:
		// 1. Render initial seeded log stream (120 logs across 3 moments)
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 1}))
		actor.scheduler_wait_idle(&sched)

		// 2. Step back to @0 (`[` twice) and trigger `<C-g>` (`query.diff`) + `<C-d>` (`query.datalog`) + `f` (`moment.follow`)
		//    through declarative `bind_actor_action` routing onto `worker_pid`
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = '['}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = '['}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = 'g', ctrl = true}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = 'd', ctrl = true}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = 'f'}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 2}))
		actor.scheduler_wait_idle(&sched)

		// 3. Scroll down 4 rows and simulate a 500-message commit burst to verify mailbox coalescing
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Scroll_Viewport{delta_rows = 4}))
		for i := 0; i < 500; i += 1 {
			actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Commit_Notification{
				moment_idx = 2,
				slot_ptr   = 512,
				tx_id      = i64(100 + i),
				tag_name   = "burst",
			}))
		}
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 3}))
		actor.scheduler_wait_idle(&sched)

		saved_ws := bifrost.save_ui_workspace_to_xitdb(&shared, &ui_actor.state, "monitor_default")
		if !saved_ws {
			return false
		}

		fmt.printf(
			"[Bifrost Log Monitor] batches=%d logs_written=%d coalesced=%d frames=%d viewport_rows=%d workspace_saved=%v\n",
			producer_actor.state.batches_sent,
			producer_actor.state.logs_written,
			ui_actor.state.coalesced_commits,
			ui_actor.state.total_frames,
			ui_actor.state.last_viewport_rows,
			saved_ws,
		)
		for r := 0; r < ui_actor.state.rows; r += 1 {
			fmt.printf("  %s\n", extract_monitor_row(&ui_actor.state, r))
		}

		if dir := os.get_env("BIFROST_SCREENSHOT_DIR", context.temp_allocator); dir != "" {
			b := strings.builder_make(context.temp_allocator)
			bifrost.screen_export_html(&ui_actor.state.screen, "Bifrost Log & Metrics Monitor", &b)
			_ = os.write_entire_file_from_string(fmt.tprintf("%s/log_monitor.html", dir), strings.to_string(b))
		}

		// 4. Switch to Tab 2 (`4` -> `tab.heimdall`) to flush & inspect live Heimdall Arrow IPC telemetry records
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Key{code = .Rune, ch = '4'}))
		actor.send(&sched, ui_pid, bifrost.UI_Msg(bifrost.UI_Msg_Frame_Tick{tick_ns = 4}))
		actor.scheduler_wait_idle(&sched)

		fmt.printf(
			"\n[Bifrost Log Monitor — Tab 2 (Heimdall Arrow IPC Viewer)] segments=%d records=%d spans=%d frames=%d\n",
			tctx.store.segment_count,
			len(tctx.store.records),
			tctx.store.total_spans,
			ui_actor.state.total_frames,
		)
		for r := 0; r < ui_actor.state.rows; r += 1 {
			fmt.printf("  %s\n", extract_monitor_row(&ui_actor.state, r))
		}

		if dir := os.get_env("BIFROST_SCREENSHOT_DIR", context.temp_allocator); dir != "" {
			b := strings.builder_make(context.temp_allocator)
			bifrost.screen_export_html(&ui_actor.state.screen, "Bifrost Log Monitor — Heimdall IPC Viewer", &b)
			_ = os.write_entire_file_from_string(fmt.tprintf("%s/log_monitor_heimdall.html", dir), strings.to_string(b))
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

	ok := run_log_monitor(live_tty)

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
