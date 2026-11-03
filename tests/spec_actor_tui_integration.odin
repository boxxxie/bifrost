package bifrost_tests

import "core:fmt"
import "core:testing"
import "../bifrost"
import xitdb "../deps/xitdb/xitdb"

// =============================================================================
// Layer 1: Executable Specifications — Sleipnir Actor Runtime & xitdb Inspector
// =============================================================================

@(test)
spec_worker_actor_commits_and_ui_coordinator_renders :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_actor_xitdb_inspector(&s, t, 100, 24, 2, "$users")
	defer driver_destroy(&s)

	// Commit 2 moments via worker actor (1 DSL script + 1 sorted batch)
	upon_worker_transacting_script(
		&s,
		`
		doc "initial seed"
		put .users$user_000001 = "alice"
		put .users$user_000002 = "bob"
		`,
		"v0.1.0",
	)
	upon_worker_committing_batch(&s, "$users", "user", 3, 25, true, "v0.2.0")

	// Render 1 coalesced UI frame
	upon_ticking_ui_frame(&s, 1)

	then_worker_ping_count_is(&s, 2)
	then_ui_coordinator_metrics_are(&s, 2, 1)
	then_ui_active_moment_is(&s, 1, 1, false)
	then_ui_screen_contains_text(&s, "LIVE @1 (latest @1")
	then_ui_screen_contains_text(&s, "Records (27 total)")
	then_ui_screen_contains_text(&s, "user:000003")
}

@(test)
spec_mailbox_burst_coalesces_1000_commits_into_single_frame :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_actor_xitdb_inspector(&s, t, 100, 24, 2, "$events")
	defer driver_destroy(&s)

	// Seed 1 moment so the database has records to display
	upon_worker_committing_batch(&s, "$events", "ev", 0, 10, true, "seed")
	upon_ticking_ui_frame(&s, 1)
	then_ui_coordinator_metrics_are(&s, 1, 1)

	// Flood 1,000 rapid commit notifications into the UI coordinator actor's mailbox
	// followed by a single vsync tick
	upon_sending_commit_burst(&s, 1000)
	upon_ticking_ui_frame(&s, 2)

	// All 1,000 notifications must coalesce into 1 additional frame (total_frames == 2)
	then_ui_coordinator_metrics_are(&s, 1001, 2)
	then_ui_active_moment_is(&s, 999, 999, false)
	then_ui_screen_contains_text(&s, "LIVE @999")
}

@(test)
spec_historical_moment_time_travel_and_datalog_diff_queries :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_actor_xitdb_inspector(&s, t, 110, 24, 2, "$accounts")
	defer driver_destroy(&s)

	// Commit Moment @0 (5 accounts) and Moment @1 (10 more accounts = 15 total)
	upon_worker_committing_batch(&s, "$accounts", "acct", 1, 5, true, "m0")
	upon_worker_committing_batch(&s, "$accounts", "acct", 6, 10, true, "m1")
	upon_ticking_ui_frame(&s, 1)

	then_ui_active_moment_is(&s, 1, 1, false)
	then_ui_screen_contains_text(&s, "Records (15 total)")

	// Pin the UI viewport to historical Moment @0
	upon_sending_ui_msg(&s, bifrost.UI_Msg(bifrost.UI_Msg_Select_Moment{
		moment_idx = 0,
		pin        = true,
	}))
	upon_ticking_ui_frame(&s, 2)

	then_ui_active_moment_is(&s, 0, 1, true)
	then_ui_screen_contains_text(&s, "PINNED @0 (latest @1")
	then_ui_screen_contains_text(&s, "Records (5 total)")

	// While pinned to @0, background worker commits Moments @2 and @3
	upon_worker_committing_batch(&s, "$accounts", "acct", 16, 10, true, "m2")
	upon_worker_committing_batch(&s, "$accounts", "acct", 26, 10, true, "m3")
	upon_worker_diffing_moments(&s, 0, 3)
	upon_worker_running_datalog(&s, "find ?k, ?v where $accounts[?k] = ?v")
	upon_ticking_ui_frame(&s, 3)

	// Viewport must remain locked on Moment @0 (5 records) even though latest is @3 (35 records)
	then_ui_active_moment_is(&s, 0, 3, true)
	then_ui_screen_contains_text(&s, "PINNED @0 (latest @3")
	then_ui_screen_contains_text(&s, "Records (5 total)")
	then_ui_screen_contains_text(&s, "datalog rows=35 cols=2")
	then_ui_screen_contains_text(&s, "Diff(@0->@3): +30 ~0 -0")

	// Unpin via 'f' key to jump back to live latest Moment @3
	upon_sending_ui_msg(&s, bifrost.UI_Msg(bifrost.UI_Msg_Key{
		code = .Rune,
		ch   = 'f',
	}))
	upon_ticking_ui_frame(&s, 4)

	then_ui_active_moment_is(&s, 3, 3, false)
	then_ui_screen_contains_text(&s, "LIVE @3 (latest @3")
	then_ui_screen_contains_text(&s, "Records (35 total)")
}

