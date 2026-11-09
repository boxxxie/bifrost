package bifrost_tests

import "core:testing"
import "../bifrost"

// =============================================================================
// Layer 1: Executable Specifications for Track 19
//          (Turnkey Modal Dialogs, Floating Toasts & Contextual Tooltips)
// =============================================================================

@(private="file")
s_dialog_result: bifrost.Dialog_Result

@(private="file")
s_alert_result: bool

@(private="file")
s_prompt_result: bifrost.Dialog_Result

@(private="file")
s_prompt_text: string

@(private="file")
s_tm: bifrost.Toast_Manager

@(test)
@(scenario)
spec_confirm_dialog_lifecycle_and_actions :: proc(t: ^testing.T) {
	_ = scenario(t, w = 50, h = 15)

	build_ui_del :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			s_dialog_result = bifrost.ui_confirm_dialog(ctx, scr, &sc.input, "dlg_del", bifrost.Confirm_Dialog_Config{
				title           = "Delete Resource?",
				message         = "Are you sure you want to delete this resource?",
				default_confirm = true,
			})
		}
	}

	build_ui_esc :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			s_dialog_result = bifrost.ui_confirm_dialog(ctx, scr, &sc.input, "dlg_esc", bifrost.Confirm_Dialog_Config{
				title           = "Discard Changes?",
				message         = "Unsaved edits will be lost.",
				default_confirm = false,
			})
		}
	}

	// 1. Frame 1: Modal opens, Confirm has default focus, status is .Pending
	upon.rendering_frame(build_ui_del)
	then.dialog_result_is(s_dialog_result, .Pending)
	then.vt_contains_text("Delete Resource?", true)
	then.vt_contains_text("Confirm", true)

	// 2. Frame 2: Enter activates the focused Confirm button -> returns .Confirmed
	upon.pressing_key(.Enter)
	upon.rendering_frame(build_ui_del)
	then.dialog_result_is(s_dialog_result, .Confirmed)

	// 3. Frame 3: Escape key dismisses modal -> returns .Cancelled
	upon.rendering_frame(build_ui_esc)
	then.dialog_result_is(s_dialog_result, .Pending)
	upon.pressing_key(.Escape)
	upon.rendering_frame(build_ui_esc)
	then.dialog_result_is(s_dialog_result, .Cancelled)
}

@(test)
@(scenario)
spec_alert_dialog_acknowledgment :: proc(t: ^testing.T) {
	_ = scenario(t, w = 45, h = 12)

	build_ui_alert :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			s_alert_result = bifrost.ui_alert(ctx, scr, &sc.input, "alt_done", bifrost.Alert_Dialog_Config{
				title   = "Backup Complete",
				message = "Database snapshot committed successfully.",
			})
		}
	}

	// 1. Initial mount: returns false (pending acknowledgment)
	upon.rendering_frame(build_ui_alert)
	then.bool_is(s_alert_result, false)
	then.vt_contains_text("Backup Complete", true)

	// 2. Press Enter to acknowledge OK button
	upon.pressing_key(.Enter)
	upon.rendering_frame(build_ui_alert)
	then.bool_is(s_alert_result, true)
}

@(test)
@(scenario)
spec_prompt_dialog_input_and_commit :: proc(t: ^testing.T) {
	_ = scenario(t, w = 55, h = 14)

	build_ui_prompt :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			s_prompt_result = bifrost.ui_prompt(ctx, scr, &sc.input, "prm_user", &s_prompt_text, bifrost.Prompt_Dialog_Config{
				title       = "Rename Workspace",
				message     = "Enter new workspace label:",
				placeholder = "e.g. production-east",
			})
		}
	}

	// 1. Initial render -> Pending, placeholder visible
	upon.rendering_frame(build_ui_prompt)
	then.dialog_result_is(s_prompt_result, .Pending)
	then.vt_contains_text("Rename Workspace", true)

	// 2. Type text "staging" into input
	upon.pressing_key_rune('s')
	upon.pressing_key_rune('t')
	upon.pressing_key_rune('a')
	upon.pressing_key_rune('g')
	upon.pressing_key_rune('i')
	upon.pressing_key_rune('n')
	upon.pressing_key_rune('g')
	upon.rendering_frame(build_ui_prompt)
	then.vt_contains_text("staging", true)

	// 3. Press Enter -> commits input -> Confirmed
	upon.pressing_key(.Enter)
	upon.rendering_frame(build_ui_prompt)
	then.dialog_result_is(s_prompt_result, .Confirmed)
	then.string_is(s_prompt_text, "staging")

	// 4. Tab to Cancel button and press Enter -> returns .Cancelled (not .Confirmed)
	upon.rendering_frame(build_ui_prompt)
	// Re-opened prompt must start with an empty input buffer (not stale "staging")
	then.vt_contains_text("staging", false)
	upon.pressing_key(.Tab)
	upon.pressing_key(.Tab)
	upon.rendering_frame(build_ui_prompt)
	upon.pressing_key(.Enter)
	upon.rendering_frame(build_ui_prompt)
	then.dialog_result_is(s_prompt_result, .Cancelled)

	// 5. Pressing Escape once while typing inside ui_prompt cancels the modal immediately without requiring double-Escape
	upon.rendering_frame(build_ui_prompt)
	upon.pressing_key_rune('x')
	upon.rendering_frame(build_ui_prompt)
	upon.pressing_key(.Escape)
	upon.rendering_frame(build_ui_prompt)
	then.dialog_result_is(s_prompt_result, .Cancelled)
}

