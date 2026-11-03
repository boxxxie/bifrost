# Implementation Plan: `actor_xitdb_tui_20261103`

## Phase 1: Two-Pass Layout Solver & Z-Layer Geometry (`bifrost/layout.odin`)
- [x] Implement `Direction`, `Alignment`, `Border_Kind`, `Anchor_Mode`, `Fit`, `Grow`, `Fixed`, `Axis_Size`, `Padding`, `Rect`, `Box_Config`, `Layout_Node`, and `Layout_Context` in `bifrost/layout.odin`.
- [x] Implement `begin_layout`, scoped `container` (`@(deferred_in = defer_end_container)`), `leaf`, `push_node`, `get_rect`, `get_inner_rect`, and `end_layout` (Pass 0 z-layer/scope propagation, Pass 1 reverse-topological Fit sizing, Pass 2 forward Grow solver + hierarchical clip rects, Pass 3 stable `z_order` sort).
- [x] Verify layout solver unit tests (`test_clay_layout_solver`, `test_grow_min_max_and_remainder`) pass with `odin test bifrost -vet -strict-style`.

## Phase 2: Z-Sorted Rasterizer, 50% RGB Dimming & ANSI Diff Emitter (`bifrost/renderer.odin`)
- [x] Implement `Color`, `Style_Flags`, `Cell`, `Backdrop_Mode`, `Paint_Spec`, `Modal_Spec`, `Screen` double-buffer lifecycle, and scoped `ui_modal` in `bifrost/renderer.odin`.
- [x] Implement `render_layout` with in-place 50% RGB bit-shift dimming (`dim_rect_backdrop`), clipped background/border/title/scrollbar/text/cursor rasterization, and `screen_diff_ansi` with DEC Mode 2026 synchronized output.
- [x] Verify renderer and backdrop dimming tests (`test_render_layout_and_incremental_diff`, `test_z_layer_sorting_and_backdrop_dimming`) pass with zero memory leaks.

## Phase 3: Z-Aware Input, Scoped Focus & Mouse Hit-Testing (`bifrost/input.odin`)
- [ ] Implement `Key_Code`, `Mod_Flags`, `Key_Event`, `Mouse_Event`, `Input_Event`, `Input_State`, `ui_button`, and query helpers (`was_activated`, `is_focused`, `is_hovered`, `was_modal_dismissed`) in `bifrost/input.odin`.
- [ ] Implement `resolve_input`, `reconcile_focus` (with 8-deep `focus_history`), `cycle_focus_within_scope`, `cycle_focus_scope`, `hit_test_point`, and `apply_input_highlights`.
- [ ] Verify scoped focus and modal capture tests (`test_scoped_tab_and_modal_input_capture`) pass with zero memory leaks.

## Phase 4: Virtualized `xitdb` Scrolling & UTF-8 Text Input Filtering (`bifrost/scroll.odin`, `bifrost/text_input.odin`)
- [ ] Implement `Scroll_Slot`, `Virtual_Slice`, scoped `ui_virtual_list`, `sync_scroll_viewports`, `hit_test_scrollable`, mouse/keyboard scroll handlers, and `draw_vertical_scrollbar` in `bifrost/scroll.odin`.
- [ ] Implement `Text_Input_Slot`, `ui_text_input`, UTF-8 codepoint cursor editing, Telescope-style `linked_list_id` forwarding, and `Xitdb_Filter` in `bifrost/text_input.odin`.
- [ ] Verify 100,000-row virtualized scrolling and real-time UTF-8 filtering tests (`test_virtual_xitdb_scroll_and_modal_wheel_blocking`, `test_utf8_text_input_and_realtime_xitdb_filtering`) pass with zero memory leaks.

## Phase 5: Interactive Split-Pane Dividers, Keybinding Router & Command Palette (`bifrost/splitter_keymap.odin`, `bifrost/command_palette.odin`)
- [ ] Implement `Splitter_Slot`, `get_split_size`, `ui_splitter`, same-frame drag/keyboard geometry updates (`apply_splitter_size_immediate`), and the 3-tier keybinding router (`bind_key`, `bind_splitter_key`, `dispatch_keybindings`) in `bifrost/splitter_keymap.odin`.
- [ ] Implement `Command_Palette`, `command_palette_init`, `register_command`, `ui_command_palette`, `update_command_palette`, `fuzzy_score`, and `lookup_action_shortcut` in `bifrost/command_palette.odin`.
- [ ] Verify splitter, keybinding router, and command palette tests (`test_splitter_resize_and_global_keybinding_router`, `test_ctrl_p_fuzzy_command_palette_workflow`) pass with zero memory leaks.

## Phase 6: Sleipnir (`package actor`) + `xitdb` Integration & Terminal Backend (`bifrost/actor_bridge.odin`, `bifrost/terminal.odin`, `examples/xitdb_inspector`)
- [ ] Implement raw POSIX terminal mode, `SIGWINCH` resize detection, and ANSI escape sequence input parsing in `bifrost/terminal.odin`.
- [ ] Implement the Sleipnir + `xitdb` actor bridge (`bifrost/actor_bridge.odin`) and an end-to-end `xitdb` Inspector TUI example (`examples/xitdb_inspector/main.odin`) + integration test suite (`tests/`).
