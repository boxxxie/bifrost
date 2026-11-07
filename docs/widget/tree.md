# Virtualized Collapsible Tree (`ui_tree`)

**Source File:** [`bifrost/tree.odin`](../../bifrost/tree.odin)

`ui_tree` renders hierarchical data structures (file explorers, AST inspectors, configuration outlines) with automatic box-drawing indentation guides (`│  `, `   `, `├─ `, `╰─ `, `▾ `, `▸ `), keyboard and mouse expand/collapse, parent-node jump navigation, and **O(visible_rows) layout node materialization** capable of handling 10,000+ nodes with zero heap allocations outside the frame arena.

---

## 1. Data Structures (`Tree_Node`, `Tree_Config`, `Tree_Slice`)

Callers pass a flat pre-order slice `[]Tree_Node`. Relationships can be specified either by 0-based `depth` (`0, 1, 2, ...`) or by explicit `parent_idx` (`-1` for root nodes):

```odin
Tree_Node :: struct {
	id:           string,      // Optional explicit string ID (recommended for dynamic trees)
	id_hash:      u64,         // Optional precomputed FNV-1a ID hash
	label:        string,      // Primary visible label text
	icon:         string,      // Optional icon/badge rendered after ▾/▸ (e.g. "📂", "📐")
	depth:        i32,         // 0-based nesting depth
	parent_idx:   i32,         // Optional explicit parent index (-1 for roots)
	expanded:     bool,        // Initial expand/collapse state on first mount
	has_children: bool,        // Explicit branch flag (also inferred if followed by deeper nodes)
	fg:           Color,
	bg:           Color,
	guide_fg:     Color,
	icon_fg:      Color,
	style:        Style_Flags,
	userdata:     rawptr,
}

Tree_Config :: struct {
	title:            string,
	width:            Axis_Size,   // Defaults to smart p95 content width when nil (or grow(1) when width_percentile < 0)
	height:           Axis_Size,   // Defaults to grow(1)
	border:           Border_Kind,
	fg:               Color,
	bg:               Color,
	border_fg:        Color,
	title_fg:         Color,
	guide_fg:         Color,       // Color for │, ├─, ╰─ connectors
	toggle_fg:        Color,       // Color for ▾ / ▸ branch indicators
	sel_fg:           Color,       // Highlighted selected row foreground
	sel_bg:           Color,       // Highlighted selected row background
	leaf_prefix:      string,      // Optional prefix for leaf nodes (e.g. "  " or "• ")
	scroll_step:      i32,
	scroll_padding:   i32,
	fallback_rows:    i32,
	width_percentile: i32,         // Target item-width percentile (1..100, default 95 when 0; < 0 disables auto p95 sizing)
	min_auto_width:   i32,         // Minimum auto-computed outer box width in cells (defaults to 20)
	max_auto_width:   i32,         // Maximum auto-computed outer box width in cells (defaults to 56 when 0)
	focus_flags:      Focus_Flags,
}

Tree_Slice :: struct {
	start_row:          i32, // Inclusive start index into flattened visible rows
	end_row:            i32, // Exclusive end index into flattened visible rows
	selected_vis_row:   i32, // Currently highlighted visible row index
	selected_node_idx:  i32, // Index into `nodes` slice for the selected row (-1 if empty)
	activated_node_idx: i32, // Index into `nodes` if a leaf node was activated this frame (-1 if none)
	scroll_offset:      i32,
	viewport_rows:      i32,
	total_visible_rows: i32,
	total_nodes:        i32,
	recommended_width:  i32, // Auto-computed p95 outer box width (including borders + scrollbar gutter)
}
```

---

## 2. Architectural Invariants

1. **O(visible_rows) Layout Node Budget:**
   * `ui_tree` resolves `parent_idx`, `first_child`, `next_sibling`, and `has_children` in a single linear pre-order pass over `nodes`, builds `vis_to_node` skipping descendants of collapsed branches, and pushes `Layout_Node`s **only** for `[start_row ..< end_row]`.
2. **`id_hash`-Persistent Expand/Collapse & Selection State:**
   * Each `Tree_Slot` (`MAX_TREE_SLOTS = 8`) stores an inline open-addressed hash table (`hash_keys: [512]u64`, `hash_expanded: [8]u64`) alongside a 16,384-node bitset (`expanded_bits: [256]u64`) and `selected_node_hash`. Inserting or filtering nodes above a branch preserves both its expanded/collapsed state and the active selection across frames.
3. **Collapse-Safe Ancestor Reconciliation:**
   * If a branch is collapsed programmatically while one of its descendants is selected, `rebuild_tree_visible_rows` walks up `parent_idx` to snap selection to the nearest visible ancestor.