@(test)
@(scenario)
spec_toast_manager_lifecycle_and_stacking :: proc(t: ^testing.T) {
	_ = scenario(t, w = 50, h = 15)

	s_tm = {}
	_ = bifrost.toast_push(&s_tm, "Connected", "Sleipnir cluster peer online", .Success, 20)
	_ = bifrost.toast_push(&s_tm, "High Load", "CPU usage above 85%", .Warning, 5)

	then.toast_count_is(&s_tm, 2)
	then.toast_item_is(&s_tm, 0, "Connected", .Success)
	then.toast_item_is(&s_tm, 1, "High Load", .Warning)

	// Render frame and verify both toasts appear in screen buffer
	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_toast_stack(ctx, scr, &sc.input, &s_tm)
		}
	})

	then.vt_contains_text("Connected", true)
	then.vt_contains_text("High Load", true)

	// Advance 6 ticks: "High Load" (5 ticks) expires, "Connected" (20 - 6 = 14 ticks) remains
	bifrost.toast_update(&s_tm, 6)

	then.toast_count_is(&s_tm, 1)
	then.toast_item_is(&s_tm, 0, "Connected", .Success)

	// Verify toast_push truncates overlong multi-byte UTF-8 strings cleanly on a codepoint boundary
	long_utf8_title := "01234567890123456789012345678901234567890123456789012345678901—"
	_ = bifrost.toast_push(&s_tm, long_utf8_title, "UTF-8 boundary test", .Info, 10)
	truncated_title := bifrost.toast_item_title(&s_tm.items[1])
	then.string_is(truncated_title, "01234567890123456789012345678901234567890123456789012345678901")
}

@(test)
@(scenario)
spec_tooltip_hover_and_positioning :: proc(t: ^testing.T) {
	_ = scenario(t, w = 40, h = 10)

	build_ui_tooltip :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_button(ctx, scr, "btn_deploy", bifrost.Button_Spec{label = "Deploy"})
			bifrost.ui_tooltip(ctx, scr, &sc.input, "btn_deploy", "Trigger rolling deployment")
		}
	}

	// 1. Mouse outside button (target not hovered) -> tooltip does not render
	upon.rendering_frame(build_ui_tooltip)
	upon.mouse_move(30, 8)
	upon.rendering_frame(build_ui_tooltip)
	then.vt_contains_text("Trigger rolling deployment", false)

	// 2. Mouse inside button (col = 2, row = 0) -> tooltip renders
	upon.mouse_move(2, 0)
	upon.rendering_frame(build_ui_tooltip)
	then.vt_contains_text("Trigger rolling deployment", true)

	// 3. Bottom-right button flips tooltip above and clamps horizontally inside screen bounds
	build_ui_bottom_right :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		if bifrost.container(ctx, "root", {
			dir         = .Column,
			width       = bifrost.grow(1),
			height      = bifrost.grow(1),
			main_align  = .End,
			cross_align = .End,
		}) {
			bifrost.ui_button(ctx, scr, "btn_edge", bifrost.Button_Spec{label = "Edge"})
			bifrost.ui_tooltip(ctx, scr, &sc.input, "btn_edge", "Clamped edge tooltip")
		}
	}
	upon.rendering_frame(build_ui_bottom_right)
	upon.mouse_move(36, 9)
	upon.rendering_frame(build_ui_bottom_right)
	then.vt_contains_text("Clamped edge tooltip", true)
}
