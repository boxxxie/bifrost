package bifrost_tests

import "core:fmt"
import "core:testing"
import "../bifrost"

// =============================================================================
// Track 12: Virtualized Collapsible Tree (`ui_tree`) Executable Specifications
// =============================================================================

@(test)
@(scenario)
spec_tree_guide_glyphs_and_expand_collapse_navigation :: proc(t: ^testing.T) {
	_ = scenario(t, w = 54, h = 14)

	build_ui :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		nodes := [?]bifrost.Tree_Node{
			{id = "n_bifrost",   label = "bifrost",        depth = 0, expanded = true,  has_children = true},  // 0
			{id = "n_layout",    label = "layout.odin",    depth = 1, expanded = false, has_children = false}, // 1
			{id = "n_widgets",   label = "widgets",        depth = 1, expanded = true,  has_children = true},  // 2
			{id = "n_scroll",    label = "scroll.odin",    depth = 2, expanded = false, has_children = false}, // 3
			{id = "n_tree",      label = "tree.odin",      depth = 2, expanded = false, has_children = false}, // 4
			{id = "n_renderer",  label = "renderer.odin",  depth = 1, expanded = false, has_children = false}, // 5
			{id = "n_tests",     label = "tests",          depth = 0, expanded = false, has_children = true},  // 6
			{id = "n_spec_tree", label = "spec_tree.odin", depth = 1, expanded = false, has_children = false}, // 7
		}
		if bifrost.container(ctx, "root", {
			dir    = .Column,
			width  = bifrost.grow(1),
			height = bifrost.grow(1),
		}) {
			bifrost.ui_tree(ctx, scr, &sc.input, "pkg_tree", nodes[:], {
				title         = "Workspace",
				width         = bifrost.grow(1),
				height        = bifrost.grow(1),
				border        = .Rounded,
				fallback_rows = 12,
			})
		}
	}

	// Frame 0: initial mount
	// Visible rows (7 total, since node 6 "tests" is collapsed):
	// vis 0 (y=1): "▾ bifrost"          (node 0)
	// vis 1 (y=2): "├─ layout.odin"     (node 1)
	// vis 2 (y=3): "├─ ▾ widgets"       (node 2)
	// vis 3 (y=4): "│  ├─ scroll.odin"  (node 3)
	// vis 4 (y=5): "│  ╰─ tree.odin"    (node 4)
	// vis 5 (y=6): "╰─ renderer.odin"   (node 5)
	// vis 6 (y=7): "▸ tests"            (node 6)
	upon.rendering_frame(build_ui)
	then.focused_widget_is("pkg_tree")
	then.tree_visible_count_is("pkg_tree", 7)
	then.tree_selection_is("pkg_tree", 0, 0)
	then.vt_row_contains_text(1, "▾ bifrost")
	then.vt_row_contains_text(2, "├─ layout.odin")
	then.vt_row_contains_text(3, "├─ ▾ widgets")
	then.vt_row_contains_text(4, "│  ├─ scroll.odin")
	then.vt_row_contains_text(5, "│  ╰─ tree.odin")
	then.vt_row_contains_text(6, "╰─ renderer.odin")
	then.vt_row_contains_text(7, "▸ tests")

	// Step down to node 2 ("widgets") at vis_row 2 and press Enter to collapse it
	upon.pressing_key_rune('j')
	upon.pressing_key_rune('j')
	then.tree_selection_is("pkg_tree", 2, 2)

	upon.pressing_key(.Enter)
	then.tree_node_expanded_is("pkg_tree", 2, false)
	then.tree_visible_count_is("pkg_tree", 5)

	upon.rendering_frame(build_ui)
	then.vt_row_contains_text(3, "├─ ▸ widgets")
	then.vt_row_contains_text(4, "╰─ renderer.odin")
	then.vt_row_contains_text(5, "▸ tests")

	// Press Space on collapsed "widgets" (node 2) to re-expand it
	upon.pressing_key(.Space)
	then.tree_node_expanded_is("pkg_tree", 2, true)
	then.tree_visible_count_is("pkg_tree", 7)

	// Press Down to select leaf "scroll.odin" (node 3) and press Enter to activate it
	upon.pressing_key(.Down)
	then.tree_selection_is("pkg_tree", 3, 3)
	upon.pressing_key(.Enter)
	then.tree_activated_node_is("pkg_tree", 3)
	then.activated_widget_is("n_scroll")

	// Mouse left-click on row y=7 (vis_row 6 -> node 6 "tests") selects & expands "tests"
	upon.rendering_frame(build_ui)
	upon.mouse_click(4, 7)
	then.tree_selection_is("pkg_tree", 6, 6)
	then.tree_node_expanded_is("pkg_tree", 6, true)
	then.tree_visible_count_is("pkg_tree", 8)

	upon.rendering_frame(build_ui)
	then.vt_row_contains_text(7, "▾ tests")
	then.vt_row_contains_text(8, "╰─ spec_tree.odin")
}

