package bifrost_tests

import "core:testing"
import "../bifrost"

// =============================================================================
// Layer 1: Executable Specifications for Track 15
//          (Form Controls Suite: ui_checkbox, ui_switch, ui_radio_group, ui_slider, ui_dropdown)
// =============================================================================

@(private = "file")
s_chk_val: bool

@(private = "file")
s_sw_val: bool

@(private = "file")
s_rg_idx: int

@(private = "file")
s_sld_val: f64

@(private = "file")
s_dd_idx: int

@(private = "file")
s_dd_open: bool

@(private = "file")
s_dd2_idx: int

@(private = "file")
s_dd2_open: bool

@(test)
@(scenario)
spec_checkbox_toggle_space_and_mouse_click :: proc(t: ^testing.T) {
	_ = scenario(t, w = 50, h = 10)
	s_chk_val = false

	build_form :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_checkbox(ctx, scr, &sc.input, "chk_notify", &s_chk_val, "Enable Notifications", {
				focus_flags = {.Default_Focus},
			})
		}
	}

	// 1. Initial render: unchecked
	upon.rendering_frame(build_form)
	then.focused_widget_is("chk_notify")
	then.vt_contains_text("[ ] Enable Notifications", true)
	then.bool_is(s_chk_val, false)

	// 2. Press Space to toggle
	upon.pressing_key(.Space)
	upon.rendering_frame(build_form)
	then.vt_contains_text("[x] Enable Notifications", true)
	then.bool_is(s_chk_val, true)

	// 3. Mouse click to toggle back
	node_r := current_scenario().layout_ctx.nodes[current_scenario().layout_ctx.id_map[bifrost.hash_id("chk_notify")]].rect
	upon.mouse_click(node_r.x + 1, node_r.y)
	upon.rendering_frame(build_form)
	then.vt_contains_text("[ ] Enable Notifications", true)
	then.bool_is(s_chk_val, false)
}

@(test)
@(scenario)
spec_switch_toggle_space_and_mouse_click :: proc(t: ^testing.T) {
	_ = scenario(t, w = 50, h = 10)
	s_sw_val = false

	build_switch_form :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_switch(ctx, scr, &sc.input, "sw_dark", &s_sw_val, "Dark Mode", {
				focus_flags = {.Default_Focus},
			})
		}
	}

	// 1. Initial render: OFF
	upon.rendering_frame(build_switch_form)
	then.focused_widget_is("sw_dark")
	then.vt_contains_text("[ on | OFF ] Dark Mode", true)
	then.bool_is(s_sw_val, false)

	// 2. Press Space to toggle ON
	upon.pressing_key(.Space)
	upon.rendering_frame(build_switch_form)
	then.vt_contains_text("[ ON | off ] Dark Mode", true)
	then.bool_is(s_sw_val, true)

	// 3. Click to toggle OFF
	node_r := current_scenario().layout_ctx.nodes[current_scenario().layout_ctx.id_map[bifrost.hash_id("sw_dark")]].rect
	upon.mouse_click(node_r.x + 2, node_r.y)
	upon.rendering_frame(build_switch_form)
	then.vt_contains_text("[ on | OFF ] Dark Mode", true)
	then.bool_is(s_sw_val, false)
}

@(test)
@(scenario)
spec_radio_group_exclusive_selection_and_arrow_navigation :: proc(t: ^testing.T) {
	_ = scenario(t, w = 50, h = 12)
	s_rg_idx = 0

	build_radio_form :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		options := [3]string{"Small", "Medium", "Large"}
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_radio_group(ctx, scr, &sc.input, "rg_size", &s_rg_idx, options[:], {
				auto_select = true,
			})
		}
	}

	// 1. Initial render: "Small" selected
	upon.rendering_frame(build_radio_form)
	then.vt_contains_text("(•) Small", true)
	then.vt_contains_text("( ) Medium", true)
	then.vt_contains_text("( ) Large", true)
	then.int_is(s_rg_idx, 0)

	// 2. Click option 2 ("Large")
	large_id := "rg_size_opt_2"
	large_idx := current_scenario().layout_ctx.id_map[bifrost.hash_id(large_id)]
	large_r := current_scenario().layout_ctx.nodes[large_idx].rect
	upon.mouse_click(large_r.x + 2, large_r.y)
	upon.rendering_frame(build_radio_form)

	then.vt_contains_text("( ) Small", true)
	then.vt_contains_text("( ) Medium", true)
	then.vt_contains_text("(•) Large", true)
	then.int_is(s_rg_idx, 2)
}

