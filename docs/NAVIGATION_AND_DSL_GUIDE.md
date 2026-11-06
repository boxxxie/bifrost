# Bifrost v0.2.0 Navigation, Focus Scopes & Key-Chord DSL Guide

This reference guide covers Bifrost's embedded statechart focus model, 2D spatial navigation, two-stage vs. `.Scope_Text_Sink` inputs, multi-style keymaps (`Vim`, `Helix`, `Emacs`), compile-time AST action codegen (`tools/bifrost_gen`), 2D virtualized tables, and `sleipnir` + `xitdb` coordinator routing.

---

## 1. Architecture Overview: Embedded Statechart Invariants

Bifrost embeds Harel statechart invariants directly into the immediate-mode layout and input pipeline so applications never maintain a parallel state tree alongside dynamic widgets:

* **OR-States & Hierarchy (`ui_scope`):** Nested `.Focus_Scope` containers build an explicit scope tree (`parent_scope_idx`, `subtree_end_idx`) during `begin_layout` .. `end_layout`.
* **Shallow ($H$) & Deep ($H^*$) History (`Scope_Memory_Entry`):** Fixed-capacity LRU memory on `Input_State` records `last_child_hash` and `last_leaf_hash` per scope, halting upward writes at `.Trap_Focus` boundaries.
* **Bottom-Up Event Bubbling (`focus_node_path`):** Key events walk from the focused tip up through enclosing scopes to the root (`0`), halting at the topmost `effective_z` `.Trap_Focus` modal.
* **Orthogonal Text Delegation (`.Scope_Text_Sink`):** A search bar captures printable runes and horizontal caret motion while sibling list items simultaneously hold focus for vertical navigation and `Enter` activation.
* **Transient Widget Sub-Modes (`scope_submodes`):** Scopes and widgets (such as `ui_splitter`) switch between `.Navigate` and `.Resize` sub-modes without global boolean flags.

---

## 2. Focus Flags & Scope Resolution Matrix

Combine `Focus_Flags` on `Box_Config`, `Scope_Config`, `Button_Spec`, `Text_Input_Config`, `Virtual_List_Config`, or `Modal_Spec` to control hierarchy and spatial behavior.

| Flag | Role | Typical Widget | Esc Behavior | History Impact |
| --- | --- | --- | --- | --- |
| `.Focusable` | Holds `focused_id` | Button, Card, Row | Bubbles to parent | Recorded as $H^*$ leaf |
| `.Focus_Scope` | Scope region | Pane, Column, Form | Drills up if focusable | Stores $H$ and $H^*$ |
| `.Trap_Focus` | Modal shield | `ui_modal`, Palette | Sets `escape_modal_id` | Freezes outer scopes |
| `.Default_Focus` | Initial mount target | Primary Button, Row 0 | Standard leaf | Used before $H^*$ exists |
| `.Captures_Text` | Consumes text keys | `ui_text_input` | Exits 2-stage edit | Standard leaf |
| `.Auto_Edit` | Immediate edit mode | Search bar, Palette | Bubbles in 1 press | Standard leaf |
| `.Scope_Text_Sink` | Scope text delegate | Command Palette input | Bubbles to modal | Resets scope on edit |
| `.Loop_Spatial` | Same-lane ring wrap | Toolbar, Kanban col | Standard scope | Wraps within lane |
| `.Wrap_Spatial` | 2D reading-order wrap | Card grid, Calendar | Standard scope | Wraps to next row/col |
| `.Strict_Spatial` | Blocks nav bubbling | Isolated sub-grid | Standard scope | Swallows edge misses |
| `.Disabled` | Dimmed and skipped | Inactive Button/Group | Ignored | Auto-advances focus |

When focus enters a `.Focus_Scope` (via `F6`, cross-scope spatial movement, `Enter` drill-down, or modal close), `resolve_scope_target` evaluates four stages in order:

1. **Deep History ($H^*$):** Restores `last_leaf_hash` if the node is still mounted, `.Focusable`, and allowed by the active modal shield.
2. **Shallow History ($H$):** If the prior leaf was deleted or filtered out, descends into `last_child_hash` (e.g., the remembered Kanban column) to pick its surviving default or first focusable item.
3. **Fresh Mount:** Selects the first direct child with `.Default_Focus`, or the first focusable descendant.
4. **Empty Scope / Zero-Match Fallback:** Focuses the scope container itself if `.Focusable` is set (such as an empty Kanban column), or falls back to `text_sink_idx` so `Backspace` still works when a filter matches zero rows.

