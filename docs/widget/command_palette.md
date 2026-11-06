# Fuzzy Command Palette (`ui_command_palette`)

**Source File:** [`bifrost/command_palette.odin`](../../bifrost/command_palette.odin)

`ui_command_palette` is a floating modal overlay (`z_layer = 30`, `.Dim_Screen` 50% RGB backdrop dimming) modeled after VS Code, Helix, and Telescope. It combines a `.Scope_Text_Sink` search input, a multi-token subsequence fuzzy scorer (`fuzzy_score`), a virtualized results list, and automatic right-aligned keyboard shortcut badge discovery from `Input_State.keybindings`.

---

## 1. Data Structures (`Command_Palette`, `Command_Item`)

`Command_Palette` is a zero-allocation struct holding up to `MAX_PALETTE_COMMANDS` ($64$) commands.

```odin
Command_Item :: struct {
	action:    string, // Canonical action name (e.g. "theme.cycle")
	action_id: u64,    // FNV-1a 64-bit hash of `action`
	label:     string, // Human-readable title (e.g. "Cycle Color Theme")
	category:  string, // Optional category prefix (e.g. "Appearance")
	shortcut:  string, // Auto-discovered from Input_State.keybindings if left empty
}

Command_Palette :: struct {
	id:            string,
	input_id:      string,
	list_id:       string,
	toggle_action: string,
	is_open:       bool,
	commands:      [MAX_PALETTE_COMMANDS]Command_Item,
	command_cnt:   int,
	matches:       [MAX_PALETTE_COMMANDS]Command_Match,
	match_count:   int,
	last_query:    [MAX_TEXT_BYTES]byte,
	last_q_len:    int,
	dirty:         bool,
}
```

---

## 2. Multi-Token Fuzzy Scoring & Auto Shortcut Discovery

1. **Multi-Token Subsequence Matching (`fuzzy_score`):**
   * Every space-separated token in the user's query must match either `cmd.label` or `cmd.category` (case-insensitive).
   * Matches on `cmd.label` receive a $+20$ priority bonus over category-only matches.
   * Character matches earn bonuses for start-of-string ($+25$), word boundaries (` `, `_`, `-`, `/`, `:`, `.`: $+20$), `camelCase` transitions ($+15$), and consecutive character runs ($+12 \times \text{run}$), with a $-1$ gap penalty.
   * Matched commands are stably sorted in descending score order.
2. **Automatic Shortcut Badge Discovery (`lookup_action_shortcut_by_id`):**
   * If `cmd.shortcut` is empty, `ui_command_palette` inspects `inp.keybindings` for `cmd.action_id` and formats 1-step (`Ctrl+T`, `F2`) or 2-step (`g g`, `Ctrl+X [`) chords right-aligned on each command row.
   * Switching keymap styles at runtime (`set_keymap_style(&inp, .Emacs)`) automatically updates the shortcut badges displayed in the Command Palette and rebinds `palette.toggle` from `<C-p>` to `<M-x>` (`execute-extended-command`) so `<C-p>` is freed for `previous-line`.
3. **Single-Source Struct-Tag Registration:**
   * Calling `register_actions_struct(&inp, &palette, My_Actions{})` registers both the keybindings on `Input_State` and the searchable commands on `Command_Palette` in one call.

---

## 3. Keyboard & Mouse Bindings

| Key / Event | Action |
| :--- | :--- |
| `Ctrl+P` (Vim/Helix) or `Alt+X` (`<M-x>` in Emacs) | Toggle Command Palette open/closed from anywhere (`.Global_Always`, `.Allow_In_Text_Input`) |
| `Printable Runes` / `Backspace` / `Left` / `Right` | Captured by `.Scope_Text_Sink` search input; live-filters commands and resets selection to row `0` |
| `Up` / `Down`, `Ctrl+P` / `Ctrl+N`, `PgUp` / `PgDn` | Navigate matched command rows via `linked_list_id` |
| `Enter` | Dispatches the selected command's `action` (respecting any `Action_Guard_Proc` or `Action_Availability`) and closes the palette |
| `Mouse Left Click` on command row | Selects and dispatches the clicked command row and closes the palette |
| `Escape` or `Mouse Click` outside modal | Dismisses the Command Palette and restores prior focus via the LIFO modal stack |

---

## 4. Public API & Usage Example

### Procedures
* `command_palette_init(cp: ^Command_Palette, inp: ^Input_State = nil, id := "cmd_palette_modal", input_id := "cmd_palette_input", list_id := "cmd_palette_list", toggle_action := "palette.toggle")`
* `register_command(cp: ^Command_Palette, action_name: string, label: string, category: string = "", shortcut: string = "")`
* `ui_command_palette(ctx: ^Layout_Context, s: ^Screen, inp: ^Input_State, cp: ^Command_Palette, width: i32 = 54, visible_rows: i32 = 8)`
* `update_command_palette(cp: ^Command_Palette, inp: ^Input_State, toggle_action: string = "") -> bool`
* `fuzzy_score(label, category, query: string) -> (score: i32, matched: bool)`

### Example
```odin
package demo

import "../../bifrost"

App_Action :: enum u8 {
	None = 0,
	Save,
	Format,
	Quit,
}

App_Actions :: struct {
	Save:   App_Action `bifrost:"key=<C-s>, id=file.save, allow_in_edit=true, desc=Save, label='Save Workspace to xitdb', category=File"`,
	Format: App_Action `bifrost:"vim=g f, helix=<Space> f, emacs=<C-c> f, id=code.format, desc=Format, label='Format Buffer', category=Editor"`,
	Quit:   App_Action `bifrost:"key=q|<C-q>, id=app.quit, policy=global, desc=Quit, label='Quit Application', category=System"`,
}

init_palette :: proc(inp: ^bifrost.Input_State, cp: ^bifrost.Command_Palette) {
	bifrost.command_palette_init(cp, inp)
	_ = bifrost.register_actions_struct(inp, cp, App_Actions{})
}

// 1. Inside your layout pass (before end_layout):
//    bifrost.ui_command_palette(ctx, scr, inp, cp, 56, 6)
//
// 2. Inside your input handling step (after resolve_input):
//    if bifrost.update_command_palette(cp, inp) { ... }
```