# Layout Primitives, Focus Scopes, Buttons & Modals

**Source Files:** [`bifrost/layout.odin`](../../bifrost/layout.odin), [`bifrost/focus_scope.odin`](../../bifrost/focus_scope.odin), [`bifrost/renderer.odin`](../../bifrost/renderer.odin), [`bifrost/input.odin`](../../bifrost/input.odin)

Bifrost's foundational building blocks construct the topological layout tree, define hierarchical Harel focus scopes (`ui_scope`), render styled text (`ui_label`), handle button activations (`ui_button`), and mount z-layered modal overlays (`ui_modal`) with 50% RGB backdrop dimming.

---

## 1. Sizing & Geometry Helpers (`layout.odin`)

Every container and widget accepts `Axis_Size` values for `width` and `height`:

| Helper | Type | Behavior |
| :--- | :--- | :--- |
| `fit(min = 0, max = 0)` | `Fit` | Shrink-wraps to children or text intrinsic width/height, clamped to `[min, max]`. Default when `Axis_Size` is `nil`. |
| `grow(weight = 1, min = 0, max = 0)` | `Grow` | Expands to fill remaining space in parent container (water-filling when weights are equal; proportional weighted flex with `min`/`max` freeze clamping otherwise). |
| `fixed(cells: i32)` | `Fixed` | Exact size in terminal character cells. |
| `percent(fraction: f32, min = 0, max = 0)` | `Percent` | Fraction (`0.0 ..= 1.0` or `0 ..= 100.0`) of parent inner available size minus gaps. |
| `pad_all(p: i32)` / `pad_xy(x, y: i32)` | `Padding` | Uniform or horizontal/vertical interior padding. |
| `nav_target(dir: Nav_Dir, target_id: string)` | `[Nav_Dir]u64` | Explicit 2D directional focus override portal on `Box_Config` or `Scope_Config`. |

### Zero-Allocation Local ID Hashing
Inside loops or dynamic scopes, avoid `fmt.tprintf` allocations by combining `current_scope_hash(ctx)` with `hash_local_id` or `hash_local_idi`:

```odin
scope_h := bifrost.current_scope_hash(ctx)
item_h  := bifrost.hash_local_idi(scope_h, "card", i32(index))
bifrost.leaf(ctx, "", 16, 1, {
	id_hash     = item_h,
	width       = bifrost.grow(1),
	height      = bifrost.fixed(1),
	focus_flags = {.Focusable},
})
```

---

## 2. Containers & Focus Scopes (`container`, `leaf`, `ui_scope`)

### `container` & `leaf`
`container` is a `@(deferred_in = defer_end_container)` scoped block that pushes a parent `Layout_Node` and automatically pops it when the `if` block exits. `leaf` pushes a terminal widget node with intrinsic `content_w` and `content_h`.

```odin
if bifrost.container(ctx, "toolbar", {
	dir         = .Row,
	width       = bifrost.grow(1),
	height      = bifrost.fixed(3),
	padding     = bifrost.pad_xy(1, 0),
	gap         = 2,
	border      = .Rounded,
	cross_align = .Center,
}) {
	bifrost.leaf(ctx, "status_badge", 10, 1, {
		width  = bifrost.fixed(10),
		height = bifrost.fixed(1),
		text   = "ONLINE",
	})
}
```

### `ui_scope` (`Scope_Config`)
`ui_scope` is a `@(deferred_in = defer_end_ui_scope)` container builder that automatically sets `.Focus_Scope`, registers border/title/background `Paint_Spec` on `Screen`, and establishes an OR-state in Bifrost's focus scope tree with Shallow (H) and Deep (H*) focus memory (`Scope_Memory_Entry`).

```odin
Scope_Config :: struct {
	dir:           Direction,
	width:         Axis_Size,
	height:        Axis_Size,
	padding:       Padding,
	gap:           i32,
	border:        Border_Kind,      // .None, .Plain, .Rounded, .Double
	main_align:    Alignment,        // .Start, .Center, .End
	cross_align:   Alignment,
	self_align:    [2]Alignment,
	z_layer:       u8,
	floating:      bool,
	anchor:        Anchor_Mode,      // .Screen, .Parent
	offset:        [2]i32,
	scrollable:    bool,
	scroll_step:   i32,
	clickable:     bool,
	hoverable:     bool,
	focus_flags:   Focus_Flags,
	nav_overrides: [Nav_Dir]u64,
	title:         string,
	fg:            Color,
	bg:            Color,
	border_fg:     Color,
	title_fg:      Color,
	fill_bg:       bool,
}
```

#### Focus Scope Navigation & Drill-Down / Drill-Up Rules
* **Scope Ring Cycling (`F6` / `Shift+F6` / `Ctrl+Tab`):** Cycles between sibling `ui_scope` containers and restores the target scope's remembered H* leaf.
* **Drill-Up (`Escape`) & Drill-Down (`Enter`):** If a `ui_scope` includes `.Focusable` in its `focus_flags` (e.g., a Kanban column), pressing `Escape` from a child card drills focus up to the column container itself; pressing `Enter` on the focused column drills back down into its remembered H* card.
* **Non-Modal Floating Window MRU Promotion:** Focusing any widget inside a non-modal floating `ui_scope` (`floating = true`, without `.Trap_Focus`) automatically promotes that floating scope to the front of its `effective_z` tier (`promote_floating_scope`).