### Example: Drillable Multi-Column Board with `H*` History & Local IDs

Use `ui_scope` with `{.Focus_Scope, .Focusable, .Loop_Spatial}` to create columns that remember their selected card, accept focus when empty, and support `Esc` (drill up to column header) and `Enter` (drill down into the remembered card). Use `hash_local_idi` or `local_id = true` to avoid per-frame `fmt.tprintf` string allocations.

```odin
package demo

import "../../bifrost"

render_board :: proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen, inp: ^bifrost.Input_State) {
	if bifrost.ui_scope(ctx, scr, "board", {
		dir         = .Row,
		width       = bifrost.grow(1),
		height      = bifrost.grow(1),
		gap         = 1,
		focus_flags = {.Loop_Spatial},
	}) {
		columns := [3]string{"col_backlog", "col_doing", "col_done"}
		counts  := [3]int{4, 2, 0} // col_done is empty but still focusable!

		for col_id, c_idx in columns {
			if bifrost.ui_scope(ctx, scr, col_id, {
				dir         = .Column,
				width       = bifrost.grow(1),
				height      = bifrost.grow(1),
				border      = .Rounded,
				scrollable  = true,
				title       = col_id,
				// .Focusable allows Esc to pop focus onto the column itself and F6/h/l to land on empty columns
				focus_flags = {.Focusable, .Loop_Spatial},
			}) {
				col_hash := bifrost.current_scope_hash(ctx)
				for i := 0; i < counts[c_idx]; i += 1 {
					card_hash := bifrost.hash_local_idi(col_hash, "card", i32(i))
					flags := bifrost.Focus_Flags{.Focusable}
					if i == 0 {
						flags += {.Default_Focus}
					}
					bifrost.leaf(ctx, "", 20, 2, {
						id_hash     = card_hash,
						width       = bifrost.grow(1),
						height      = bifrost.fixed(2),
						border      = .Plain,
						text        = "Task Card",
						focus_flags = flags,
					})
				}
			}
		}
	}
	_ = inp
}
```

* **Active vs. Inactive Selection Query:** Call `bifrost.is_focused(inp, id)` for the active cursor tip and `bifrost.is_scope_selected(inp, id)` to check if an item is the remembered $H^*$ selection inside an inactive column or background pane.

---

## 3. 2D Spatial Navigation, Portals & Two-Stage Forms

Bifrost scores spatial candidates (`h/j/k/l`, Arrow keys, and Emacs `Ctrl+N/P/F/B`) using unclipped layout `rect` coordinates so offscreen items inside scroll containers are seamlessly reachable and scrolled into view on the same frame (`0` frame lag).

* **Sticky Orthogonal Axis Bias (`preferred_nav_pos`):** Moving vertically across a full-width banner remembers the prior column's X center so the next vertical step lands back in the original column.
* **Explicit Portal Overrides (`nav_overrides`):** Use `bifrost.nav_target(dir, "target_id")` on `Box_Config` or `Scope_Config` when irregular HUD geometry needs a deterministic jump.
* **Two-Stage vs. `.Auto_Edit` Inputs:** Set `two_stage = true` on `Text_Input_Config` in multi-field forms so `h/j/k/l` navigates between inputs while `editing_id == 0`, `Enter` (or mouse click) enters edit mode, `Tab` carries edit mode to the next text field, and `Esc` exits edit mode before closing an enclosing modal.

### Example: Two-Stage Modal Form with Portal Override & Visual Selection

```odin
package demo

import "../../bifrost"

render_task_modal :: proc(
	ctx: ^bifrost.Layout_Context,
	scr: ^bifrost.Screen,
	inp: ^bifrost.Input_State,
) {
	if bifrost.ui_modal(ctx, scr, "new_task_modal", {
		title    = "Create Task",
		z_layer  = 20,
		width    = bifrost.fixed(48),
		height   = bifrost.fixed(12),
		border   = .Rounded,
		backdrop = .Dim_Screen,
		gap      = 1,
	}) {
		// Two-stage input: starts in navigation mode; Enter/click edits; Shift+Arrows/Ctrl+A selects; Ctrl+C/X copies via OSC 52
		bifrost.ui_text_input(ctx, scr, inp, "title_input", {
			title       = "Title (Enter to edit, Esc to nav)",
			placeholder = "Task summary...",
			width       = bifrost.grow(1),
			height      = bifrost.fixed(3),
			border      = .Plain,
			two_stage   = true,
			focus_flags = {.Default_Focus},
		})

		bifrost.ui_text_input(ctx, scr, inp, "owner_input", {
			title       = "Assignee (Tab carries edit mode)",
			placeholder = "username...",
			width       = bifrost.grow(1),
			height      = bifrost.fixed(3),
			border      = .Plain,
			two_stage   = true,
		})

		// Explicit nav_overrides portal: pressing Up ('k') on save_btn jumps straight to title_input
		bifrost.leaf(ctx, "save_btn", 12, 1, {
			width         = bifrost.fixed(12),
			height        = bifrost.fixed(1),
			text          = "[ Save ]",
			focus_flags   = {.Focusable},
			nav_overrides = bifrost.nav_target(.Up, "title_input"),
		})
	}
}
```

