# Contextual Status Bars & Which-Key Overlay

**Source File:** [`bifrost/status_bars.odin`](../../bifrost/status_bars.odin)

Bifrost provides three self-populating contextual HUD components that inspect `Input_State` and `Layout_Context`:
1. **`ui_focus_breadcrumb_bar`:** Renders the live hierarchical focus chain (`Focus: root -> main_body -> col_doing -> card_2`) with automatic left-truncation (`… -> col_doing -> card_2`) when terminal width is narrow.
2. **`ui_key_hint_bar`:** Renders active mode badges (`[EDIT]`, `[RESIZE]`, `[COUNT: 5x]`, `[C-u: 4x]`, `[SUFFIX: 5x]`, `[CHORD: g…]`) and contextually active keybindings from the 3-tier scope hierarchy.
3. **`ui_which_key_overlay`:** Pops up a floating non-capturing card (`z_layer = 28`) in the bottom-right corner whenever a 2-step key chord prefix (`g`, `<Space>`, `<C-x>`) is pending.

---

## 1. Zero-Lag Post-Input Refresh (`refresh_dynamic_bars`)

Because `resolve_input` runs *after* `end_layout`, a naive immediate-mode status bar would display stale focus or mode state from the previous frame. Bifrost eliminates this lag by recording `Dynamic_Bar_Entry` descriptors on `Screen.dynamic_bars` during layout and re-evaluating their `Paint_Spec` inside `apply_input_highlights` (`refresh_dynamic_bars`) *after* `resolve_input` has completed.

As a result, pressing `Enter` to enter `[EDIT]` or `[RESIZE]` mode, typing a prefix key like `g` (`[CHORD: g…]`), or jumping focus across scopes updates `ui_focus_breadcrumb_bar` and `ui_key_hint_bar` on the **exact same frame** (0 frame lag).

---

## 2. Focus Breadcrumb Bar (`ui_focus_breadcrumb_bar`)

```odin
Breadcrumb_Bar_Config :: struct {
	width:     Axis_Size, // Defaults to grow(1)
	fg:        Color,     // Ancestor scope color
	bg:        Color,
	active_fg: Color,     // Bold highlight color for the focused tip widget
	sep_fg:    Color,     // Color for "Focus: " prefix and " -> " arrows
	prefix:    string,    // Defaults to "Focus: "
}

ui_focus_breadcrumb_bar :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	cfg: Breadcrumb_Bar_Config = {},
) -> i32
```

* Walks `inp.focus_node_path` from root to focused tip.
* If the full breadcrumb exceeds `inner_rect.w`, `build_breadcrumb_paint` left-truncates outer ancestors with `"… -> "` while preserving the innermost focused tip.

---

## 3. Contextual Key Hint Bar (`ui_key_hint_bar`)

```odin
Key_Hint_Bar_Config :: struct {
	width:    Axis_Size, // Defaults to grow(1)
	key_fg:   Color,     // Bold shortcut badge color
	desc_fg:  Color,     // Action description color
	sep_fg:   Color,     // " | " separator color
	bg:       Color,
	mode_fg:  Color,     // Foreground for [EDIT], [RESIZE], [COUNT] badges
	mode_bg:  Color,     // Background for mode badges
	chord_fg: Color,     // Foreground for [CHORD: <prefix>…] badge
	chord_bg: Color,     // Background for pending chord badge
	dim_fg:   Color,     // Foreground for .Disabled_Dimmed actions
}

ui_key_hint_bar :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string,
	cfg: Key_Hint_Bar_Config = {},
) -> i32
```

### Contextual Filtering & Grouping Rules
1. **3-Tier Priority & Shadowing:** Collects `Action_Spec`s in priority order:
   * Tier 1: `.Scope_Only` bindings matching scopes along `inp.focus_node_path` (innermost first, halting at `.Trap_Focus` modal shields) and matching any active transient scope `submode`.
   * Tier 2: `.Root_And_Scopes` bindings (suppressed when a `.Trap_Focus` modal is open).
   * Tier 3: `.Global_Always` bindings.
   * Lower-priority bindings whose primary chord is shadowed by an inner scope are automatically omitted.
2. **Edit-Mode Suppression:** When `inp.editing_id != 0`, single-key printable bindings without `.Allow_In_Text_Input` are automatically hidden from the hint bar and replaced by `[EDIT] Esc: Exit Edit` (for two-stage inputs) plus any `.Allow_In_Text_Input` shortcuts.
3. **Group Merging (`group`, `group_desc`, `compact`):** Actions sharing a `group` tag are merged into a single hint item (e.g., `H/L: Move Stage` or compact `hjkl: Move`).
4. **Availability States (`set_action_availability`):** Actions with `.Disabled_Dimmed` render dimmed (`{.Dim}`); actions with `.Hidden` are omitted completely.
5. **Graceful Right-Truncation:** Fits as many complete `Key: Desc` items as possible inside `inner_rect.w` and appends `" | …"` if additional hints exist.

---

## 4. Floating Which-Key Overlay (`ui_which_key_overlay`)

When the user presses the first key of a 2-step chord (such as `g` in `g g` / `g e`, `<Space>` in Helix mode, or `<C-x>` in Emacs mode), `inp.pending_chord.active` latches `true`. Calling `ui_which_key_overlay` near the end of your layout pass mounts a floating rounded card at `z_layer = 28` anchored to the bottom-right of the screen listing every valid second key and its description, plus `Esc  Cancel`.

```odin
Which_Key_Config :: struct {
	title:     string, // Defaults to " Prefix: <key>… "
	z_layer:   u8,     // Defaults to 28
	width:     i32,    // Defaults to 38
	bg:        Color,
	border_fg: Color,
	key_fg:    Color,
	desc_fg:   Color,
}

ui_which_key_overlay :: proc(
	ctx: ^Layout_Context,
	s: ^Screen,
	inp: ^Input_State,
	id: string = "__which_key_overlay__",
	cfg: Which_Key_Config = {},
) -> bool
```

### Example: Mounting All Three Contextual Helpers
```odin
package demo

import "../../bifrost"

render_hud_chrome :: proc(
	ctx: ^bifrost.Layout_Context,
	scr: ^bifrost.Screen,
	inp: ^bifrost.Input_State,
) {
	// At the bottom of your root Column container:
	bifrost.ui_focus_breadcrumb_bar(ctx, scr, inp, "breadcrumb_bar")
	bifrost.ui_key_hint_bar(ctx, scr, inp, "hint_bar")

	// Before end_layout(ctx):
	bifrost.ui_which_key_overlay(ctx, scr, inp)
}
```