@(test)
@(scenario)
spec_tree_parent_node_jump_and_child_drill_down :: proc(t: ^testing.T) {
	_ = scenario(t, w = 50, h = 12)

	build_ui :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		nodes := [?]bifrost.Tree_Node{
			{id = "root_a",   label = "root_a",   depth = 0, expanded = true,  has_children = true},  // 0
			{id = "branch_b", label = "branch_b", depth = 1, expanded = true,  has_children = true},  // 1
			{id = "leaf_b1",  label = "leaf_b1",  depth = 2, expanded = false, has_children = false}, // 2
			{id = "leaf_b2",  label = "leaf_b2",  depth = 2, expanded = false, has_children = false}, // 3
			{id = "branch_c", label = "branch_c", depth = 1, expanded = false, has_children = true},  // 4
			{id = "leaf_c1",  label = "leaf_c1",  depth = 2, expanded = false, has_children = false}, // 5
		}
		if bifrost.container(ctx, "root", {
			dir    = .Column,
			width  = bifrost.grow(1),
			height = bifrost.grow(1),
		}) {
			bifrost.ui_tree(ctx, scr, &sc.input, "nav_tree", nodes[:], {
				title         = "Outline",
				width         = bifrost.grow(1),
				height        = bifrost.grow(1),
				border        = .Rounded,
				fallback_rows = 10,
			})
		}
	}

	upon.rendering_frame(build_ui)
	then.tree_selection_is("nav_tree", 0, 0)

	// Pressing Right (`l`) on already-expanded `root_a` (node 0) moves selection to its first child `branch_b` (node 1)
	upon.pressing_key_rune('l')
	then.tree_selection_is("nav_tree", 1, 1)

	// Pressing Right (`l`) on already-expanded `branch_b` (node 1) moves to its first child `leaf_b1` (node 2)
	upon.pressing_key(.Right)
	then.tree_selection_is("nav_tree", 2, 2)

	// Move down to `leaf_b2` (node 3, vis_row 3)
	upon.pressing_key_rune('j')
	then.tree_selection_is("nav_tree", 3, 3)

	// Pressing Left (`h`) on leaf `leaf_b2` (node 3) jumps directly to its parent `branch_b` (node 1, vis_row 1)!
	upon.pressing_key_rune('h')
	then.tree_selection_is("nav_tree", 1, 1)
	then.tree_node_expanded_is("nav_tree", 1, true)

	// Pressing Left (`h`) on expanded `branch_b` (node 1) collapses `branch_b` in-place
	upon.pressing_key(.Left)
	then.tree_node_expanded_is("nav_tree", 1, false)
	then.tree_selection_is("nav_tree", 1, 1)
	then.tree_visible_count_is("nav_tree", 3) // root_a (0), branch_b (1), branch_c (4)

	// Pressing Left (`h`) again on now-collapsed `branch_b` (node 1) jumps to its parent `root_a` (node 0, vis_row 0)!
	upon.pressing_key_rune('h')
	then.tree_selection_is("nav_tree", 0, 0)

	// Move down to collapsed `branch_c` (node 4, vis_row 2) and press Right (`l`) to expand it
	upon.pressing_key_rune('j')
	upon.pressing_key_rune('j')
	then.tree_selection_is("nav_tree", 4, 2)
	upon.pressing_key_rune('l')
	then.tree_node_expanded_is("nav_tree", 4, true)
	then.tree_visible_count_is("nav_tree", 4)

	// Clicking empty space below the 4 visible rows (e.g. y = 9 inside the 10-row inner viewport)
	// must NOT toggle/collapse or activate the last visible node (`leaf_c1`, node 5)!
	upon.rendering_frame(build_ui)
	upon.mouse_click(5, 9)
	then.tree_selection_is("nav_tree", 4, 2)
	then.tree_activated_node_is("nav_tree", -1)
	then.tree_node_expanded_is("nav_tree", 4, true)
}

