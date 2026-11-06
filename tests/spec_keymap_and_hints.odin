package bifrost_tests

import "core:testing"
import "../bifrost"

ATDD_Track8_Action :: enum u8 {
	None = 0,
	Stage_Left,
	Stage_Right,
	Jump_Top,
	Quit,
}

ATDD_Track8_Actions :: struct {
	Stage_Left:  ATDD_Track8_Action `bifrost:"key=H, id=task.left, scope=col_*, group=stage, group_desc=Move Stage, desc=Move Left, category=Board"`,
	Stage_Right: ATDD_Track8_Action `bifrost:"key=L, id=task.right, scope=col_*, group=stage, group_desc=Move Stage, desc=Move Right, category=Board"`,
	Jump_Top:    ATDD_Track8_Action `bifrost:"key=g g, id=nav.top, desc=Jump Top, category=Nav"`,
	Quit:        ATDD_Track8_Action `bifrost:"key=q|<C-q>, id=app.quit, desc=Quit, category=App"`,
}

@(test)
@(scenario)
spec_declarative_key_chords_splitter_submode_and_live_contextual_hint_bar :: proc(t: ^testing.T) {
	s := scenario(t, w = 96, h = 16)

	palette: bifrost.Command_Palette
	bifrost.command_palette_init(&palette, &s.input)
	given_actions_struct_registered(&palette, ATDD_Track8_Actions{})

	build_track8_ui :: proc(events: ..bifrost.Input_Event) {
		upon.rendering_frame_with_events(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
			sc := current_scenario()
			split_w := bifrost.get_split_size(&sc.input, "board_split", default_size = 24, min_size = 12, max_size = 50)
			if bifrost.ui_scope(ctx, scr, "root", {
				dir    = .Column,
				width  = bifrost.grow(1),
				height = bifrost.grow(1),
			}) {
				bifrost.ui_focus_breadcrumb_bar(ctx, scr, &sc.input, "breadcrumb_bar")
				if bifrost.ui_scope(ctx, scr, "workspace", {
					dir    = .Row,
					width  = bifrost.grow(1),
					height = bifrost.grow(1),
				}) {
					if bifrost.ui_scope(ctx, scr, "sidebar", {
						dir    = .Column,
						width  = bifrost.fixed(split_w),
						height = bifrost.grow(1),
						border = .Plain,
					}) {
						bifrost.ui_button(ctx, scr, "side_btn", {label = "Backlog Filter"})
					}
					bifrost.ui_splitter(ctx, scr, &sc.input, "board_split", {
						dir          = .Row,
						default_size = 24,
						min_size     = 12,
						max_size     = 50,
						step         = 4,
					})
					if bifrost.ui_scope(ctx, scr, "col_doing", {
						dir         = .Column,
						width       = bifrost.grow(1),
						height      = bifrost.grow(1),
						border      = .Plain,
						focus_flags = {.Focusable, .Default_Focus},
					}) {
						bifrost.ui_button(ctx, scr, "card_1", {
							label       = "Implement Chord DSL",
							focus_flags = {.Default_Focus},
						})
					}
				}
				bifrost.ui_key_hint_bar(ctx, scr, &sc.input, "hint_bar")
			}
		}, ..events)
	}

	// 1. Initial frame: card_1 inside col_doing is focused; VT shows breadcrumb path & grouped col_* hint "H/L: Move Stage"
	build_track8_ui()
	then.focused_widget_is("card_1")
	then.vt_contains_text("root -> workspace -> col_doing -> card_1", true)
	then.vt_contains_text("H/L: Move Stage", true)

	// 2. Step 1 of 2-step chord ('g') immediately renders [CHORD: badge on the exact same frame; step 2 ('g') fires nav.top!
	build_track8_ui(bifrost.Key_Event{code = .Rune, ch = 'g'})
	then.pending_chord_is(true, "g")
	then.vt_contains_text("[CHORD:", true)

	build_track8_ui(bifrost.Key_Event{code = .Rune, ch = 'g'})
	then.pending_chord_is(false)
	then.action_triggered_is("nav.top", true)

	// 3. Focus splitter via spatial West ('h'), press Enter -> [RESIZE] submode -> 'l' grows split (24 -> 28) -> Esc exits
	build_track8_ui(bifrost.Key_Event{code = .Rune, ch = 'h'})
	then.focused_widget_is("board_split")
	then.splitter_submode_is("board_split", .Navigate)

	build_track8_ui(bifrost.Key_Event{code = .Enter})
	then.splitter_submode_is("board_split", .Resize)
	then.vt_contains_text("[RESIZE]", true)

	build_track8_ui(bifrost.Key_Event{code = .Rune, ch = 'l'})
	then.split_size_is("board_split", 28)

	build_track8_ui(bifrost.Key_Event{code = .Escape})
	then.splitter_submode_is("board_split", .Navigate)
	then.vt_contains_text("[RESIZE]", false)
}