---

## 3. Keyboard & Mouse Bindings

| Key / Event | Action |
| :--- | :--- |
| `j` / `Down`, `k` / `Up`, `Ctrl+N` / `Ctrl+P` | Step selection through visible rows (supports Vim `5j`, Helix `j5`, and Emacs `C-u` repeat counts, plus lookahead `scroll_padding` / `scrolloff`) |
| `Ctrl+D` / `Ctrl+U` (Vim/Helix) | Half-page scroll down / up (`max(1, viewport_rows / 2)`) while keeping selection synchronized |
| `Page_Up` / `Page_Down`, `Home` / `End`, `G` | Page by `max(1, viewport_rows - 1)` or jump to first / last visible row |
| `l` / `Right`, `Ctrl+F` (Emacs) | **On collapsed branch:** expand in-place (`▸` → `▾`). **On expanded branch:** step into `first_child`. **On leaf:** bubbles out to right sibling pane (unless `.Strict_Spatial` is set). |
| `h` / `Left`, `Ctrl+B` (Emacs) | **On expanded branch:** collapse in-place (`▾` → `▸`). **On collapsed branch or leaf with `parent_idx >= 0`:** jump directly to parent node and auto-scroll viewport. **At root (`depth == 0`) collapsed/leaf:** bubbles out to left sibling pane. |
| `Space` | Toggle expand/collapse on a branch node, or activate a leaf node |
| `Enter` | Toggle expand/collapse on a branch node, or fire `activated_node_idx` (`get_tree_activated_node`) on a leaf node |
| `Mouse Left Click` | Focus tree, select clicked visible row, and toggle branch or activate leaf |
| `Mouse Wheel Up / Down` | Scroll visible rows vertically |

---

## 4. Public API & Example

### Procedures
* `ui_tree(ctx: ^Layout_Context, s: ^Screen, inp: ^Input_State, id: string, nodes: []Tree_Node, cfg: Tree_Config = {}, out_slice: ^Tree_Slice = nil) -> i32`
* `get_tree_selected_node(inp: ^Input_State, id: string) -> i32`
* `get_tree_selected_vis_row(inp: ^Input_State, id: string) -> i32`
* `get_tree_activated_node(inp: ^Input_State, id: string) -> i32`
* `get_tree_visible_row_count(inp: ^Input_State, id: string) -> i32`
* `get_tree_recommended_width(inp: ^Input_State, id: string) -> i32`
* `compute_tree_auto_width(nodes: []Tree_Node, border: Border_Kind = .Rounded, leaf_prefix: string = "", percentile: i32 = 95, min_width: i32 = 20, max_width: i32 = 56) -> i32`
* `is_tree_node_expanded(inp: ^Input_State, id: string, node_idx: i32) -> bool`
* `set_tree_node_expanded(inp: ^Input_State, id: string, node_idx: i32, expanded: bool)`
* `format_tree_guide_prefix(meta: []Tree_Node_Meta, node_idx: i32, allocator := context.temp_allocator) -> string`

### Example: Collapsible File Explorer
```odin
package demo

import "../../bifrost"

@(rodata)
PROJECT_NODES := [6]bifrost.Tree_Node{
	{id = "root",   label = "bifrost/",       icon = "📦", depth = 0, expanded = true,  has_children = true},
	{id = "core",   label = "core/",          icon = "📂", depth = 1, expanded = true,  has_children = true},
	{id = "layout", label = "layout.odin",    icon = "📐", depth = 2},
	{id = "render", label = "renderer.odin",  icon = "🎨", depth = 2},
	{id = "tests",  label = "tests/",         icon = "🧪", depth = 1, expanded = false, has_children = true},
	{id = "spec1",  label = "spec_tree.odin", icon = "✓",  depth = 2},
}

render_explorer :: proc(
	ctx: ^bifrost.Layout_Context,
	scr: ^bifrost.Screen,
	inp: ^bifrost.Input_State,
) {
	slice: bifrost.Tree_Slice
	nodes := PROJECT_NODES
	bifrost.ui_tree(ctx, scr, inp, "explorer_tree", nodes[:], {
		title         = "Project Files",
		width         = bifrost.fixed(32),
		height        = bifrost.grow(1),
		border        = .Rounded,
		fallback_rows = 16,
		focus_flags   = {.Focusable, .Default_Focus},
	}, &slice)

	if act_idx := bifrost.get_tree_activated_node(inp, "explorer_tree"); act_idx >= 0 {
		opened_file := nodes[act_idx].label
		_ = opened_file
	}
}
```