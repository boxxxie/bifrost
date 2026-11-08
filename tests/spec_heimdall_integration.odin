package bifrost_tests

import "core:testing"
import "../bifrost"

// =============================================================================
// Layer 1: Executable Specifications — Heimdall Telemetry & OdinArrow Bridge
// =============================================================================

@(test)
@(scenario)
spec_heimdall_captures_nested_actor_coordinator_xitdb_and_renderer_spans :: proc(t: ^testing.T) {
	_ = actor_scenario(t, w = 100, h = 24, num_workers = 2, active_collection = "$metrics")

	given.heimdall_recorder("atdd_heimdall_actor", true, false)

	// Commit 2 batches, run Datalog query, diff moments, and render 2 UI frames
	upon.worker_committing_batch("$metrics", "cpu", 1, 10, true, "m0")
	upon.worker_committing_batch("$metrics", "cpu", 11, 10, true, "m1")
	upon.worker_running_datalog("find ?k, ?v where $metrics[?k] = ?v")
	upon.worker_diffing_moments(0, 1)
	upon.ticking_ui_frame(1)

	// Trigger `moment.prev` (`[`) action and render frame 2
	upon.sending_ui_key(.Rune, '[')
	upon.ticking_ui_frame(2)

	// Flush Heimdall `.arrow` segments and load into `Heimdall_Segment_Store`
	upon.flushing_and_loading_heimdall_segments()

	then.heimdall_recorder_dropped_is(0)
	then.heimdall_has_record(bifrost.TELEMETRY_SCOPE_COORDINATOR, "actor_turn", .Span)
	then.heimdall_has_record(bifrost.TELEMETRY_SCOPE_COORDINATOR, "flush_frame", .Span)
	then.heimdall_has_record(bifrost.TELEMETRY_SCOPE_COORDINATOR, "frames_rendered", .Counter)
	then.heimdall_has_record(bifrost.TELEMETRY_SCOPE_COORDINATOR, "diff_cells", .Gauge)
	then.heimdall_has_record(bifrost.TELEMETRY_SCOPE_LAYOUT, "end_layout", .Span)
	then.heimdall_has_record(bifrost.TELEMETRY_SCOPE_LAYOUT, "layout_nodes", .Gauge)
	then.heimdall_has_record(bifrost.TELEMETRY_SCOPE_INPUT, "resolve_input", .Span)
	then.heimdall_has_record(bifrost.TELEMETRY_SCOPE_INPUT, "action_triggered", .Event)
	then.heimdall_has_record(bifrost.TELEMETRY_SCOPE_RENDERER, "render_layout", .Span)
	then.heimdall_has_record(bifrost.TELEMETRY_SCOPE_RENDERER, "screen_diff_ansi", .Span)
	then.heimdall_has_record(bifrost.TELEMETRY_SCOPE_RENDERER, "ansi_diff_bytes", .Histogram)
	then.heimdall_has_record(bifrost.TELEMETRY_SCOPE_XITDB, "commit_batch", .Span)
	then.heimdall_has_record(bifrost.TELEMETRY_SCOPE_XITDB, "run_datalog", .Span)
	then.heimdall_has_record(bifrost.TELEMETRY_SCOPE_XITDB, "diff_moments", .Span)
	then.heimdall_has_record(bifrost.TELEMETRY_SCOPE_XITDB, "xitdb_slice_viewport", .Span)

	// Verify nested span parent-child hierarchy (`actor_turn` -> `flush_frame` -> `end_layout`, `render_layout`, `slice_viewport` -> `xitdb_slice_viewport`)
	then.heimdall_span_is_child_of(
		bifrost.TELEMETRY_SCOPE_COORDINATOR,
		"flush_frame",
		bifrost.TELEMETRY_SCOPE_COORDINATOR,
		"actor_turn",
	)
	then.heimdall_span_is_child_of(
		bifrost.TELEMETRY_SCOPE_LAYOUT,
		"end_layout",
		bifrost.TELEMETRY_SCOPE_COORDINATOR,
		"flush_frame",
	)
	then.heimdall_span_is_child_of(
		bifrost.TELEMETRY_SCOPE_RENDERER,
		"render_layout",
		bifrost.TELEMETRY_SCOPE_COORDINATOR,
		"flush_frame",
	)
	then.heimdall_span_is_child_of(
		bifrost.TELEMETRY_SCOPE_XITDB,
		"xitdb_slice_viewport",
		bifrost.TELEMETRY_SCOPE_COORDINATOR,
		"slice_viewport",
	)

	// Filter store by `.Spans_Only` and `bifrost.renderer`
	upon.filtering_heimdall_store(.Spans_Only, bifrost.TELEMETRY_SCOPE_RENDERER, "")
	then.heimdall_filtered_count_at_least(2)
}

@(test)
@(scenario)
spec_heimdall_default_recorder_fallback_and_ui_widget_inspection :: proc(t: ^testing.T) {
	_ = scenario(t, w = 96, h = 24)

	// Configure `heimdall.set_default_recorder` without setting explicit `.recorder` pointers on structs
	given.heimdall_recorder("atdd_heimdall_default", false, true)

	upon.rendering_frame_with_events(
		proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
			if bifrost.container(ctx, "root", bifrost.Box_Config{
				dir    = .Column,
				width  = bifrost.fixed(96),
				height = bifrost.fixed(24),
			}) {
				_ = bifrost.ui_button(ctx, scr, "btn_run", bifrost.Button_Spec{label = "Run Telemetry"})
			}
		},
		bifrost.Input_Event(bifrost.Key_Event{code = .Enter, action = .Press}),
	)

	upon.flushing_and_loading_heimdall_segments()

	then.heimdall_recorder_dropped_is(0)
	then.heimdall_has_record(bifrost.TELEMETRY_SCOPE_LAYOUT, "end_layout", .Span)
	then.heimdall_has_record(bifrost.TELEMETRY_SCOPE_INPUT, "resolve_input", .Span)
	then.heimdall_has_record(bifrost.TELEMETRY_SCOPE_RENDERER, "render_layout", .Span)
	then.heimdall_has_record(bifrost.TELEMETRY_SCOPE_RENDERER, "screen_diff_ansi", .Span)

	// Render a follow-up frame mounting `ui_tree` and `ui_sparkline` directly from `s.heimdall_store`
	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		nodes := bifrost.heimdall_store_build_scope_tree(&sc.heimdall_store, context.temp_allocator)
		durs  := bifrost.heimdall_store_extract_span_durations_us(&sc.heimdall_store, 16)

		if bifrost.container(ctx, "inspect_root", bifrost.Box_Config{
			dir    = .Column,
			width  = bifrost.fixed(96),
			height = bifrost.fixed(24),
		}) {
			_ = bifrost.ui_sparkline(ctx, scr, "span_spark", durs, bifrost.Sparkline_Config{
				title  = "Span Durations (us)",
				width  = bifrost.grow(1),
				height = bifrost.fixed(3),
				border = .Plain,
			})
			tslice: bifrost.Tree_Slice
			_ = bifrost.ui_tree(ctx, scr, &sc.input, "scope_tree", nodes, bifrost.Tree_Config{
				title  = "Heimdall Scopes",
				width  = bifrost.grow(1),
				height = bifrost.grow(1),
				border = .Plain,
			}, &tslice)
		}
	})

	then.vt_row_contains_text(0, "Span Durations (us)")
	then.vt_row_contains_text(3, "Heimdall Scopes")
	then.vt_row_contains_text(4, "bifrost.layout")
}