@(test)
@(scenario)
spec_virtual_tree_10k_nodes_o1_layout_budget_and_scrollbar :: proc(t: ^testing.T) {
	_ = scenario(t, w = 60, h = 14)

	// 10,000-node hierarchy: 100 root modules * (1 module branch + 99 leaf symbols = 100 nodes per module) = 10,000 nodes
	build_10k_tree :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		sc := current_scenario()
		nodes := make([]bifrost.Tree_Node, 10_000, context.temp_allocator)
		idx := 0
		for m := 0; m < 100; m += 1 {
			nodes[idx] = bifrost.Tree_Node{
				label        = fmt.aprintf("module_%03d", m, allocator = context.temp_allocator),
				depth        = 0,
				parent_idx   = -1,
				expanded     = true,
				has_children = true,
			}
			mod_idx := i32(idx)
			idx += 1
			for c := 1; c < 100; c += 1 {
				nodes[idx] = bifrost.Tree_Node{
					label        = fmt.aprintf("sym_%03d_%02d", m, c, allocator = context.temp_allocator),
					depth        = 1,
					parent_idx   = mod_idx,
					expanded     = false,
					has_children = false,
				}
				idx += 1
			}
		}

		if bifrost.container(ctx, "root", {
			dir    = .Column,
			width  = bifrost.grow(1),
			height = bifrost.grow(1),
		}) {
			bifrost.ui_tree(ctx, scr, &sc.input, "huge_tree", nodes, {
				title         = "10K AST Tree",
				width         = bifrost.grow(1),
				height        = bifrost.grow(1),
				border        = .Rounded,
				fallback_rows = 12,
			})
		}
	}

	// Frame 0: 10,000 total visible rows inside a 14-row box (inner_rect.h = 12)
	// Total materialized Layout_Nodes MUST be O(visible_rows):
	// 1 ("root") + 1 ("huge_tree") + 12 visible rows = 14 Layout_Nodes!
	upon.rendering_frame(build_10k_tree)
	then.layout_node_count_is(14)
	then.tree_visible_count_is("huge_tree", 10_000)
	then.tree_selection_is("huge_tree", 0, 0)
	then.vt_row_contains_text(1, "▾ module_000")
	then.vt_row_contains_text(2, "├─ sym_000_01")
	then.cell_at_is(59, 1, '┃')
	then.cell_at_is(59, 2, '│')

	// Collapsing `module_000` (node 0) hides its 99 children -> 9,901 visible rows, still 14 Layout_Nodes!
	upon.pressing_key_rune('h')
	then.tree_node_expanded_is("huge_tree", 0, false)
	then.tree_visible_count_is("huge_tree", 9_901)

	upon.rendering_frame(build_10k_tree)
	then.layout_node_count_is(14)
	then.vt_row_contains_text(1, "▸ module_000")
	then.vt_row_contains_text(2, "▾ module_001")

	// Jump to End of the 10K tree -> selects last node (node 9999, vis_row 9900)
	upon.pressing_key(.End)
	then.tree_selection_is("huge_tree", 9_999, 9_900)

	upon.rendering_frame(build_10k_tree)
	then.layout_node_count_is(14)
	then.vt_row_contains_text(12, "╰─ sym_099_99")
	then.cell_at_is(59, 11, '│')
	then.cell_at_is(59, 12, '┃')

	// Pressing Left (`h`) on the very last leaf `sym_099_99` (node 9999) jumps directly to its parent `module_099` (node 9900)
	// and auto-scrolls the viewport so `module_099` is visible at the top of the viewport!
	upon.pressing_key_rune('h')
	then.tree_selection_is("huge_tree", 9_900, 9_801)

	upon.rendering_frame(build_10k_tree)
	then.layout_node_count_is(14)
	then.vt_row_contains_text(1, "▾ module_099")
}