---

## 3. Labels & Styled Spans (`ui_label`, `set_paint`)

`ui_label` creates a leaf node measured by `string_display_width(text)` (accounting for 0-width combining marks and 2-column CJK/Emoji graphemes) and assigns its `Paint_Spec`:

```odin
ui_label :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	id: string,
	text: string,
	fg: Color = {},
	style: Style_Flags = {},
	cfg: Box_Config = {},
) -> i32
```

For multi-color inline text on a single node, pass `spans: []Styled_Span` to `set_paint`:

```odin
spans := make([]bifrost.Styled_Span, 2, context.temp_allocator)
spans[0] = {text = "Status: ", fg = bifrost.rgb(150, 160, 180)}
spans[1] = {text = "HEALTHY",  fg = bifrost.rgb(120, 240, 160), style = {.Bold}}

bifrost.leaf(ctx, "status_line", 15, 1, {width = bifrost.grow(1), height = bifrost.fixed(1)})
bifrost.set_paint(scr, "status_line", {spans = spans})
```

---

## 4. Interactive Buttons (`ui_button`)

`ui_button` mounts a focusable, clickable, hoverable leaf widget centered along both axes and checks activation via `was_activated(inp, id)`.

```odin
Button_Spec :: struct {
	label:       string,
	width:       Axis_Size,   // Defaults to fit(min = display_width(label) + 4)
	height:      Axis_Size,   // Defaults to fit(min = 1)
	border:      Border_Kind,
	fg:          Color,
	bg:          Color,
	hover_bg:    Color,
	focus_fg:    Color,
	focus_bg:    Color,
	focus_flags: Focus_Flags, // Pass {.Disabled} to dim and skip focus/click routing
}
```

### Button Activation & Coordinator Binding
* **Keyboard:** Pressing `Enter` or `Space` while focused sets `inp.activated_id = hash_id(id)`.
* **Mouse:** Left mouse press + release inside the button's clipped bounds sets both `inp.activated_id` and `inp.clicked_id` (releasing outside the button cancels the click).
* **Coordinator Action Bridge:** When using `UI_Coordinator_State`, call `bind_button_action(coord, "btn_save", "doc.save")` to automatically trigger a named keymap/actor action whenever the button is activated.

```odin
bifrost.ui_button(ctx, scr, "btn_deploy", {
	label       = "Deploy Snapshot",
	width       = bifrost.fixed(20),
	height      = bifrost.fixed(1),
	fg          = bifrost.rgb(235, 240, 250),
	bg          = bifrost.rgb(45, 65, 95),
	focus_flags = {.Default_Focus},
})

if bifrost.was_activated(inp, "btn_deploy") {
	// Handle button press or click
}
```

---

## 5. Z-Layered Modals & Backdrop Dimming (`ui_modal`)

`ui_modal` is a `@(deferred_in = defer_end_modal)` floating container centered on screen with `.Focus_Scope` + `.Trap_Focus` (`capture_input = true`) and automatic 50% RGB backdrop dimming.

```odin
Modal_Spec :: struct {
	title:       string,
	z_layer:     u8,            // Defaults to 20 if 0
	width:       Axis_Size,     // Defaults to fit(min = 30)
	height:      Axis_Size,     // Defaults to fit()
	padding:     Padding,
	gap:         i32,
	border:      Border_Kind,   // Defaults to .Double if .None
	fg:          Color,
	bg:          Color,
	border_fg:   Color,
	title_fg:    Color,
	backdrop:    Backdrop_Mode, // .Dim_Screen (default), .Dim_Rect, or .None
	focus_flags: Focus_Flags,
}
```

### Modal Shield & LIFO Focus Restoration Invariants
1. **Input Shielding (`active_shield_z`):** While a modal is mounted, keyboard navigation (`Tab`, `F6`, `h/j/k/l`), `.Scope_Only` / `.Root_And_Scopes` keybindings, and mouse hit-testing are strictly confined to the topmost `effective_z` capturing modal.
2. **LIFO Focus Stack (`focus_history`):** Mounting a modal pushes the previously focused background widget onto `inp.focus_history` (up to `MAX_FOCUS_HISTORY = 8` nested modals). Unmounting the modal pops `focus_history` and restores focus to the exact prior widget.
3. **Dismissal Detection (`was_modal_dismissed`):** Pressing `Escape` inside the modal (when not in two-stage text edit mode) sets `inp.escape_modal_id`, and clicking outside the modal's bounds sets `inp.backdrop_clicked_id`. Query both with `was_modal_dismissed(inp, "modal_id")`.

```odin
if app.confirm_open {
	if bifrost.ui_modal(ctx, scr, "confirm_modal", {
		title     = "Confirm Reset",
		z_layer   = 25,
		width     = bifrost.fixed(44),
		height    = bifrost.fixed(7),
		padding   = bifrost.pad_xy(2, 1),
		gap       = 1,
		border    = .Double,
		backdrop  = .Dim_Screen,
	}) {
		bifrost.ui_label(ctx, scr, "msg", "Revert all uncommitted changes?")
		bifrost.ui_button(ctx, scr, "btn_ok", {
			label       = "Confirm (Enter)",
			focus_flags = {.Default_Focus},
		})
	}

	if bifrost.was_modal_dismissed(inp, "confirm_modal") {
		app.confirm_open = false
	}
}
```