# Focus-Scope-Integrated Tab Bar & Container (`ui_tabs` / `ui_tab_bar`)

**Source File:** [`bifrost/tabs.odin`](../../bifrost/tabs.odin)

`ui_tabs` and `ui_tab_bar` provide a declarative horizontal tab bar and scoped tab container deeply integrated with Bifrost's Harel statechart Shallow ($H$) and Deep ($H^*$) focus history (`Scope_Memory_Entry`).

---

## 1. Configuration & Specs (`Tab_Item_Spec`, `Tabs_Config`)

`Input_State` manages up to `MAX_TABS_SLOTS` ($16$) tab bars with up to `MAX_TAB_ITEMS` ($16$) tabs each.

```odin
Tab_Item_Spec :: struct {
	label:    string, // Tab title text
	badge:    string, // Optional count/status badge rendered as " (badge)"
	key_hint: string, // Optional prefix hint (e.g. "1:" or "Alt+1")
	disabled: bool,   // Dims the tab and skips it during [ / ] and h / l stepping
}

Tabs_Config :: struct {
	default_tab:      int,
	width:            Axis_Size,   // Defaults to grow(1)
	height:           Axis_Size,   // Defaults to grow(1)
	body_dir:         Direction,   // Defaults to .Column (set body_row = true for .Row)
	body_row:         bool,
	body_padding:     Padding,
	body_gap:         i32,
	body_border:      Border_Kind,
	header_border:    Border_Kind,
	fg:               Color,
	bg:               Color,
	header_bg:        Color,
	active_fg:        Color,
	active_bg:        Color,
	inactive_fg:      Color,
	inactive_bg:      Color,
	badge_fg:         Color,
	sep_fg:           Color,
	border_fg:        Color,
	title_fg:         Color,
	title:            string,      // Optional border title on the active tab body container
	show_index_hints: bool,        // Automatically prefixes tabs 1..9 with "1:", "2:", ...
	no_wrap:          bool,        // Disables ring wrap on [ / ] and header h / l
	focus_flags:      Focus_Flags,
	body_focus_flags: Focus_Flags,
	state:            ^Tabs_State, // Optional caller-owned state struct
}
```

---

## 2. Deep History ($H^*$) Focus Restoration Invariants

1. **Per-Tab Body Scope Isolation (`<id>_body_<i>`):**
   * `ui_tabs` wraps the header bar (`<id>_header`) and the active tab body (`<id>_body_<active>`) inside an outer `Focus_Scope` (`<id>`).
   * Each tab index $i \in [0, \text{tab\_count})$ has a distinct body scope hash `tab_body_scope_hash(id, i)`.
   * As the user navigates between widgets inside Tab $i$, `set_focused_node` updates the `Scope_Memory_Entry` for `<id>_body_<i>` with the exact focused leaf (`last_leaf_hash`).
2. **Automatic $H^*$ Restoration on Tab Switch:**
   * Switching from Tab $i$ to Tab $j$ (via `[` / `]`, `Alt+1..9`, mouse click on `<id>_tab_<j>`, or pressing `Down`/`Enter` on the tab header) sets `inp.wants_focus_id = body_scope_hash[j]`.
   * When the new tab's widgets mount on the subsequent layout pass, `reconcile_focus` resolves `<id>_body_<j>` via `resolve_scope_target(..., use_history = true)`, restoring focus to the exact widget the user was last interacting with in Tab $j$!
3. **Outer Scope Shallow History ($H$) Synchronization:**
   * `begin_ui_tabs_internal` keeps the outer `<id>` scope's `last_child_hash` pointed at the active tab's body scope (`<id>_body_<active>`) whenever focus is not directly on the tab header bar. Pressing `F6` to cycle into `ui_tabs` from another pane therefore lands directly inside the active tab body's $H^*$ leaf rather than stopping on the tab header bar.

---

## 3. Keyboard & Mouse Bindings

| Context | Key / Event | Action |
| :--- | :--- | :--- |
| Anywhere inside `ui_tabs` (when `editing_id == 0`) | `[` / `]` | Step to previous / next enabled tab (supports repeat counts) and restore target tab's $H^*$ body focus |
| Anywhere inside `ui_tabs` (when `editing_id == 0`) | `Alt+1` .. `Alt+9` | Jump directly to tab $0..8$ (if enabled) and restore its $H^*$ body focus |
| Focused on `<id>_header` or `<id>_tab_<i>` | `h` / `l`, `Left` / `Right` | Step active tab left / right while keeping focus on the tab header pill |
| Focused on `<id>_header` or `<id>_tab_<i>` | `j` / `Down`, `Enter`, `Space` | Enter the active tab body scope (`<id>_body_<active>`) and restore its $H^*$ leaf |
| Unoccluded mouse click | `Left Click` on `<id>_tab_<i>` | Switch to tab $i$ (if enabled) and restore its $H^*$ body focus |

---

## 4. Public API & Example

### Procedures
* `ui_tabs(ctx: ^Layout_Context, s: ^Screen, inp: ^Input_State, id: string, items_or_labels, cfg: Tabs_Config = {}, out_active_tab: ^int = nil) -> bool` (`@(deferred_in)` scoped container)
* `ui_tab_bar(ctx: ^Layout_Context, s: ^Screen, inp: ^Input_State, id: string, items_or_labels, cfg: Tabs_Config = {}) -> int` (standalone 1-row or 3-row header bar)
* `get_active_tab(inp: ^Input_State, id: string) -> int`
* `set_active_tab(inp: ^Input_State, id: string, tab_idx: int, restore_body_focus: bool = true)`
* `was_tab_changed(inp: ^Input_State, id: string) -> bool`
* `tab_header_id(id: string, index: int, alloc := context.temp_allocator) -> string`
* `tab_body_scope_id(id: string, index: int, alloc := context.temp_allocator) -> string`

### Example: Multi-Tab Workspace with $H^*$ Memory
```odin
package demo

import "../../bifrost"

render_tabbed_workspace :: proc(
	ctx: ^bifrost.Layout_Context,
	scr: ^bifrost.Screen,
	inp: ^bifrost.Input_State,
) {
	specs := [?]bifrost.Tab_Item_Spec{
		{label = "Code",      badge = "Odin"},
		{label = "Telemetry", badge = "LIVE"},
		{label = "Inspector", badge = "3"},
		{label = "Archive",   disabled = true},
	}

	active_tab := 0
	if bifrost.ui_tabs(ctx, scr, inp, "main_tabs", specs[:], {
		body_border      = .Rounded,
		body_padding     = bifrost.pad_xy(1, 0),
		show_index_hints = true,
	}, &active_tab) {
		switch active_tab {
		case 0:
			bifrost.ui_text_area(ctx, scr, inp, "code_editor", {
				two_stage         = true,
				show_line_numbers = true,
				syntax_mode       = .Odin,
				focus_flags       = {.Default_Focus},
			})
		case 1:
			bifrost.ui_button(ctx, scr, "btn_pulse", {
				label       = "Pulse Wave",
				focus_flags = {.Default_Focus},
			})
		case 2:
			bifrost.ui_button(ctx, scr, "btn_a", {label = "Action A", focus_flags = {.Default_Focus}})
			bifrost.ui_button(ctx, scr, "btn_b", {label = "Action B"})
		}
	}
}
```