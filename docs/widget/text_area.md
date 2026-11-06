# Multi-Line UTF-8 Text Editor (`ui_text_area`)

**Source File:** [`bifrost/text_area.odin`](../../bifrost/text_area.odin)

`ui_text_area` is a multi-line, grapheme- and East Asian display-width-aware text and code editor featuring 2D caret navigation with sticky `preferred_col`, an optional dynamic line-number gutter, multi-line `Shift+Arrow` / `Ctrl+A` selection, $O(N + M)$ bulk bracketed paste, zero-CGO OSC 52 clipboard integration, proportional vertical scrollbar rendering, and built-in zero-allocation **Odin** and **CUE** syntax highlighters.

---

## 1. Configuration & State Management (`Text_Area_Config`, `Text_Area_State`)

```odin
Text_Area_Syntax_Mode :: enum u8 {
	None = 0,
	Odin = 1, // Built-in Odin lexical highlighter (highlight_odin_line)
	Cue  = 2, // Built-in CUE schema highlighter (highlight_cue_line)
}

Text_Area_Highlighter_Proc :: #type proc(
	line:       string,
	line_idx:   i32,
	out_spans:  ^[dynamic]Styled_Span,
	default_fg: Color,
	default_bg: Color,
	userdata:   rawptr,
)

Text_Area_Config :: struct {
	placeholder:       string,
	initial_text:      string,
	width:             Axis_Size,   // Defaults to grow(1)
	height:            Axis_Size,   // Defaults to fixed(6)
	border:            Border_Kind,
	fg:                Color,
	bg:                Color,
	placeholder_fg:    Color,
	border_fg:         Color,
	gutter_fg:         Color,
	title:             string,
	focus_flags:       Focus_Flags,
	two_stage:         bool,        // Enter / 'i' / Click to edit; Esc returns to 2D scope nav
	show_line_numbers: bool,        // Dynamic 1-based left line-number gutter (" 1 │")
	tab_width:         i32,         // Spaces per Tab press (1..8, default 4)
	syntax_mode:       Text_Area_Syntax_Mode,
	highlighter:       Text_Area_Highlighter_Proc,
	highlight_data:    rawptr,
	state:             ^Text_Area_State, // Optional caller-owned heap state
}
```

### Fixed Zero-Allocation Slots vs. Caller-Owned Dynamic State
* **Default Zero-Allocation Mode (`cfg.state == nil`):** `Input_State` provides `MAX_TEXT_AREA_SLOTS` ($8$) fixed-capacity slots (`[4096]u8` buffer, `256` lines max) evicted via `last_layout_gen` LRU with zero heap allocations.
* **Caller-Owned Dynamic Buffer (`cfg.state != nil`):** For larger documents, initialize a `Text_Area_State` with `text_area_init(&my_state, allocator, initial_text)` (`defer text_area_destroy(&my_state)`) and pass `state = &my_state` in `Text_Area_Config`.

---

## 2. Architectural Invariants

1. **Sticky `preferred_col` Across Vertical Motion:**
   * Moving `Up`, `Down`, `Page_Up`, or `Page_Down` (or `Ctrl+P` / `Ctrl+N` in Emacs mode) preserves `slot.preferred_col` across shorter or empty intermediate lines and resolves the target byte via `text_area_byte_for_row_col` without splitting multi-byte UTF-8 or 2-column CJK/Emoji grapheme clusters.
   * Horizontal caret movement, text insertion/deletion, and mouse clicks update `preferred_col` to the new `cursor_col`.
2. **Two-Stage Modal Editing (`two_stage = true`):**
   * Focusing the editor in `.Navigation` mode (`inp.editing_id == 0`) highlights the border in blue and allows `h/j/k/l` to navigate to adjacent widgets.
   * Pressing `Enter` or `i` (or clicking inside the editor) enters `.Editing` mode (`inp.editing_id == node.id_hash`, gold border + block cursor).
   * Pressing `Escape` (or `Ctrl+G` in Emacs style) clears any active selection first; pressing `Escape` again exits `.Editing` mode back to `.Navigation` mode.
3. **Syntax Highlighting with Selection & Scroll Preservation:**
   * `render_text_area_range_with_spans` slices syntax `Styled_Span`s across horizontal scroll offsets (`scroll_col`) and overlays `{.Reverse}` on any selected byte range (`[sel_lo, sel_hi)`) so syntax colors remain intact inside and outside selections.

---

## 3. Keyboard & Mouse Bindings (`.Editing` Mode)