---

## 4. `.Scope_Text_Sink` (Telescope / Fuzzy Finder Pattern)

When a non-focusable `ui_text_input` inside a scope is marked with `{.Captures_Text, .Auto_Edit, .Scope_Text_Sink}`, `reconcile_focus` automatically binds `inp.editing_id` to that input while keeping `inp.focused_id` on the results list:

* Printable characters, `Backspace`, `Delete`, and `Left`/`Right`/`Home`/`End` edit the search input and automatically reset scope selection to `.Default_Focus` (row `0`) whenever text mutates.
* `Up`, `Down`, `Ctrl+N`, `Ctrl+P`, `Page_Up`, `Page_Down`, and `Enter` bypass the text sink and navigate or activate the focused list item.
* If the filter matches `0` items, focus temporarily falls back to `text_sink_idx` so typing and `Backspace` continue working, then snaps back to item `0` as soon as a match reappears.

```odin
package demo

import "../../bifrost"

render_quick_picker :: proc(
	ctx: ^bifrost.Layout_Context,
	scr: ^bifrost.Screen,
	inp: ^bifrost.Input_State,
	matches: []string,
) {
	if bifrost.ui_modal(ctx, scr, "picker_modal", {
		title   = "Quick File Picker",
		z_layer = 30,
		width   = bifrost.fixed(52),
		height  = bifrost.fixed(12),
		border  = .Rounded,
	}) {
		// 1. Non-focusable Scope_Text_Sink captures typing & horizontal cursor keys
		bifrost.ui_text_input(ctx, scr, inp, "picker_query", {
			placeholder = "Type to filter...",
			width       = bifrost.grow(1),
			height      = bifrost.fixed(1),
			focus_flags = {.Captures_Text, .Auto_Edit, .Scope_Text_Sink},
		})

		// 2. Focusable list items receive Up/Down/Ctrl+N/Ctrl+P and Enter activation
		for item, idx in matches {
			flags := bifrost.Focus_Flags{.Default_Focus} if idx == 0 else bifrost.Focus_Flags{}
			bifrost.ui_button(ctx, scr, item, {
				label       = item,
				width       = bifrost.grow(1),
				height      = bifrost.fixed(1),
				focus_flags = flags,
			})
		}
	}
}
```

---

## 5. Declarative Key-Chord DSL, Multi-Style Keymaps & AST Codegen

Bifrost provides a two-tier keybinding system that populates `Input_State.keybindings`, `Command_Palette`, `ui_key_hint_bar`, and `ui_which_key_overlay` from a single definition.

### Tier 1: Zero-Build-Step Struct-Tag Reflection (`register_actions_struct`)

Define an action enum and a struct with ``bifrost:"..."`` tags. Supported tag keys:

| Tag Key | Example | Purpose |
| --- | --- | --- |
| `id` / `action` | `id=task.move_left` | Canonical action name hashed via FNV-1a |
| `key` / `chord` | `key=q|<C-q>` | Default 1-step or 2-step chord with `|` alternates |
| `vim`, `helix`, `emacs` | `vim=g g, emacs=<C-x> [` | Style-specific chords swapped by `set_keymap_style` |
| `scope` | `scope=col_*` | Exact scope ID or `*` prefix wildcard (sets `.Scope_Only`) |
| `policy` | `policy=global` | `root` (`.Root_And_Scopes`), `scope` (`.Scope_Only`), `global` (`.Global_Always`) |
| `group`, `group_desc`, `compact` | `group=nav, group_desc=Move, compact` | Merges hints into `hjkl: Move` or `[/]: History` |
| `desc`, `desc_vim`, `desc_helix`, `desc_emacs` | `desc='Save, close & exit'` | Short hint-bar badge (quote-aware for embedded commas) |
| `label`, `category` | `label=Create Task, category=Board` | Searchable `Command_Palette` title and category |
| `allow_in_edit` | `allow_in_edit=true` | Fires even when `editing_id != 0` |
| `submode` | `submode=1` | Restricts binding to a numeric scope sub-mode |
| `bar`, `palette` | `bar=false, palette=false` | Hides action from `ui_key_hint_bar` or `Command_Palette` |