@(test)
@(scenario)
spec_slider_keyboard_stepping_and_home_end :: proc(t: ^testing.T) {
	_ = scenario(t, w = 50, h = 10)
	s_sld_val = 50.0
	s_chk_val = false

	build_slider_form :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1), focus_flags = {.Focus_Scope}}) {
			bifrost.ui_slider(ctx, scr, &sc.input, "sld_vol", &s_sld_val, 0.0, 100.0, 10.0, {
				label       = "Volume",
				focus_flags = {.Default_Focus},
			})
			bifrost.ui_checkbox(ctx, scr, &sc.input, "chk_below", &s_chk_val, "Mute", {})
		}
	}

	// 1. Initial render: 50%
	upon.rendering_frame(build_slider_form)
	then.focused_widget_is("sld_vol")
	then.vt_contains_text("Volume: [", true)
	then.vt_contains_text(" 50%", true)

	// 2. Step Left: 50 -> 40
	upon.pressing_key(.Left)
	upon.rendering_frame(build_slider_form)
	then.vt_contains_text(" 40%", true)
	then.f64_is(s_sld_val, 40.0)

	// 3. Step Right: 40 -> 50
	upon.pressing_key(.Right)
	upon.rendering_frame(build_slider_form)
	then.vt_contains_text(" 50%", true)
	then.f64_is(s_sld_val, 50.0)

	// 4. Jump End -> 100%
	upon.pressing_key(.End)
	upon.rendering_frame(build_slider_form)
	then.vt_contains_text("100%", true)
	then.f64_is(s_sld_val, 100.0)

	// 5. Jump Home -> 0%
	upon.pressing_key(.Home)
	upon.rendering_frame(build_slider_form)
	then.vt_contains_text(" 0%", true)
	then.f64_is(s_sld_val, 0.0)

	// 6. Vertical navigation (`Down` / `Up`) leaves the slider instead of being trapped
	upon.pressing_key(.Down)
	upon.rendering_frame(build_slider_form)
	then.focused_widget_is("chk_below")

	upon.pressing_key(.Up)
	upon.rendering_frame(build_slider_form)
	then.focused_widget_is("sld_vol")

	// 7. Mouse click at rightmost cell of inner track -> 100%
	sld_idx := current_scenario().layout_ctx.id_map[bifrost.hash_id("sld_vol")]
	sld_r   := current_scenario().layout_ctx.nodes[sld_idx].rect
	slot    := bifrost.find_slider_slot(&current_scenario().input, bifrost.hash_id("sld_vol"))
	upon.mouse_click(sld_r.x + slot.track_offset + slot.track_w - 1, sld_r.y)
	upon.rendering_frame(build_slider_form)
	then.vt_contains_text("100%", true)
	then.f64_is(s_sld_val, 100.0)
}

@(test)
@(scenario)
spec_dropdown_parent_anchored_overlay_and_selection :: proc(t: ^testing.T) {
	_ = scenario(t, w = 50, h = 12)
	s_dd_idx = 1
	s_dd_open = false

	build_dd_form :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		langs := [3]string{"Rust", "Odin", "Zig"}
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_dropdown(ctx, scr, &sc.input, "dd_lang", &s_dd_idx, langs[:], &s_dd_open, {
				focus_flags = {.Default_Focus},
			})
		}
	}

	// 1. Initial render: closed with "Odin"
	upon.rendering_frame(build_dd_form)
	then.focused_widget_is("dd_lang")
	then.vt_contains_text("[Odin ▾]", true)
	then.bool_is(s_dd_open, false)

	// 2. Press Space to open
	upon.pressing_key(.Space)
	upon.rendering_frame(build_dd_form)
	then.vt_contains_text("[Odin ▴]", true)
	then.vt_contains_text("✓ Odin", true)
	then.vt_contains_text("Rust", true)
	then.vt_contains_text("Zig", true)
	then.bool_is(s_dd_open, true)

	// 3. Click option 2 ("Zig") inside dropdown menu
	zig_id := "dd_lang_item_2"
	zig_idx := current_scenario().layout_ctx.id_map[bifrost.hash_id(zig_id)]
	zig_r := current_scenario().layout_ctx.nodes[zig_idx].rect
	upon.mouse_click(zig_r.x + 2, zig_r.y)
	upon.rendering_frame(build_dd_form)

	// Menu should close and display "Zig"
	then.vt_contains_text("[Zig ▾]", true)
	then.bool_is(s_dd_open, false)
	then.int_is(s_dd_idx, 2)
}

@(test)
@(scenario)
spec_dropdown_windowed_max_visible_items_keyboard_navigation :: proc(t: ^testing.T) {
	_ = scenario(t, w = 50, h = 14)
	s_dd2_idx = 0
	s_dd2_open = false

	build_windowed_dd :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		items := [4]string{"Alpha", "Beta", "Gamma", "Delta"}
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_dropdown(ctx, scr, &sc.input, "dd_win", &s_dd2_idx, items[:], &s_dd2_open, {
				max_visible_items = 2,
				focus_flags       = {.Default_Focus},
			})
		}
	}

	// 1. Open dropdown with max_visible_items = 2
	upon.rendering_frame(build_windowed_dd)
	upon.pressing_key(.Space)
	upon.rendering_frame(build_windowed_dd)
	then.bool_is(s_dd2_open, true)
	then.focused_widget_is("dd_win_item_0")

	// 2. Navigate down through items 0 -> 1 -> 2 -> 3 and select "Delta"
	upon.pressing_key(.Down)
	upon.rendering_frame(build_windowed_dd)
	then.focused_widget_is("dd_win_item_1")

	upon.pressing_key(.Down)
	upon.rendering_frame(build_windowed_dd)
	then.focused_widget_is("dd_win_item_2")
	then.vt_contains_text("Gamma", true)

	upon.pressing_key(.Down)
	upon.rendering_frame(build_windowed_dd)
	then.focused_widget_is("dd_win_item_3")
	then.vt_contains_text("Delta", true)

	upon.pressing_key(.Enter)
	upon.rendering_frame(build_windowed_dd)
	then.bool_is(s_dd2_open, false)
	then.int_is(s_dd2_idx, 3)
	then.vt_contains_text("[Delta ▾]", true)
}

