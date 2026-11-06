package bifrost_tests

import "core:testing"
import "../bifrost"

// =============================================================================
// Layer 1: Executable Specifications (Track 13: Focus-Scoped Tab Bar `ui_tabs`)
// =============================================================================

@(test)
@(scenario)
spec_tabs_header_rendering_keyboard_bracket_alt_header_nav_and_mouse_switching :: proc(t: ^testing.T) {
	_ = scenario(t, w = 88, h = 18)

	build_tabbed_workspace :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		items := [4]bifrost.Tab_Item_Spec{
			{label = "Explorer", badge = "12", key_hint = "1:"},
			{label = "Search",   badge = "3",  key_hint = "2:"},
			{label = "Locked",   disabled = true},
			{label = "Settings", key_hint = "4:"},
		}

		active_tab := 0
		if bifrost.ui_tabs(ctx, scr, &sc.input, "work_tabs", items[:], {
			body_border = .Plain,
			body_gap    = 1,
		}, &active_tab) {
			switch active_tab {
			case 0:
				bifrost.ui_button(ctx, scr, "exp_btn_a", {label = "Open File", focus_flags = {.Default_Focus}})
				bifrost.ui_button(ctx, scr, "exp_btn_b", {label = "New Folder"})
			case 1:
				bifrost.ui_button(ctx, scr, "srch_btn_a", {label = "Run Query", focus_flags = {.Default_Focus}})
				bifrost.ui_button(ctx, scr, "srch_btn_b", {label = "Clear Results"})
			case 3:
				bifrost.ui_button(ctx, scr, "cfg_btn_a", {label = "Save Config", focus_flags = {.Default_Focus}})
			}
		}
	}

	// 1. Initial mount: Tab 0 ("Explorer") is active, headers and badges render in VT, and exp_btn_a holds focus
	upon.rendering_frame(build_tabbed_workspace)
	then.active_tab_is("work_tabs", 0)
	then.focused_widget_is("exp_btn_a")
	then.vt_contains_text("[ 1:Explorer (12) ]", true)
	then.vt_contains_text("2:Search (3)", true)
	then.vt_contains_text("4:Settings", true)
	then.vt_contains_text("Open File", true)

	// 2. Scoped ']' cycles from Tab 0 -> Tab 1 ("Search") and mounts srch_btn_a on next frame
	upon.pressing_key_rune(']')
	then.active_tab_is("work_tabs", 1)
	then.tab_changed_is("work_tabs", true)

	upon.rendering_frame(build_tabbed_workspace)
	then.focused_widget_is("srch_btn_a")
	then.vt_contains_text("[ 2:Search (3) ]", true)
	then.vt_contains_text("Run Query", true)

	// 3. Pressing ']' again skips disabled Tab 2 ("Locked") and lands on Tab 3 ("Settings")
	upon.pressing_key_rune(']')
	then.active_tab_is("work_tabs", 3)

	upon.rendering_frame(build_tabbed_workspace)
	then.focused_widget_is("cfg_btn_a")
	then.vt_contains_text("[ 4:Settings ]", true)

	// 4. Pressing ']' at the last tab wraps around to Tab 0 ("Explorer"), and '[' wraps back to Tab 3
	upon.pressing_key_rune(']')
	then.active_tab_is("work_tabs", 0)
	upon.rendering_frame(build_tabbed_workspace)
	then.focused_widget_is("exp_btn_a")

	upon.pressing_key_rune('[')
	then.active_tab_is("work_tabs", 3)
	upon.rendering_frame(build_tabbed_workspace)
	then.focused_widget_is("cfg_btn_a")

	// 5. Alt+2 jumps directly to Tab 1 ("Search")
	upon.pressing_key_rune('2', {.Alt})
	then.active_tab_is("work_tabs", 1)
	upon.rendering_frame(build_tabbed_workspace)
	then.focused_widget_is("srch_btn_a")

	// 6. Focus the tab header bar directly (`work_tabs_tab_1`), step left with 'h' to Tab 0,
	//    then press 'j' (or Enter) to drill down into Tab 0's body scope
	upon.requesting_focus("work_tabs_tab_1")
	upon.rendering_frame(build_tabbed_workspace)
	then.focused_widget_is("work_tabs_tab_1")

	upon.pressing_key_rune('h')
	then.active_tab_is("work_tabs", 0)
	then.focused_widget_is("work_tabs_tab_0")

	upon.pressing_key_rune('j')
	upon.rendering_frame(build_tabbed_workspace)
	then.focused_widget_is("exp_btn_a")

	// 7. Mouse left-click on Tab 1 header (`work_tabs_tab_1`) switches active_tab to 1 and focuses body
	upon.clicking_tab("work_tabs", 1)
	then.active_tab_is("work_tabs", 1)
	then.tab_changed_is("work_tabs", true)
	upon.rendering_frame(build_tabbed_workspace)
	then.focused_widget_is("srch_btn_a")
}