```odin
package demo

import "../../bifrost"

Board_Action :: enum u8 {
	None = 0,
	Cycle_Style,
	Move_Left,
	Move_Right,
	Jump_Top,
	Quit,
}

Board_Actions :: struct {
	Cycle_Style: Board_Action `bifrost:"key=<F2>, id=keymap.cycle_style, policy=global, allow_in_edit=true, desc='Style (F2)', category=Keymap"`,
	Move_Left:   Board_Action `bifrost:"key=H, id=task.left, scope=col_*, group=stage, group_desc='Move Stage', desc='Move Left', category=Board"`,
	Move_Right:  Board_Action `bifrost:"key=L, id=task.right, scope=col_*, group=stage, group_desc='Move Stage', desc='Move Right', category=Board"`,
	Jump_Top:    Board_Action `bifrost:"vim=g g, helix=g g, emacs=<C-x> [, id=nav.top, scope=col_*, desc='Top Card', category=Navigation"`,
	Quit:        Board_Action `bifrost:"vim=q|<C-q>, helix=q|<C-q>, emacs=<C-x> c|<C-q>, id=app.quit, policy=global, desc='Quit', category=System"`,
}

setup_board_bindings :: proc(inp: ^bifrost.Input_State, cp: ^bifrost.Command_Palette) {
	bifrost.command_palette_init(cp, inp)
	_ = bifrost.register_actions_struct(inp, cp, Board_Actions{})

	// Optional guard: swallow 'H' at the leftmost column with an explanation, or return .Disabled_Bubble
	bifrost.set_action_guard(inp, "task.left", proc(action_id: u64, userdata: rawptr) -> (bifrost.Guard_Result, string) {
		_ = action_id
		is_leftmost := (^bool)(userdata)^
		if is_leftmost {
			return .Disabled_Swallow, "Already at leftmost stage"
		}
		return .Enabled, ""
	}, nil)
}
```

### Multi-Style Modal Editing (`Vim`, `Helix`, `Emacs`) & Numeric Counts

Switch keymap styles at runtime with `bifrost.set_keymap_style(&inp, .Helix)` or `bifrost.cycle_keymap_style(&inp)`:

* **`.Vim` (Default):** `h/j/k/l` navigation and **prefix repeat counts** (`5j` jumps 5 rows down; `3l` steps 3 columns or nudges a splitter in `[RESIZE]` sub-mode by $3 \times \text{step}$).
* **`.Helix`:** Selection/motion-first navigation with **postfix repeat counts** (`j` moves 1 row, then typing `5` immediately advances the remaining 4 rows to complete `j5`).
* **`.Emacs`:** Chordal navigation (`Ctrl+N`/`Ctrl+P`/`Ctrl+F`/`Ctrl+B`, `Ctrl+V`/`Alt+V` paging, `Ctrl+A`/`Ctrl+E` home/end, `Ctrl+G` `keyboard-quit`, `<M-x>` command palette) and **`Ctrl+U` universal argument** (`Ctrl+U` = $4\times$, `Ctrl+U Ctrl+U` = $16\times$, `Ctrl+U 7` = $7\times$).

### Tier 2: Compile-Time AST Code Generator (`tools/bifrost_gen`)

For zero-reflection startup and direct procedure dispatch, annotate structs with `@(ui_actions)` and handler procedures with `@(ui_action="...")` and optional `@(ui_scope="...")`, then run `odin run tools/bifrost_gen -- <pkg_dir>`:

```odin
package my_app

import "../../bifrost"

App_State :: struct {
	tasks_created: int,
	moved_left:    int,
}

@(ui_action="key=n, id=task.new, desc='New Task', category=Board")
on_new_task :: proc(app: ^App_State) {
	app.tasks_created += 1
}

@(ui_scope="col_*")
@(ui_action="key=H, id=task.move_left, group=stage, group_desc='Move Stage', desc='Move Left'")
on_move_left :: proc(app: ^App_State) {
	app.moved_left += 1
}
```