@(test)
@(scenario)
spec_tree_skipped_depth_clamping_and_dynamic_id_hash_expand_persistence :: proc(t: ^testing.T) {
	_ = scenario(t, w = 48, h = 10)
	sc := current_scenario()

	prepend_filter_node := false
	sc.input.action_userdata = &prepend_filter_node

	build_dyn_tree :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		s := current_scenario()
		prepend := (^bool)(s.input.action_userdata)^

		dyn_nodes := make([dynamic]bifrost.Tree_Node, 0, 6, context.temp_allocator)
		if prepend {
			append(&dyn_nodes, bifrost.Tree_Node{id = "inserted_top", label = "inserted.txt", depth = 0})
		}
		// Notice `child_skipped` specifies `depth = 3` directly beneath root `branch_a` (`depth = 0`)
		// -> `ui_tree` clamps `depth` to `prev_depth + 1` (`1`) so `parent_idx` resolves to `branch_a`!
		append(&dyn_nodes, bifrost.Tree_Node{id = "branch_a", label = "branch_a/", depth = 0, expanded = true, has_children = true})
		append(&dyn_nodes, bifrost.Tree_Node{id = "child_skipped", label = "skipped_depth.odin", depth = 3})

		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_tree(ctx, scr, &s.input, "dyn_tree", dyn_nodes[:], {
				width         = bifrost.grow(1),
				height        = bifrost.grow(1),
				border        = .Rounded,
				fallback_rows = 6,
			})
		}
	}

	// Frame 0: `branch_a` is expanded at index 0, and `child_skipped` (clamped from depth 3 -> depth 1) is visible under it
	upon.rendering_frame(build_dyn_tree)
	then.tree_visible_count_is("dyn_tree", 2)

	// Collapse `branch_a` via `h` -> 1 visible row
	upon.pressing_key_rune('h')
	then.tree_visible_count_is("dyn_tree", 1)

	// Dynamically insert `inserted_top` at index 0 -> `branch_a` shifts to index 1,
	// and its collapsed state + selection follow `"branch_a"` by `id_hash`!
	prepend_filter_node = true
	upon.rendering_frame(build_dyn_tree)
	then.tree_node_expanded_is("dyn_tree", 1, false)
	then.tree_visible_count_is("dyn_tree", 2)
	then.tree_selection_is("dyn_tree", 1, 1)
}