@(test)
@(scenario)
spec_tabs_per_tab_focus_scope_deep_history_restoration_across_tab_switches :: proc(t: ^testing.T) {
	_ = scenario(t, w = 92, h = 20)

	build_deep_history_tabs :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		labels := [3]string{" Code ", " Inspector ", " Logs "}
		active := 0

		if bifrost.ui_tabs(ctx, scr, &sc.input, "ide_tabs", labels[:], {
			body_border = .Rounded,
			body_gap    = 1,
		}, &active) {
			switch active {
			case 0:
				// Nested child scope inside Tab 0 to verify true Deep History (H*) restoration
				if bifrost.ui_scope(ctx, scr, "code_group", {
					dir = .Column,
					gap = 1,
				}) {
					bifrost.ui_button(ctx, scr, "tab0_btn1", {label = "Format Buffer", focus_flags = {.Default_Focus}})
					bifrost.ui_button(ctx, scr, "tab0_btn2", {label = "Rename Symbol (Nested H*)"})
				}
			case 1:
				if bifrost.ui_scope(ctx, scr, "insp_group", {
					dir = .Column,
					gap = 1,
				}) {
					bifrost.ui_text_input(ctx, scr, &sc.input, "tab1_input", {
						placeholder = "Filter symbols...",
						two_stage   = true,
						focus_flags = {.Default_Focus},
					})
					bifrost.ui_button(ctx, scr, "tab1_btn2", {label = "Inspect AST Node"})
				}
			case 2:
				bifrost.ui_button(ctx, scr, "tab2_btn1", {label = "Tail Logs", focus_flags = {.Default_Focus}})
				bifrost.ui_button(ctx, scr, "tab2_btn2", {label = "Export Trace"})
			}
		}
	}

	// 1. Mount Tab 0 ("Code"): lands on default control "tab0_btn1", then navigate down to nested "tab0_btn2"
	upon.rendering_frame(build_deep_history_tabs)
	then.active_tab_is("ide_tabs", 0)
	then.focused_widget_is("tab0_btn1")

	upon.pressing_key_rune('j')
	then.focused_widget_is("tab0_btn2")

	// 2. Switch to Tab 1 ("Inspector") via ']': focus lands on Tab 1's initial default control "tab1_input",
	//    then navigate down to "tab1_btn2" so Tab 1 records its own H* leaf
	upon.pressing_key_rune(']')
	upon.rendering_frame(build_deep_history_tabs)
	then.active_tab_is("ide_tabs", 1)
	then.focused_widget_is("tab1_input")

	upon.pressing_key_rune('j')
	then.focused_widget_is("tab1_btn2")

	// 3. Switch to Tab 2 ("Logs") via ']': lands on "tab2_btn1", navigate down to "tab2_btn2"
	upon.pressing_key_rune(']')
	upon.rendering_frame(build_deep_history_tabs)
	then.active_tab_is("ide_tabs", 2)
	then.focused_widget_is("tab2_btn1")

	upon.pressing_key_rune('j')
	then.focused_widget_is("tab2_btn2")

	// 4. Switch back to Tab 0 ("Code") via mouse click on Tab 0 header:
	//    automatically restores focus to deeply nested "tab0_btn2" (H*) rather than resetting to "tab0_btn1"!
	upon.clicking_tab("ide_tabs", 0)
	upon.rendering_frame(build_deep_history_tabs)
	then.active_tab_is("ide_tabs", 0)
	then.focused_widget_is("tab0_btn2")

	// 5. Switch to Tab 1 ("Inspector") via ']': automatically restores focus to "tab1_btn2" (H*)!
	upon.pressing_key_rune(']')
	upon.rendering_frame(build_deep_history_tabs)
	then.active_tab_is("ide_tabs", 1)
	then.focused_widget_is("tab1_btn2")

	// 6. Switch to Tab 2 ("Logs") via Alt+3: automatically restores focus to "tab2_btn2" (H*)!
	upon.pressing_key_rune('3', {.Alt})
	upon.rendering_frame(build_deep_history_tabs)
	then.active_tab_is("ide_tabs", 2)
	then.focused_widget_is("tab2_btn2")
}