Running `odin run tools/bifrost_gen -- my_app` validates all chord strings at compile time (reporting `file(line:col)` diagnostics on invalid chords or duplicate scope conflicts) and emits `my_app/ui_actions_gen.odin` with `init_app_state_keymap_and_palette(&inp, &cp)` and an FNV-1a switch dispatcher `dispatch_ui_actions(&app, &inp)`. Compile packages using custom attributes with `-custom-attribute:ui_actions,ui_action,ui_scope`.

---

## 6. Contextual Breadcrumb, Hint Bar & Which-Key Overlay

Mount `ui_focus_breadcrumb_bar`, `ui_key_hint_bar`, and `ui_which_key_overlay` inside your layout pass. `apply_input_highlights` refreshes dynamic bars after `resolve_input` so mode badges (`[EDIT]`, `[RESIZE]`, `[COUNT: 5x]`, `[C-u: 4x]`, `[CHORD: g…]`) render on the exact same frame:

```odin
// Inside your root column container:
bifrost.ui_focus_breadcrumb_bar(ctx, scr, inp, "breadcrumb_bar")
// ... main workspace ...
bifrost.ui_key_hint_bar(ctx, scr, inp, "hint_bar")

// Before end_layout(ctx): automatically pops up at z_layer=28 whenever a 2-step prefix is pending
bifrost.ui_which_key_overlay(ctx, scr, inp)
```

---

## 7. 2D Virtualized Tables & Column Hit-Testing

To enable 2D `(row, col)` navigation (`h/l` column stepping that bubbles out to left/right sibling panes when pressing `h` at column `0`) and mouse click column selection on `ui_virtual_list`, set `total_cols` on `Virtual_List_Config` and register solved column spans via `register_virtual_table_col_spans`:

```odin
vslice: bifrost.Virtual_Slice
if bifrost.ui_virtual_list(ctx, scr, inp, "pkg_table", 100_000, {
	title         = "Packages (100k rows x 4 cols)",
	width         = bifrost.grow(1),
	height        = bifrost.grow(1),
	border        = .Rounded,
	fallback_rows = 20,
	total_cols    = len(col_specs),
	focus_flags   = {.Focusable, .Default_Focus},
}, &vslice) {
	for r := vslice.start_row; r < vslice.end_row; r += 1 {
		bifrost.leaf(ctx, "", 20, 1, {
			id_hash   = bifrost.hash_local_idi(bifrost.hash_id("pkg_table"), "row", r),
			width     = bifrost.grow(1),
			height    = bifrost.fixed(1),
			clickable = true,
		})
	}
}

// After end_layout(ctx), register solved column spans so mouse clicks select the exact column:
if inner, ok := bifrost.get_inner_rect(ctx, "pkg_table"); ok {
	spans: [4]bifrost.Table_Column_Span
	bifrost.resolve_table_columns(col_specs[:], spans[:], inner, 2, 1)
	bifrost.register_virtual_table_col_spans(inp, "pkg_table", spans[:])
}
```

---

## 8. Sleipnir Actor Action Sinks, Side-Effects & `xitdb` Persistence

When using `UI_Coordinator_State`, bind UI actions and buttons directly to `sleipnir` worker `actor.PID`s, enqueue pure terminal side-effects, and persist workspace state to `xitdb` without manual per-frame polling:

```odin
package demo

import "../../bifrost"
import actor "../../deps/sleipnir/actor"

wire_coordinator :: proc(
	coord: ^bifrost.UI_Coordinator_State,
	worker_pid: actor.PID(bifrost.Xitdb_Worker_Msg),
	shared_db: ^bifrost.Xitdb_Shared_Handle,
) {
	// 1. Restore splitter widths, H/H* scope memory, keymap style, and chord overrides from xitdb
	_ = bifrost.load_ui_workspace_from_xitdb(shared_db, coord, "main_workspace")

	// 2. Map a UI button directly to a named action
	_ = bifrost.bind_button_action(coord, "btn_run_audit", "query.datalog")

	// 3. Static Sleipnir actor sink (also supports slice-spliced batches `[]Msg`)
	_ = bifrost.bind_actor_action(
		coord,
		"query.datalog",
		worker_pid,
		bifrost.Xitdb_Worker_Msg(bifrost.Worker_Msg_Run_Datalog{
			query_source = "find ?k, ?v where $logs[?k] = ?v",
		}),
	)

	// 4. Dynamic Sleipnir actor sink (reads coordinator state when action fires)
	_ = bifrost.bind_actor_action(
		coord,
		"query.diff",
		worker_pid,
		proc(c: ^bifrost.UI_Coordinator_State, _: rawptr) -> (bifrost.Xitdb_Worker_Msg, bool) {
			return bifrost.Worker_Msg_Diff_Moments{
				moment_a = c.active_moment_idx,
				moment_b = c.latest_moment_idx,
			}, true
		},
	)

	// 5. Local action callback issuing pure terminal side-effects (OSC 52 clipboard, OSC 2 title, DECSCUSR cursor)
	_ = bifrost.on_ui_action(coord, "clip.yank_moment", proc(c: ^bifrost.UI_Coordinator_State, _: string, _: rawptr) {
		bifrost.ui_cmd_copy_osc52(c, "moment-snapshot-copied")
		bifrost.ui_cmd_set_title(c, "Bifrost — Snapshot Copied")
		bifrost.ui_cmd_set_cursor_shape(c, .Bar_Steady)
		bifrost.ui_cmd_request_focus(c, "records_pane")
	})

	// 6. Optional Bubble-Tea-style quit guard to intercept 'q' / Ctrl+Q when unsaved edits exist
	bifrost.ui_set_quit_filter(coord, proc(c: ^bifrost.UI_Coordinator_State) -> bool {
		_ = c
		return true // Return false to block quit and open a confirmation modal
	})
}
```

---

## 9. AST-Powered ATDD DSL & `@(scenario)` Purity Checker (`--atdd`)

Bifrost's 4-layer Acceptance Test-Driven Development (ATDD) suite in `tests/` uses `core:odin/parser` (`odin run tools/bifrost_gen -- --atdd tests`) to inspect all `given_*`, `upon_*`, and `then_*` steps in `tests/dsl_*.odin`, validate Layer 1 `@(scenario)` purity across `tests/spec_*.odin`, and emit `tests/dsl_atdd_gen.odin`:

1. **`@(deferred_out = scenario_scope_end)` RAII `scenario(t, ...)` & `actor_scenario(t, ...)`:** Automatically initializes a stack-managed `Suite_Ctx` on `@(thread_local) _scenario_stack`, calls `given_terminal` (or `given_actor_tui_system`), and runs `driver_destroy` when the test exits—eliminating manual `s: Suite_Ctx` + `defer driver_destroy(&s)` boilerplate with zero heap allocations.
2. **Ambient Namespace DSL (`given.*`, `upon.*`, `then.*`):** Zero-state-threading step calls that automatically forward the active thread-local `Suite_Ctx` and caller `#caller_location` (`loc`).
3. **`Scenario_Handle` Method Selector VTable (`s->given_*`, `s->upon_*`, `s->then_*`):** `using vtable: ^Suite_Ctx_VTable` on `Scenario_Handle` so specs can also use `->` method call syntax or access `s.ctx` when needed.
4. **Compile-Time Layer 1 Purity Enforcement (`@(scenario)`):** Any test annotated with `@(scenario)` in `tests/spec_*.odin` is AST-checked by `bifrost_gen --atdd` to forbid raw `testing.expect*` calls, direct Layer 3 `driver_*` calls, and zero-argument `then.*()` ("Macro Theater") assertions.

```odin
package bifrost_tests

import "core:testing"
import "../bifrost"

@(test)
@(scenario)
spec_three_phase_event_dispatch_and_capture_short_circuit :: proc(t: ^testing.T) {
	_ = scenario(t, w = 80, h = 24)

	given.focused_widget("save_btn")
	upon.rendering_frame(proc(ctx: ^bifrost.Layout_Context, scr: ^bifrost.Screen) {
		if bifrost.container(ctx, "root_panel", {dir = .Column, width = bifrost.grow(1), height = bifrost.grow(1)}) {
			if bifrost.container(ctx, "toolbar", {dir = .Row, width = bifrost.grow(1), height = bifrost.fixed(3)}) {
				bifrost.ui_button(ctx, scr, "save_btn", {label = "Save"})
			}
		}
	})
	then.focused_widget_is("save_btn")

	upon.pressing_key(.Enter)
	then.activated_widget_is("save_btn")
}
```

Run the generator and execute the ATDD suite with:

```bash
odin run tools/bifrost_gen -- --atdd tests
odin test tests -custom-attribute:scenario
```

