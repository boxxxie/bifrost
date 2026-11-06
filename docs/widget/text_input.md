# Single-Line UTF-8 Text Input (`ui_text_input`)

**Source File:** [`bifrost/text_input.odin`](../../bifrost/text_input.odin)

`ui_text_input` is a zero-allocation, single-line UTF-8 text input widget supporting extended grapheme cluster navigation (including 2-column CJK characters, Emoji variation selectors `U+FE0F`, and Zero-Width Joiner `U+200D` sequences), horizontal viewport scrolling, `Shift+Arrow` visual selection, Readline/Emacs kill commands, zero-CGO OSC 52 terminal clipboard integration, and Telescope-style list forwarding.

---

## 1. Configuration & State Slot (`Text_Input_Config`, `Text_Input_Slot`)

`Input_State` manages up to `MAX_TEXT_SLOTS` ($16$) concurrent text inputs, each backed by a fixed `[MAX_TEXT_BYTES]byte` ($256$-byte) inline buffer.

```odin
Text_Input_Config :: struct {
	placeholder:    string,
	initial_text:   string,
	linked_list_id: string,      // Optional virtual list ID to forward Up/Down/PgUp/PgDn/C-n/C-p to
	width:          Axis_Size,   // Defaults to grow(1, min = 12)
	height:         Axis_Size,   // Defaults to fixed(1) (or fixed(3) when border != .None)
	border:         Border_Kind,
	fg:             Color,
	bg:             Color,
	placeholder_fg: Color,
	border_fg:      Color,
	title:          string,
	focus_flags:    Focus_Flags,
	two_stage:      bool,        // When true, requires Enter or click before capturing printable keys
}
```

---

## 2. Editing Modes: `.Auto_Edit`, `two_stage`, and `.Scope_Text_Sink`

`ui_text_input` supports three distinct interaction patterns depending on your layout:

1. **Immediate `.Auto_Edit` (Default):**
   * Focusing the input immediately sets `inp.editing_id = id_hash` and displays the block cursor.
   * Pressing `Escape` transfers focus to `linked_list_id` (if configured) or steps to the next focusable widget in the scope.
2. **Two-Stage Modal Input (`two_stage = true`):**
   * Focusing the input via `Tab` or `h/j/k/l` leaves `inp.editing_id == 0` (`.Navigation` mode) so single-letter navigation keys move between form fields.
   * Pressing `Enter` (or clicking the input with the mouse) enters `.Editing` mode (`inp.editing_id = id_hash`).
   * Pressing `Tab` while editing carries edit mode directly into the next `ui_text_input` (`carry_edit_mode`).
   * Pressing `Escape` exits `.Editing` mode back to `.Navigation` mode without dismissing an enclosing modal.
3. **Orthogonal Scope Text Sink (`focus_flags = {.Captures_Text, .Auto_Edit, .Scope_Text_Sink}`):**
   * Used by `ui_command_palette` and fuzzy finders. The input captures typing, `Backspace`, and horizontal cursor movement for the entire enclosing `ui_scope` while `inp.focused_id` remains on the results list for `Up`/`Down`/`Enter` activation.
   * Any text mutation in a `.Scope_Text_Sink` automatically resets the enclosing scope's selection and scroll offset back to item `0` (`reset_scope_selection_to_default`).

---

## 3. Keyboard & Mouse Bindings (When `editing_id == id_hash`)