@(test)
@(scenario)
spec_tabs_body_row_direction_and_sibling_pane_bracket_isolation :: proc(t: ^testing.T) {
	_ = scenario(t, w = 88, h = 16)

	build_split_tabs :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		if bifrost.ui_scope(ctx, scr, "split_root", {dir = .Row, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_button(ctx, scr, "left_pane_btn", {
				label       = "Tree Explorer Pane",
				width       = bifrost.fixed(22),
				height      = bifrost.fixed(3),
				focus_flags = {.Default_Focus},
			})

			labels := [2]string{"RowBody", "Other"}
			active := 0
			if bifrost.ui_tabs(ctx, scr, &sc.input, "right_tabs", labels[:], {
				body_row = true,
				body_gap = 2,
			}, &active) {
				bifrost.ui_button(ctx, scr, "row_btn_1", {label = "LeftCol", width = bifrost.fixed(12), height = bifrost.fixed(1), focus_flags = {.Default_Focus}})
				bifrost.ui_button(ctx, scr, "row_btn_2", {label = "RightCol", width = bifrost.fixed(12), height = bifrost.fixed(1)})
			}
		}
	}

	// 1. When focus is on `left_pane_btn` outside `right_tabs`, pressing ']' does NOT hijack focus or switch `right_tabs`!
	upon.rendering_frame(build_split_tabs)
	then.focused_widget_is("left_pane_btn")
	then.active_tab_is("right_tabs", 0)

	upon.pressing_key_rune(']')
	upon.rendering_frame(build_split_tabs)
	then.focused_widget_is("left_pane_btn")
	then.active_tab_is("right_tabs", 0)

	// 2. Verify `body_row = true` laid out `row_btn_1` and `row_btn_2` horizontally on the same Y row!
	then.node_rect_is("row_btn_1", {x = 22, y = 1, w = 12, h = 1})
	then.node_rect_is("row_btn_2", {x = 36, y = 1, w = 12, h = 1})

	// 3. Focusing an inactive tab header item directly (`right_tabs_tab_1`) and pressing Left ('h')
	//    steps relative to that focused tab item (1 -> 0) while keeping focus on the header bar!
	upon.requesting_focus("right_tabs_tab_1")
	upon.rendering_frame(build_split_tabs)
	then.focused_widget_is("right_tabs_tab_1")

	upon.pressing_key_rune('l')
	upon.rendering_frame(build_split_tabs)
	then.active_tab_is("right_tabs", 0)
	then.focused_widget_is("right_tabs_tab_0")
}

@(test)
@(scenario)
spec_tabs_header_focus_preserved_across_modal_open_and_close_and_standalone_tab_bar :: proc(t: ^testing.T) {
	_ = scenario(t, w = 80, h = 16)
	sc := current_scenario()

	show_modal := false
	sc.input.action_userdata = &show_modal

	build_modal_and_tabs :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		s := current_scenario()
		modal_open := (^bool)(s.input.action_userdata)^

		if bifrost.ui_scope(ctx, scr, "root_scope", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1), gap = 1}) {
			// Standalone `ui_tab_bar` (not wrapping a body scope)
			bar_labels := [3]string{"Alpha", "Beta", "Gamma"}
			_ = bifrost.ui_tab_bar(ctx, scr, &s.input, "standalone_bar", bar_labels[:])

			// Full `ui_tabs` container
			tab_labels := [2]string{"Main", "Aux"}
			active := 0
			if bifrost.ui_tabs(ctx, scr, &s.input, "modal_tabs", tab_labels[:], {}, &active) {
				bifrost.ui_button(ctx, scr, "body_btn", {label = "Inside Body", focus_flags = {.Default_Focus}})
			}

			if modal_open {
				if bifrost.ui_modal(ctx, scr, "overlay_modal", {
					title    = "Modal Overlay",
					z_layer  = 20,
					width    = bifrost.fixed(30),
					height   = bifrost.fixed(6),
					border   = .Rounded,
					backdrop = .Dim_Screen,
				}) {
					bifrost.ui_button(ctx, scr, "modal_ok_btn", {label = "OK", focus_flags = {.Default_Focus}})
				}
			}
		}
	}

	// 1. Focus the tab header item `modal_tabs_tab_0` directly
	upon.rendering_frame(build_modal_and_tabs)
	upon.requesting_focus("modal_tabs_tab_0")
	upon.rendering_frame(build_modal_and_tabs)
	then.focused_widget_is("modal_tabs_tab_0")

	// 2. Open and render the modal overlay for 2 frames:
	//    `begin_ui_tabs_internal` must NOT overwrite `modal_tabs` outer scope memory with `body_h`
	//    while `modal_tabs_tab_0` was the focused header item, so closing the modal returns focus to `modal_tabs_tab_0`!
	show_modal = true
	upon.rendering_frame(build_modal_and_tabs)
	then.focused_widget_is("modal_ok_btn")

	show_modal = false
	upon.rendering_frame(build_modal_and_tabs)
	then.focused_widget_is("modal_tabs_tab_0")

	// 3. Move focus outside `modal_tabs` (onto `standalone_bar_tab_0`) and press ']':
	//    standalone `ui_tab_bar` advances from 0 -> 1 without setting `wants_focus_id` to a non-existent body scope!
	upon.requesting_focus("standalone_bar_tab_0")
	upon.rendering_frame(build_modal_and_tabs)
	then.focused_widget_is("standalone_bar_tab_0")

	upon.pressing_key_rune(']')
	upon.rendering_frame(build_modal_and_tabs)
	then.active_tab_is("standalone_bar", 1)
	then.focused_widget_is("standalone_bar_tab_1")
}
