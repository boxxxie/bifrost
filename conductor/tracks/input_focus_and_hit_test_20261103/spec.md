# Specification: Track 2 — Z-Aware Input Routing, Scoped Focus Domains & Hit-Testing (`input_focus_and_hit_test_20261103`)

## Overview
Build the zero-allocation 3-phase input routing, scoped focus domain navigation, 8-deep LIFO focus restoration stack, modal input capture shield, active press mouse capture, and clipped reverse `z_order` hit-testing engine (`bifrost/input.odin`), verified via 4-layer ATDD executable specifications (`tests/spec_focus_and_input.odin`).

## Reference Patches & Investigation
- **Investigation Report:** [`investigation.md`](./investigation.md)
- [`.tmp/patches/track2_libvaxis_vxfw_focus_routing.patch`](../../../.tmp/patches/track2_libvaxis_vxfw_focus_routing.patch) (`reference/libvaxis`)
- [`.tmp/patches/track2_ftxui_component_modal_focus.patch`](../../../.tmp/patches/track2_ftxui_component_modal_focus.patch) (`reference/ftxui`)

## Functional Requirements (Refined via Investigation)
1. **Input Events, 3-Phase Dispatch & Zero-Allocation State (`bifrost/input.odin`):**
   - `Key_Code`, `Mod_Flags`, `Key_Event`, `Mouse_Button`, `Mouse_Action`, `Mouse_Event`, `Input_Event`, `Event_Phase` (`.Capturing`, `.At_Target`, `.Bubbling`), `Dispatch_Step`, and `Input_State`.
   - Reconstruct `focus_path` and `hover_path` (`root -> target`) and route events through `.Capturing` -> `.At_Target` -> `.Bubbling` with `consume_event` short-circuiting.
   - `Widget_State_Store` (`scroll_state.odin` / `input.odin`) persisting `scroll_offset`/`scroll_max` across frames, pruning unmounted IDs, and re-evaluating stationary cursor hover transitions (`did_mouse_enter` / `did_mouse_leave`) after scroll offset updates.
2. **Nested Modal Focus Stack, `active_press_id` Capture & Clipped Reverse-Z Hit-Testing:**
   - `compute_active_shield_z` discovering the highest mounted `.Capture_Input` `z_layer`, and `focus_history` (`[MAX_FOCUS_HISTORY]Focus_Scope_Entry`) restoring prior scope and widget focus in LIFO order as nested modals (`z=30` over `z=20` over `z=0`) unmount.
   - `active_press_id` mouse capture latching on left `.Press`, routing `.Drag` to `active_press_id` even when the cursor leaves 1-cell splitter/button bounds, suppressing background hover during drag, and firing `clicked_id` on `.Release` iff `hovered_id == active_press_id`.
   - `hit_test_point` walking `ctx.z_order` in reverse (front-to-back), intersecting against both `node.node_clip` and `node.rect` (preventing ghost clicks on scrolled-out children), enforcing `active_shield_z`, and recording `backdrop_clicked_id` for click-outside modal dismissal.
3. **4-Layer ATDD Specifications (`tests/spec_focus_and_input.odin`):**
   - Scoped `Tab`/`Shift+Tab` cycling, `F6` pane switching, 3-level nested modal LIFO focus capture and restoration, `active_press_id` off-axis drag & press-cancel semantics, clipped scroll-viewport hit-testing, and stationary mouse hover transitions on wheel scroll.