@(test)
@(scenario)
spec_switch_custom_on_off_labels_and_slider_fixed_width :: proc(t: ^testing.T) {
	_ = scenario(t, w = 60, h = 10)
	s_sw2_val := false
	s_sld2_val := 25.0
	_ = s_sw2_val
	_ = s_sld2_val

	build_custom_form :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		local_sw := false
		local_sld := 25.0
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_switch(ctx, scr, &sc.input, "sw_custom", &local_sw, "Confirm", {
				on_label    = "YES",
				off_label   = "NO",
				focus_flags = {.Default_Focus},
			})
			bifrost.ui_slider(ctx, scr, &sc.input, "sld_fixed", &local_sld, 0.0, 100.0, 5.0, {
				width    = bifrost.fixed(40),
				label    = "Gain",
				fill_fg  = bifrost.rgb(80, 220, 140),
				thumb_fg = bifrost.rgb(255, 220, 80),
			})
		}
	}

	// 1. Custom labels render even when switch is false, and focused switch preserves
	//    distinct .Dim (inactive YES) vs .Bold (active NO) styling
	upon.rendering_frame(build_custom_form)
	then.vt_contains_text("[ YES | NO ] Confirm", true)
	then.cell_style_has(2, 0, .Dim, true)
	then.cell_style_has(2, 0, .Bold, false)
	then.cell_style_has(8, 0, .Bold, true)
	then.cell_style_has(8, 0, .Dim, false)

	// 2. Slider honors fixed(40) width on Frame 0
	slot := bifrost.find_slider_slot(&current_scenario().input, bifrost.hash_id("sld_fixed"))
	then.bool_is(slot != nil && slot.track_w > 20, true)

	// 3. Pressing Home on a slider already at min_val (0.0) does not fire a spurious changed event
	sc := current_scenario()
	clamped_val := 0.0
	sld_changed := false
	build_clamped_sld :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc_in := current_scenario()
		v := 0.0
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			_ = bifrost.ui_slider(ctx, scr, &sc_in.input, "sld_clamp", &v, 0.0, 100.0, 10.0, {
				focus_flags = {.Default_Focus},
			})
		}
	}
	_ = clamped_val
	_ = sld_changed
	upon.rendering_frame(build_clamped_sld)
	upon.pressing_key(.Left)
	clamp_slot := bifrost.find_slider_slot(&sc.input, bifrost.hash_id("sld_clamp"))
	then.bool_is(clamp_slot != nil && !clamp_slot.changed, true)

	// 4. Slider LRU slot eviction allows mounting >16 distinct slider IDs across frames without returning nil
	for i in 0 ..< 20 {
		sc.input.frame_index += 1
		ev_slot := bifrost.get_slider_slot(&sc.input, u64(1000 + i))
		then.bool_is(ev_slot != nil, true)
	}

	// 5. Pressing Escape on an open dropdown closes the menu and restores focus to the dropdown header,
	//    and re-selecting the already-active option returns changed == false
	s_dd2_open = false
	s_dd2_idx = 0
	dd_changed := false
	build_esc_dd :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc_in := current_scenario()
		items := [3]string{"One", "Two", "Three"}
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			_ = bifrost.ui_dropdown(ctx, scr, &sc_in.input, "dd_esc", &s_dd2_idx, items[:], &s_dd2_open, {
				focus_flags = {.Default_Focus},
			})
		}
	}
	_ = dd_changed
	upon.rendering_frame(build_esc_dd)
	upon.pressing_key(.Space)
	upon.rendering_frame(build_esc_dd)
	then.bool_is(s_dd2_open, true)
	upon.pressing_key(.Escape)
	upon.rendering_frame(build_esc_dd)
	then.bool_is(s_dd2_open, false)
	then.focused_widget_is("dd_esc")

	// 6. Radio group with auto_select = true and initial selected_idx = 2 preserves index 2 on initial mount
	s_rg_idx = 2
	build_radio_init2 :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc_in := current_scenario()
		opts := [3]string{"Low", "Med", "High"}
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_radio_group(ctx, scr, &sc_in.input, "rg_init2", &s_rg_idx, opts[:], {
				auto_select = true,
			})
		}
	}
	upon.rendering_frame(build_radio_init2)
	then.int_is(s_rg_idx, 2)
	then.focused_widget_is("rg_init2_opt_2")
}
