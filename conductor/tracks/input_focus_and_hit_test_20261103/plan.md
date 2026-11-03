# Implementation Plan: `input_focus_and_hit_test_20261103`

## Phase 1: Reference Investigation & ATDD Red-First Specs
- [x] Review findings from `track2_libvaxis_vxfw_focus_routing.patch` and `track2_ftxui_component_modal_focus.patch` (documented in [`investigation.md`](./investigation.md)).
- [ ] Add focus, nested modal LIFO capture, `active_press_id` drag, clipped hit-testing, and stationary scroll-hover ATDD scenarios in `tests/spec_focus_and_input.odin` and DSL steps in `tests/dsl_bifrost.odin`.

## Phase 2: Input Routing, 3-Phase Dispatch, LIFO Focus History & Clipped Reverse-Z Hit-Testing (`bifrost/input.odin`)
- [ ] Implement `Input_Event`, `Event_Phase`, `Dispatch_Step`, `Input_State`, `Widget_State_Store`, `ui_button`, and query helpers (`was_activated`, `is_focused`, `is_hovered`, `did_mouse_enter`, `did_mouse_leave`, `was_modal_dismissed`).
- [ ] Implement `resolve_input`, `reconcile_focus` (with 8-deep LIFO `focus_history` and `compute_active_shield_z`), `cycle_focus_within_scope`, `cycle_focus_scope`, `hit_test_point` (checking both `node_clip` and `rect`), `active_press_id` capture, and `apply_input_highlights`.
- [ ] Verify all unit tests and ATDD specs pass with zero memory leaks.