@(test)
spec_100k_row_log16_viewport_slicing_and_interactive_widgets :: proc(t: ^testing.T) {
	s: Suite_Ctx
	given_actor_xitdb_inspector(&s, t, 100, 24, 2, ".logs")
	defer driver_destroy(&s)

	// Populate a 100,000-row Array_List in a single transaction
	tx := xitdb.tx_init(&s.db, -1, false, context.temp_allocator)
	logs_step := [1]xitdb.Path_Step{xitdb.hm("logs")}
	for i := 0; i < 100_000; i += 1 {
		xitdb.tx_append_steps(&tx, logs_step[:], i64(i * 10))
	}
	report, err := xitdb.tx_commit(&tx)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, report.moment_index, i64(0))
	free_all(context.temp_allocator)

	// Notify UI coordinator of Moment @0 and scroll directly to row 75,000 in O(log_16 N)
	upon_sending_ui_msg(&s, bifrost.UI_Msg(bifrost.UI_Msg_Commit_Notification{
		moment_idx = 0,
		slot_ptr   = 64,
		tx_id      = 1,
		tag_name   = "100k_seed",
	}))
	upon_ticking_ui_frame(&s, 1)
	then_ui_screen_contains_text(&s, "Records (100000 total)")

	// Scroll to row 75,000 and open the Ctrl+P Command Palette
	upon_sending_ui_msg(&s, bifrost.UI_Msg(bifrost.UI_Msg_Scroll_Viewport{
		delta_rows  = 75_000,
		page_scroll = false,
	}))
	upon_sending_ui_msg(&s, bifrost.UI_Msg(bifrost.UI_Msg_Key{
		code = .Rune,
		ch   = 'p',
		ctrl = true,
	}))
	upon_ticking_ui_frame(&s, 2)

	// Verify O(log_16 N) slice rendered row 75,000 (val = 750000) and Command Palette is open
	testing.expect_value(t, s.ui_actor.state.vlist.selected_row, 75_000)
	testing.expect_value(t, s.ui_actor.state.palette_open, true)
	then_ui_screen_contains_text(&s, "[75000]")
	then_ui_screen_contains_text(&s, "750000")
	then_ui_screen_contains_text(&s, "Command Palette")

	// Also verify direct xitdb_slice_viewport at row 99,990 returns 10 rows with zero leaks
	slice, s_err := bifrost.xitdb_slice_viewport(
		&s.db,
		0,
		".logs",
		99_990,
		15,
		{},
		context.temp_allocator,
	)
	testing.expect_value(t, s_err, nil)
	testing.expect_value(t, slice.total_rows, i64(100_000))
	testing.expect_value(t, len(slice.rows), 10)
	testing.expect_value(t, slice.rows[0].logical_index, i64(99_990))
	testing.expect_value(t, slice.rows[0].val_text, fmt.tprintf("%d", 99_990 * 10))
	testing.expect_value(t, slice.rows[9].logical_index, i64(99_999))
}