| Key / Event | Action |
| :--- | :--- |
| `Left` / `Right`, `Ctrl+B` / `Ctrl+F` | Move caret by 1 grapheme cluster (or collapse unshifted selection) |
| `Ctrl+Left` / `Ctrl+Right`, `Alt+B` / `Alt+F` | Move caret to previous / next word boundary |
| `Up` / `Down`, `Ctrl+P` / `Ctrl+N` (Emacs) | Move caret 1 line up / down while preserving sticky `preferred_col` |
| `Page_Up` / `Page_Down` | Move caret `max(1, viewport_h - 1)` lines up / down while preserving `preferred_col` |
| `Home` / `End`, `Ctrl+E` | Jump to start / end of current line |
| `Ctrl+Home` / `Ctrl+End` | Jump to start (`0`) / end (`slot.len`) of document |
| `Shift + <Any Motion>` | Extend or shrink multi-line selection (`sel_anchor_byte .. cursor_byte`) |
| `Ctrl+A` | Select entire document (or jump to line start in `.Emacs` style when unshifted) |
| `Enter` / `KP_Enter` | Delete active selection and insert `\n` (up to `MAX_TEXT_AREA_LINES = 256`) |
| `Tab` | Delete active selection and insert `tab_width` spaces (`1..8`, default `4`) |
| `Backspace` / `Delete`, `Ctrl+H` / `Ctrl+D` | Delete active selection or adjacent grapheme cluster (joins lines across `\n`) |
| `Ctrl+W`, `Ctrl+Backspace`, `Alt+Backspace` | Delete previous word on current line (copies killed word to clipboard on `Ctrl+W`) |
| `Alt+D`, `Ctrl+Delete` | Delete next word on current line |
| `Ctrl+U` / `Ctrl+K` | Kill to start / end of line (or join next line at EOL) and copy to OSC 52 clipboard |
| `Ctrl+C` / `Ctrl+X` | Copy / Cut active multi-line selection to internal + OSC 52 clipboard (`osc52_pending = true`) |
| `Ctrl+V` / `Ctrl+Y` / `Paste_Event` | Single-pass $O(N + M)$ bulk insert with `\r\n` $\rightarrow$ `\n` and `\t` $\rightarrow$ spaces normalization |
| `Mouse Left Click` | Focus editor, enter `.Editing` mode, and place caret at clicked `(row, display_col)` |
| `Mouse Wheel Up / Down` | Scroll viewport vertically (`scroll_row`) without moving the caret |
| `Escape` / `Ctrl+G` (Emacs) | Clear active selection if present; otherwise exit `.Editing` mode to `.Navigation` mode |

---

## 4. Public API & Code Example

### Procedures
* `ui_text_area(ctx: ^Layout_Context, s: ^Screen, inp: ^Input_State, id: string, cfg: Text_Area_Config = {}) -> i32`
* `text_area_init(state: ^Text_Area_State, allocator := context.allocator, initial_text: string = "") -> mem.Allocator_Error`
* `text_area_destroy(state: ^Text_Area_State)`
* `get_text_area(inp: ^Input_State, id: string) -> string`
* `set_text_area(inp: ^Input_State, id: string, value: string)`
* `get_text_area_state(inp: ^Input_State, id: string) -> ^Text_Area_State`
* `get_text_area_cursor(inp: ^Input_State, id: string) -> (row, col: i32, byte_offset: int)`
* `get_text_area_scroll(inp: ^Input_State, id: string) -> (scroll_row, scroll_col: i32)`
* `get_text_area_selected_text(inp: ^Input_State, id: string) -> string`
* `get_text_area_line_count(inp: ^Input_State, id: string) -> int`
* `text_area_insert_string(inp: ^Input_State, slot: ^Text_Area_State, text: string) -> bool`

### Example: Odin & CUE Syntax-Highlighted Editor
```odin
package demo

import "core:fmt"
import "../../bifrost"

render_code_editor :: proc(
	ctx: ^bifrost.Layout_Context,
	scr: ^bifrost.Screen,
	inp: ^bifrost.Input_State,
	is_cue_file: bool,
) {
	row, col, _ := bifrost.get_text_area_cursor(inp, "code_editor")
	lines       := bifrost.get_text_area_line_count(inp, "code_editor")

	bifrost.ui_text_area(ctx, scr, inp, "code_editor", {
		title             = fmt.tprintf("Editor (L%d:C%d | %d lines)", row + 1, col + 1, lines),
		initial_text      = "package main\n\nmain :: proc() {\n    // Press Enter or 'i' to edit\n}",
		width             = bifrost.grow(1),
		height            = bifrost.grow(1),
		border            = .Rounded,
		two_stage         = true,
		show_line_numbers = true,
		tab_width         = 4,
		syntax_mode       = .Cue if is_cue_file else .Odin,
		focus_flags       = {.Default_Focus},
	})
}
```