@(test)
@(scenario)
spec_tree_collapse_clears_unicode_icon_rows_cleanly :: proc(t: ^testing.T) {
	_ = scenario(t, w = 44, h = 8)

	build_icon_tree :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		s := current_scenario()
		nodes := [?]bifrost.Tree_Node{
			{id = "root_pkg",  label = "bifrost/",        icon = "📦", depth = 0, expanded = true,  has_children = true},
			{id = "mod_input", label = "input.odin",      icon = "⌨",  depth = 1, expanded = false, has_children = false},
			{id = "mod_tabs",  label = "tabs.odin (T13)", icon = "🗂",  depth = 1, expanded = false, has_children = false},
			{id = "mod_sched", label = "scheduler.odin",  icon = "⚡", depth = 1, expanded = false, has_children = false},
		}
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_tree(ctx, scr, &s.input, "icon_tree", nodes[:], {
				width         = bifrost.grow(1),
				height        = bifrost.grow(1),
				border        = .Rounded,
				fg            = bifrost.rgb(216, 222, 233),
				bg            = bifrost.rgb(46, 52, 64),
				fallback_rows = 6,
			})
		}
	}

	// Frame 1: Expanded tree with mixed 1-col ('⌨', '🗂') and 2-col ('📦', '⚡') icons
	upon.rendering_frame(build_icon_tree)
	then.tree_visible_count_is("icon_tree", 4)
	then.vt_row_contains_text(2, "input.odin")
	then.vt_row_contains_text(3, "tabs.odin (T13)")
	then.vt_row_contains_text(4, "scheduler.odin")

	// Frame 2: Collapse root node via 'h' -> rows 2..4 must be completely wiped with spaces in the ANSI diff
	upon.pressing_key_rune('h')
	upon.rendering_frame(build_icon_tree)
	then.tree_visible_count_is("icon_tree", 1)
	then.vt_row_contains_text(2, "input.odin", false)
	then.vt_row_contains_text(3, "tabs.odin", false)
	then.vt_row_contains_text(4, "scheduler.odin", false)
	then.diff_ansi_contains("                    ")
}

@(test)
@(scenario)
spec_tree_smooth_scroll_padding_half_page_and_mouse_wheel_sync :: proc(t: ^testing.T) {
	_ = scenario(t, w = 50, h = 10) // inner_rect.h = 8 visible rows

	build_smooth_tree :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		s := current_scenario()
		nodes := make([]bifrost.Tree_Node, 20, context.temp_allocator)
		nodes[0] = bifrost.Tree_Node{
			id           = "root",
			label        = "root",
			depth        = 0,
			parent_idx   = -1,
			expanded     = true,
			has_children = true,
		}
		for i := 1; i < 20; i += 1 {
			nodes[i] = bifrost.Tree_Node{
				id           = fmt.aprintf("leaf_%02d", i, allocator = context.temp_allocator),
				label        = fmt.aprintf("leaf_%02d", i, allocator = context.temp_allocator),
				depth        = 1,
				parent_idx   = 0,
				expanded     = false,
				has_children = false,
			}
		}
		if bifrost.container(ctx, "root", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			bifrost.ui_tree(ctx, scr, &s.input, "smooth_tree", nodes, {
				title          = "Smooth Tree",
				width          = bifrost.grow(1),
				height         = bifrost.grow(1),
				border         = .Rounded,
				scroll_step    = 1,
				scroll_padding = 2,
				fallback_rows  = 8,
				focus_flags    = {.Loop_Spatial},
			})
		}
	}

	// Frame 0: 20 visible rows in an 8-row viewport with `scroll_padding = 2` (`pad = 2`).
	// Safe interior cursor window is `[offset + 2 .. offset + 5]`.
	upon.rendering_frame(build_smooth_tree)
	then.virtual_scroll_is("smooth_tree", 0, 0)
	then.tree_selection_is("smooth_tree", 0, 0)

	// Step down 6 times to vis_row 6 -> because `scroll_padding = 2`, viewport glides forward to `offset = 1`
	// while cursor is still 2 rows above the bottom border!
	for _ in 0 ..< 6 {
		upon.pressing_key_rune('j')
	}
	then.virtual_scroll_is("smooth_tree", 1, 6)
	then.tree_selection_is("smooth_tree", 6, 6)

	// Half-page down (`Ctrl+D`) advances by `viewport_rows / 2 = 4` rows (vis_row 6 -> 10, offset -> 5)
	upon.pressing_key_rune('d', {.Ctrl})
	then.virtual_scroll_is("smooth_tree", 5, 10)
	then.tree_selection_is("smooth_tree", 10, 10)

	// Half-page up (`Ctrl+U`) steps back by 4 rows (vis_row 10 -> 6, offset -> 4)
	upon.pressing_key_rune('u', {.Ctrl})
	then.virtual_scroll_is("smooth_tree", 4, 6)
	then.tree_selection_is("smooth_tree", 6, 6)

	// Mouse wheel scrolling down 5 ticks (`scroll_step = 1`) glides `offset` from 4 -> 9,
	// preserves `selected_row = 6`, and persists on the next `rendering_frame` without snapping back!
	upon.rendering_frame(build_smooth_tree)
	for _ in 0 ..< 5 {
		upon.mouse_scroll(5, 4, .Scroll_Down)
	}
	then.virtual_scroll_is("smooth_tree", 9, 6)
	then.tree_selection_is("smooth_tree", 6, 6)

	upon.rendering_frame(build_smooth_tree)
	then.virtual_scroll_is("smooth_tree", 9, 6)
	then.tree_selection_is("smooth_tree", 6, 6)

	// Vim `G` jumps to the last visible row (vis_row 19, offset 12)
	upon.pressing_key_rune('G')
	then.virtual_scroll_is("smooth_tree", 12, 19)
	then.tree_selection_is("smooth_tree", 19, 19)
}