@(test)
@(scenario)
spec_action_guards_disabled_swallow_vs_bubble_and_hint_bar_availability :: proc(t: ^testing.T) {
	s := scenario(t, w = 96, h = 12)

	palette: bifrost.Command_Palette
	bifrost.command_palette_init(&palette, &s.input)
	given_actions_struct_registered(&palette, ATDD_Track8_Actions{})
	given.chord_bound("H", "outer.fallback_H")

	Guard_Mode_Box :: struct {
		mode: bifrost.Guard_Result,
	}
	gbox := Guard_Mode_Box{mode = .Disabled_Swallow}
	given.action_guard("task.left", proc(_: u64, ud: rawptr) -> (bifrost.Guard_Result, string) {
		b := (^Guard_Mode_Box)(ud)
		return b.mode, "Already at leftmost stage"
	}, &gbox)

	// Dim 'g g' ("Jump Top") and hide 'q' ("Quit") in the contextual hint bar
	given.action_availability("nav.top", .Disabled_Dimmed)
	given.action_availability("app.quit", .Hidden)

	build_guarded_ui :: proc(events: ..bifrost.Input_Event) {
		upon.rendering_frame_with_events(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
			sc := current_scenario()
			if bifrost.ui_scope(ctx, scr, "root", {
				dir    = .Column,
				width  = bifrost.grow(1),
				height = bifrost.grow(1),
			}) {
				if bifrost.ui_scope(ctx, scr, "col_backlog", {
					dir         = .Column,
					width       = bifrost.grow(1),
					height      = bifrost.grow(1),
					border      = .Plain,
					focus_flags = {.Focusable, .Default_Focus},
				}) {
					bifrost.ui_button(ctx, scr, "card_1", {
						label       = "Guarded Card",
						focus_flags = {.Default_Focus},
					})
				}
				bifrost.ui_key_hint_bar(ctx, scr, &sc.input, "hint_bar")
			}
		}, ..events)
	}

	// 1. Initial frame: 'Quit' (.Hidden) is omitted from hint_bar, while 'Jump Top' (.Disabled_Dimmed) renders dimmed
	build_guarded_ui()
	then.focused_widget_is("card_1")
	then.vt_contains_text("Quit", false)
	then.paint_has_dimmed_span("hint_bar", "Jump Top", true)

	// 2. Pressing 'H' with .Disabled_Swallow consumes the key at col_backlog and records disabled reason without firing outer.fallback_H
	build_guarded_ui(bifrost.Key_Event{code = .Rune, ch = 'H', mods = {.Shift}})
	then.action_triggered_is("task.left", false)
	then.action_triggered_is("outer.fallback_H", false)
	then.disabled_action_reason_is("Already at leftmost stage")

	// 3. Switching guard to .Disabled_Bubble skips col_backlog 'H' and bubbles to root 'outer.fallback_H'
	gbox.mode = .Disabled_Bubble
	build_guarded_ui(bifrost.Key_Event{code = .Rune, ch = 'H', mods = {.Shift}})
	then.action_triggered_is("outer.fallback_H", true)

	// 4. Switching guard to .Enabled fires typed ATDD_Track8_Action.Stage_Left
	gbox.mode = .Enabled
	build_guarded_ui(bifrost.Key_Event{code = .Rune, ch = 'H', mods = {.Shift}})
	then_typed_action_triggered_is(ATDD_Track8_Action.Stage_Left)
}

