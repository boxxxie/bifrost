# Specification: Track 3 — Virtualized `xitdb` Lists, UTF-8 Text Filter, Splitters & Command Palette (`xitdb_widgets_and_palette_20261103`)

## Overview
Build the high-throughput widget suite (`bifrost/scroll.odin`, `bifrost/text_input.odin`, `bifrost/splitter_keymap.odin`, `bifrost/command_palette.odin`) enabling $O(1)$ virtualized rendering of 100,000+ row `xitdb` collections, grapheme-cluster and display-width accurate UTF-8 search filtering, interactive 1-cell splitters with box-junction merging, 3-tier global/scoped keymaps, and a `Ctrl+P` fuzzy command palette.

## Reference Patches & Investigation
- **Investigation Report:** [`investigation.md`](./investigation.md)
- [`.tmp/patches/track3_libvaxis_widgets_scroll_input.patch`](../../../.tmp/patches/track3_libvaxis_widgets_scroll_input.patch) (`reference/libvaxis`)
- [`.tmp/patches/track3_ratatui_buffer_and_virtual_widgets.patch`](../../../.tmp/patches/track3_ratatui_buffer_and_virtual_widgets.patch) (`reference/ratatui`)
- [`.tmp/patches/track3_lipgloss_box_style.patch`](../../../.tmp/patches/track3_lipgloss_box_style.patch) (`reference/lipgloss`)

## Functional Requirements (Refined via Investigation)
1. **Virtualized `xitdb` Lists, Table Columns & Interior-Detent Scrollbars (`bifrost/scroll.odin`):**
   - Persistent `Scroll_Slot` table (`[MAX_SCROLL_SLOTS]Scroll_Slot`) and scoped `ui_virtual_list` returning `Virtual_Slice{start_row, end_row, selected_row, total_rows}` with `scroll_padding` lookahead.
   - `compute_scrollbar_metrics` using `i64` arithmetic and interior-detent clamping (`thumb_offset = 0` strictly at `scroll_offset == 0`, `thumb_offset = track_avail` strictly at `scroll_offset == max_scroll`, and `[1, track_avail - 1]` for all interior scroll positions).
   - Jitter-free virtual table column auto-expansion (`Table_Column_Spec` with monotonic `max_seen_width`) and box-drawing junction merging (`surface_merge_box_cell` producing `┬`, `┴`, `├`, `┤`, `┼`).
2. **Grapheme-Aware UTF-8 Text Input & Real-Time `xitdb` Filter (`bifrost/text_input.odin`):**
   - `Text_Input_Slot` (`[256]byte`), grapheme-cluster navigation (`next_grapheme_cluster` / `prev_grapheme_cluster` handling ZWJ `U+200D`, VS16 `U+FE0F`, combining marks), and display-column viewport panning (`slice_utf8_by_display_width` with `lead_pad`/`trail_pad` and wide-cell clearing under `'…'` ellipsis indicators).
   - Distinct word-deletion motions (`Ctrl+W` whitespace-delimited `text_input_delete_word_whitespace` vs `Alt+Backspace` punctuation/alphanumeric boundary `text_input_delete_word_boundary`), click-to-place, and Telescope-style `linked_list_id` arrow-key forwarding.
   - `Xitdb_Filter` caching matching row indices per `(moment_slot, query_hash, total_db_rows)`.
3. **Interactive Splitters, Keybinding Router & Command Palette (`bifrost/splitter_keymap.odin`, `bifrost/command_palette.odin`):**
   - 1-cell `ui_splitter` with same-frame drag and keyboard resize (`apply_splitter_size_immediate`).
   - 3-tier keybinding router (`.Scope_Only`, `.Root_And_Scopes`, `.Global_Always`) with `.Allow_In_Text_Input`.
   - `Command_Palette` (`ui_command_palette`, `update_command_palette`) with multi-token fuzzy scoring (word-boundary, camelCase, consecutive-run bonuses) and live shortcut badge discovery.
4. **4-Layer ATDD Specifications (`tests/spec_widgets_and_palette.odin`):**
   - 100,000-row virtualized `xitdb` viewport slicing ($O(1)$ layout node budget & interior-detent scrollbar accuracy at `99,979`), live CJK/ZWJ-emoji search filtering, jitter-free table columns, splitter drag/keyboard resize, and `Ctrl+P` fuzzy command execution.
