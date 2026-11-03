# Implementation Plan: `xitdb_widgets_and_palette_20261103`

## Phase 1: Reference Investigation & ATDD Red-First Specs
- [x] Review findings from `track3_libvaxis_widgets_scroll_input.patch`, `track3_ratatui_buffer_and_virtual_widgets.patch`, and `track3_lipgloss_box_style.patch` (documented in [`investigation.md`](./investigation.md)).
- [ ] Write Red-First ATDD scenarios in `tests/spec_widgets_and_palette.odin`.

## Phase 2: Virtualized `xitdb` Scrolling, Interior-Detent Scrollbars & Grapheme-Aware UTF-8 Text Filter (`bifrost/scroll.odin`, `bifrost/text_input.odin`)
- [ ] Implement `Scroll_Slot`, `Virtual_Slice`, `ui_virtual_list`, `compute_scrollbar_metrics` (with `i64` interior-detent clamping), `Table_Column_Spec`, `surface_merge_box_cell`, `hit_test_scrollable`, and `draw_vertical_scrollbar` in `bifrost/scroll.odin`.
- [ ] Implement `Text_Input_Slot`, `ui_text_input`, `next_grapheme_cluster` / `prev_grapheme_cluster`, `slice_utf8_by_display_width`, `Ctrl+W` vs `Alt+Backspace` word deletion, `linked_list_id` forwarding, and `Xitdb_Filter` in `bifrost/text_input.odin`.

## Phase 3: Splitters, 3-Tier Keymap & Fuzzy Command Palette (`bifrost/splitter_keymap.odin`, `bifrost/command_palette.odin`)
- [ ] Implement `Splitter_Slot`, `ui_splitter`, `apply_splitter_size_immediate`, and 3-tier keybinding dispatch in `bifrost/splitter_keymap.odin`.
- [ ] Implement `Command_Palette`, `ui_command_palette`, `fuzzy_score`, and `lookup_action_shortcut` in `bifrost/command_palette.odin`.
- [ ] Verify all unit tests and ATDD specs pass with zero memory leaks.
