# Specification: Track 5 — Sleipnir Actor Runtime Bridge & Interactive `xitdb` Inspector App (`sleipnir_xitdb_inspector_20261103`)

## Overview
Integrate `package bifrost` with `deps/sleipnir` (`package actor`) and `deps/xitdb` (`package xitdb`) via a Bubble-Tea-inspired actor message/command bridge (`bifrost/actor_bridge.odin`), and build an interactive `xitdb` Inspector TUI application (`examples/xitdb_inspector/`).

## Reference Patches & Investigation
- **Investigation Report:** [`investigation.md`](./investigation.md)
- [`.tmp/patches/track5_bubbletea_actor_loop.patch`](../../../.tmp/patches/track5_bubbletea_actor_loop.patch) (`reference/bubbletea`)
- [`.tmp/patches/track5_sleipnir_actor_api.patch`](../../../.tmp/patches/track5_sleipnir_actor_api.patch) (`deps/sleipnir`)
- [`.tmp/patches/track5_xitdb_api.patch`](../../../.tmp/patches/track5_xitdb_api.patch) (`deps/xitdb`)

## Functional Requirements (Refined via Investigation)
1. **Sleipnir + `xitdb` Actor Bridge (`bifrost/actor_bridge.odin`):**
   - Typed actor messages (`UI_Msg` union: `UI_Msg_Key`, `UI_Msg_Mouse`, `UI_Msg_Resize`, `UI_Msg_Commit_Notification`, `UI_Msg_Select_Moment`, `UI_Msg_Scroll_Viewport`, `UI_Msg_Search_Input`, `UI_Msg_Palette_Toggle`, `UI_Msg_Frame_Tick`, `UI_Msg_Quit`).
   - Mailbox burst coalescing in `ui_coordinator_receive`: reduce state in $O(1)$ per message and defer `UI_Coordinator_Render_Callback` while `!actor.mpsc_is_empty(&self.mailbox) && state.batch_drained < state.max_coalesce_batch`, coalescing 1,000+ rapid worker commits into a single immediate-mode layout + diff pass.
   - Zero-copy `xitdb` viewport slicing (`xitdb_slice_viewport`): seek directly to `start_row` in $O(\log_{16} N)$ via `cursor_iterator_array_list_from_index`, `cursor_iterator_linked_array_list_from_index`, `cursor_iterator_sorted_from_index`, and `cursor_iterator_sorted_from_key`, reading keys/values into stack buffers (`cursor_read_bytes_buf`) and cloning only visible `[start_row ..< end_row]` strings onto `context.temp_allocator`.
2. **Interactive `xitdb` Inspector TUI (`examples/xitdb_inspector/main.odin`):**
   - Background `sleipnir` worker actors committing live moments to an `xitdb` database and sending $O(1)$ `UI_Msg_Commit_Notification` messages to the UI coordinator actor.
   - Time-travel moment selector (with `pinned_moment` locking), resizable collection sidebar (`ui_splitter`), 100k-row virtualized record viewport (`ui_virtual_list` + `xitdb_slice_viewport`), real-time UTF-8 search (`ui_text_input` + `Xitdb_Filter`), and `Ctrl+P` fuzzy command palette (`ui_command_palette`).
3. **4-Layer ATDD Specifications (`tests/spec_actor_tui_integration.odin`):**
   - End-to-end actor-to-UI specs verifying background `sleipnir` workers committing `xitdb` moments, 1,000-message burst coalescing into a single frame render, historical moment time-travel while new commits arrive, and 100,000-row $O(\log_{16} N)$ viewport slicing with zero memory leaks.