@(test)
@(scenario)
spec_tree_default_p95_smart_width_accommodates_items_and_ignores_single_outlier :: proc(t: ^testing.T) {
	_ = scenario(t, w = 100, h = 12)

	build_auto_width_tree :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		s := current_scenario()
		nodes := make([]bifrost.Tree_Node, 20, context.temp_allocator)
		// Node 0: root branch (`"▾ root"` = 6 cells + 4 border/gutter = 10)
		nodes[0] = bifrost.Tree_Node{
			id           = "root",
			label        = "root",
			depth        = 0,
			parent_idx   = -1,
			expanded     = true,
			has_children = true,
		}
		// Nodes 1..18 (18 items -> 95% of 20 items = 19th rank):
		// depth=1 (`"├─ "` = 3) + icon (`"📄 "` = 3) + label (`"item_standard_len_20"` = 20) + border(2) + gutter(2) = 30 cells
		for i := 1; i < 19; i += 1 {
			nodes[i] = bifrost.Tree_Node{
				id         = fmt.aprintf("item_%02d", i, allocator = context.temp_allocator),
				label      = "item_standard_len_20",
				icon       = "📄",
				depth      = 1,
				parent_idx = 0,
			}
		}
		// Node 19 (1 outlier = top 5%): 70-char label that would blow out a naive max-width tree to 80+ cols!
		nodes[19] = bifrost.Tree_Node{
			id         = "outlier_19",
			label      = "outlier_extremely_long_path_that_should_not_blow_out_p95_default_width",
			icon       = "📄",
			depth      = 1,
			parent_idx = 0,
		}

		if bifrost.container(ctx, "root_row", {dir = .Row, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			// Omit `width` on `Tree_Config` -> defaults to p95 item width (`30` cols), NOT the single 80-col outlier!
			bifrost.ui_tree(ctx, scr, &s.input, "auto_tree", nodes, {
				title         = "Explorer",
				border        = .Rounded,
				fallback_rows = 10,
			})
			bifrost.leaf(ctx, "right_workspace", 10, 10, {
				width  = bifrost.grow(1),
				height = bifrost.grow(1),
				border = .Rounded,
			})
		}
	}

	upon.rendering_frame(build_auto_width_tree)
	// p95 of 20 items is the 19th item (`30` cols), leaving 70 cols for `right_workspace`!
	then.node_rect_is("auto_tree", {0, 0, 30, 12})
	then.node_rect_is("right_workspace", {30, 0, 70, 12})
}
