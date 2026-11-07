# Interactive Pane Splitter (`ui_splitter`)

**Source File:** [`bifrost/splitter.odin`](../../bifrost/splitter.odin)

`ui_splitter` is a 1-cell interactive divider placed between two panes in a `.Row` (vertical divider `│`/`┃`/`║`) or `.Column` (horizontal divider `─`/`━`/`═`) container. It supports mouse drag resizing, middle-click reset, keyboard shortcuts (`bind_splitter_key`), a two-stage `[RESIZE]` sub-mode, and **same-frame sibling rect reflow** (`apply_splitter_size_immediate`).

---

## 1. Configuration & State Slot (`Splitter_Config`, `Splitter_Slot`)

`Input_State` manages up to `MAX_SPLITTER_SLOTS` (16) splitters, which can also be persisted to `xitdb` via `save_ui_workspace_to_xitdb`.

```odin
Splitter_Submode :: enum u8 {
	Navigate = 0, // Default spatial-passthrough focus state (Enter enters Resize)
	Resize   = 1, // Active keyboard resize sub-mode (h/j/k/l or Arrows resize, = resets, Enter/Esc exits)
}

Splitter_Config :: struct {
	dir:          Direction, // Parent container axis: .Row (resizes width) or .Column (resizes height)
	default_size: i32,       // Default first-pane size in cells (default 24)
	min_size:     i32,       // Alias for min_first
	max_size:     i32,       // Optional explicit maximum first-pane size
	min_first:    i32,       // Minimum size of preceding pane (default 8)
	min_second:   i32,       // Minimum size of following pane (default 8)
	step:         i32,       // Cells per keyboard nudge step (default 2)
	fg:           Color,
	bg:           Color,
	active_fg:    Color,     // Highlight color when focused or resizing (default gold)
}
```

### Visual States (`sync_splitter_paint`)
* **Idle:** `│` (for `.Row`) or `─` (for `.Column`) in `cfg.fg`.
* **Hovered or Focused (`.Navigate` sub-mode):** Heavy line `┃` or `━` in bold `active_fg`.
* **Active `[RESIZE]` Sub-Mode (`Splitter_Submode.Resize`):** Double line `║` or `═` in bold reverse `active_fg`, with `[RESIZE]` badge displayed in `ui_key_hint_bar`.

---

## 2. Keyboard & Mouse Interaction

| Context | Key / Event | Action |
| :--- | :--- | :--- |
| Focused in `.Navigate` sub-mode | `h` / `j` / `k` / `l` or Arrows | Passes through via 2D spatial navigation to adjacent panes |
| Focused in `.Navigate` sub-mode | `Enter` | Enters `Splitter_Submode.Resize` (`[RESIZE]`) |
| Focused in `.Resize` sub-mode | `h` / `l`, `Left` / `Right`, `C-b` / `C-f` (on `.Row`) | Resizes preceding pane width by `±(step × repeat_count)` (supports Vim `3l`, Helix `l3`, Emacs `C-u`) |
| Focused in `.Resize` sub-mode | `k` / `j`, `Up` / `Down`, `C-p` / `C-n` (on `.Column`) | Resizes preceding pane height by `±(step × repeat_count)` |
| Focused in `.Resize` sub-mode | `=`, `0`, or `Home` | Resets splitter to `default_size` |
| Focused in `.Resize` sub-mode | `Enter`, `Escape`, or `Ctrl+G` (Emacs) | Exits `[RESIZE]` sub-mode back to `.Navigate` (blurring the splitter also auto-exits `.Resize`) |
| Mouse over splitter | `Left Press + Drag` | Continuously resizes the split to match cursor position within `[min_first, max_first]` |
| Mouse over splitter | `Middle Click` | Resets splitter to `default_size` |

---

## 3. Public API & Split-Pane Pattern

### Procedures
* `get_split_size(inp: ^Input_State, id: string, default_size: i32 = 24, min_size: i32 = 8, max_size: i32 = 0) -> i32`
* `ui_splitter(ctx: ^Layout_Context, s: ^Screen, inp: ^Input_State, id: string, cfg: Splitter_Config = {}) -> i32`
* `nudge_splitter(inp: ^Input_State, ctx: ^Layout_Context, id: string, delta: i32)`
* `bind_splitter_key(inp: ^Input_State, key: Key_Event, splitter_id: string, delta: i32, action_name: string = "", policy: Key_Scope_Policy = .Root_And_Scopes, scope_id: string = "", flags: Keybinding_Flags = {.Allow_In_Text_Input})`

### Example: Resizable Sidebar & Main Workspace
Query `get_split_size` for the first pane's `fixed(split_w)` dimension, mount `ui_splitter` immediately after the first pane, and set the second pane to `grow(1)`. When the splitter moves during `resolve_input`, `apply_splitter_size_immediate` updates the preceding pane, splitter, and following pane rects and clip masks on the **exact same frame**:

```odin
package demo

import "../../bifrost"

render_split_workspace :: proc(
	ctx: ^bifrost.Layout_Context,
	scr: ^bifrost.Screen,
	inp: ^bifrost.Input_State,
) {
	if bifrost.ui_scope(ctx, scr, "body_row", {
		dir    = .Row,
		width  = bifrost.grow(1),
		height = bifrost.grow(1),
	}) {
		// 1. Query clamped split width for the left pane
		left_w := bifrost.get_split_size(inp, "main_split", 28, 16, 60)

		if bifrost.ui_scope(ctx, scr, "sidebar_pane", {
			dir    = .Column,
			width  = bifrost.fixed(left_w),
			height = bifrost.grow(1),
			border = .Rounded,
			title  = "Sidebar",
		}) {
			bifrost.ui_button(ctx, scr, "nav_btn", {label = "Explorer"})
		}

		// 2. Mount the 1-cell interactive vertical splitter
		bifrost.ui_splitter(ctx, scr, inp, "main_split", {
			dir          = .Row,
			default_size = 28,
			min_first    = 16,
			min_second   = 24,
			step         = 2,
		})

		// 3. Right pane grows to fill remaining width
		if bifrost.ui_scope(ctx, scr, "editor_pane", {
			dir    = .Column,
			width  = bifrost.grow(1),
			height = bifrost.grow(1),
			border = .Rounded,
			title  = "Main Editor",
		}) {
			bifrost.ui_text_area(ctx, scr, inp, "main_editor", {two_stage = true})
		}
	}
}
```