| Key / Event | Action |
| :--- | :--- |
| `Printable Rune` / `Space` | Replaces active selection (if any) and inserts UTF-8 codepoint at `cursor_byte` |
| `Left` / `Right`, `Ctrl+B` / `Ctrl+F` | Move caret by 1 extended grapheme cluster (or collapse unshifted selection to its left/right edge) |
| `Ctrl+Left` / `Ctrl+Right`, `Alt+B` / `Alt+F` | Move caret to previous / next word boundary |
| `Home` / `End`, `Ctrl+E` | Jump to start (`0`) or end (`slot.len`) of input |
| `Shift + Left/Right/Home/End` | Extend or shrink visual selection (`sel_anchor_byte .. cursor_byte`, rendered with `{.Reverse}`) |
| `Ctrl+A` | Select all text (in `.Vim`/`.Helix` styles) or jump to start of line (in `.Emacs` style when unshifted) |
| `Backspace` / `Delete`, `Ctrl+D` | Delete active selection or adjacent grapheme cluster |
| `Alt+Backspace` / `Ctrl+Backspace` | Delete backward to word/punctuation boundary (`text_input_delete_word_boundary`) |
| `Alt+D` / `Ctrl+Delete` | Delete forward to word boundary (`text_input_delete_word_after`) |
| `Ctrl+W` | Unix word rubout: delete backward across whitespace + non-whitespace run and copy to clipboard |
| `Ctrl+U` / `Ctrl+K` | Kill to start / end of line and copy killed text to internal + OSC 52 clipboard |
| `Ctrl+C` / `Ctrl+X` | Copy / Cut active selection to internal clipboard and set `inp.osc52_pending = true` |
| `Ctrl+V` / `Ctrl+Y` / `Paste_Event` | Paste from internal clipboard or bracketed terminal paste |
| `Up` / `Down` / `PgUp` / `PgDn` / `C-n` / `C-p` | Forwarded directly to `linked_list_id` virtual list when `linked_list_id` is set |
| `Mouse Left Click` | Focus input, enter edit mode, clear selection, and place caret at clicked grapheme column |

---

## 4. Public API & Real-Time `Xitdb_Filter`

### State Accessors
* `ui_text_input(ctx: ^Layout_Context, s: ^Screen, inp: ^Input_State, id: string, cfg: Text_Input_Config = {}) -> i32`
* `get_text(inp: ^Input_State, id: string) -> string`
* `set_text(inp: ^Input_State, id: string, value: string)`
* `get_selected_text(inp: ^Input_State, id: string) -> string`
* `was_text_changed(inp: ^Input_State, id: string) -> bool`
* `slice_utf8_by_display_width(str: string, scroll_col: i32, max_cols: i32) -> Visible_Utf8_Slice`

### Zero-Allocation `Xitdb_Filter` Integration
Pair `ui_text_input` with `Xitdb_Filter` to filter virtualized `ui_virtual_list` collections in real time, recomputing `matched_indices` only when the query string or `xitdb` `moment_slot` changes:

```odin
package demo

import "core:fmt"
import "../../bifrost"

render_searchable_list :: proc(
	ctx: ^bifrost.Layout_Context,
	scr: ^bifrost.Screen,
	inp: ^bifrost.Input_State,
	filter: ^bifrost.Xitdb_Filter,
	moment_slot: i64,
	total_db_rows: i32,
) {
	// 1. Update cached filter indices when "search_input" or moment_slot changes
	matched_count := bifrost.xitdb_filter_update(
		filter,
		inp,
		"search_input",
		"results_list",
		moment_slot,
		total_db_rows,
		proc(db_row: i32, alloc := context.temp_allocator) -> string {
			return fmt.aprintf("record-%04d", db_row, allocator = alloc)
		},
	)

	// 2. Render search bar linked to "results_list"
	bifrost.ui_text_input(ctx, scr, inp, "search_input", {
		placeholder    = "Filter records...",
		linked_list_id = "results_list",
		border         = .Plain,
	})

	// 3. Render virtualized results list
	vslice: bifrost.Virtual_Slice
	if bifrost.ui_virtual_list(ctx, scr, inp, "results_list", matched_count, {
		border        = .Rounded,
		fallback_rows = 12,
	}, &vslice) {
		for vis_r := vslice.start_row; vis_r < vslice.end_row; vis_r += 1 {
			db_row := bifrost.xitdb_filter_map_row(filter, vis_r)
			row_id := fmt.tprintf("row_%d", vis_r)
			bifrost.ui_label(ctx, scr, row_id, fmt.tprintf("Row #%04d", db_row))
		}
	}
}
```