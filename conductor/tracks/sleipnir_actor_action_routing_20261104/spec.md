# Specification: Track 9 — Sleipnir Actor Command Routing, `actor_bridge` Focus Unification & `xitdb` Persistence (`sleipnir_actor_action_routing_20261104`)

## Overview
Unify Bifrost's **Sleipnir Actor Runtime Bridge** (`bifrost/actor_bridge.odin`) with the new Hierarchical Focus Scope Tree and Key-Chord DSL—fixing the live reducer split-brain bug where `ui_reduce_single_msg` intercepts keys before focus/text-capture evaluation, enforcing Frame-0 + two-pass `resolve_input` reconciliation in `ui_coordinator_flush_frame`, routing triggered UI actions directly into typed `sleipnir` `actor.PID` mailboxes without manual polling glue, and supporting optional `xitdb` persistence of workspace layout/focus state.

## Reference Blueprint & Patches
- **Investigation Report:** [`investigation.md`](./investigation.md)
- **Master Architecture Guide:** [`docs/NAVIGATION_AND_DSL_GUIDE.md`](../../../docs/NAVIGATION_AND_DSL_GUIDE.md)
- [`.tmp/patches/track9_libvaxis_vxfw_commands_focus.patch`](../../../.tmp/patches/track9_libvaxis_vxfw_commands_focus.patch) (`reference/libvaxis` — `vxfw.Command` side-effects & `.focus_out` drag/hover reset)
- [`.tmp/patches/track9_bubbletea_batch_seq_filter.patch`](../../../.tmp/patches/track9_bubbletea_batch_seq_filter.patch) (`reference/bubbletea` — `Batch` vs `Sequence` commands & `WithFilter` quit interception)
- [`.tmp/patches/track5_sleipnir_actor_api.patch`](../../../.tmp/patches/track5_sleipnir_actor_api.patch) (`deps/sleipnir` — `actor.PID`, `actor.send` batch splicing, `Envelope` pooling)
- [`.tmp/patches/track9_xitdb_marshal_dsl.patch`](../../../.tmp/patches/track9_xitdb_marshal_dsl.patch) (`deps/xitdb` — Reflection marshaling & `xitdb` transaction DSL)

## Functional Requirements

1. **Eliminate Reducer Key Split-Brain & Fix Two-Pass Reconciliation (`bifrost/actor_bridge.odin`):**
   - Remove unconditional key mutations in `ui_reduce_single_msg` (`j`/`k`/`Up`/`Down`/`Page_Up`/`Page_Down`/`Home`/`End` on `state.vlist`, `[`/`]`/`f` on `pinned_moment`, `Ctrl+P` toggle, and the hardcoded `!state.palette_open && !is_focused(&state.input, "search_box")` quit guard).
   - Register all built-in Inspector shortcuts (`[`/`]`/`f`, `Ctrl+P`, `q`/`Ctrl+Q`) as proper scoped/global bindings on `UI_Coordinator_State`'s `Input_State` so typing `"kafka"` or `"fail"` inside `"search_box"` or `Command_Palette` never mutates background viewports or unpins historical moments.
   - Update `ui_coordinator_flush_frame`:
     - Always run `resolve_input(&state.input, &state.layout_ctx)` on Frame 0 even when `pending_inputs` is empty so initial `.Default_Focus` and `focus_node_path` mount cleanly.
     - When `len(state.pending_inputs) > 0`, run a second `resolve_input(&state.input, &state.layout_ctx)` reconciliation pass after the re-render pass so newly opened `.Trap_Focus` modals (e.g. `Command_Palette`) acquire focus and `editing_id` on the **exact same frame**.

2. **Direct UI Action $\to$ `sleipnir` Actor Command Routing, Side-Effects & Quit Filter (`bifrost/actor_bridge.odin`, `bifrost/input.odin`):**
   - Introduce a lightweight `UI_Action_Sink` / callback & `actor.PID` dispatch table on `UI_Coordinator_State` (`bind_actor_action` / `on_ui_action`) supporting single and batched (`actor.send` slice-spliced) worker dispatches with zero manual `if was_action_triggered(...)` polling loops in app code.
   - Add `vxfw`-style pure `UI_Side_Effect` emissions (`Request_Focus`, `Copy_OSC52`, `Set_Title`, `Request_Quit`), terminal `.focus_out` (`CSI O`) auto-release of `active_press_id` + `hovered_id` (preventing stuck splitter drags on Alt-Tab), and a Bubble-Tea-style `quit_filter` callback so dirty/unsaved apps can intercept `UI_Msg_Quit` to open a `.Trap_Focus` confirmation modal.

3. **Optional `xitdb` Workspace State Snapshot (`bifrost/actor_bridge.odin`):**
   - Provide `save_ui_workspace_to_xitdb` / `load_ui_workspace_from_xitdb` helpers that persist and restore `splitter_sizes`, `scope_memory` (`H`/`H*`), and pinned collection/moment preferences in `xitdb` across sessions.

4. **Upgrade Actor-Driven Examples (`examples/log_monitor/main.odin`, `examples/xitdb_inspector/main.odin`):**
   - Remove manual `!palette_open && !is_focused(..., "search_box")` workarounds from `log_monitor`, wire background worker commands through declarative actor-bound UI actions, and render live contextual focus/shortcut hints in both actor-driven TUI apps.

## Acceptance Criteria
- All existing ATDD tests in `tests/spec_actor_tui_integration.odin` and `bifrost/actor_bridge_test.odin` continue passing (`f` unpinning when not editing text, `Ctrl+P` opening Command Palette on the same frame, 1,000-commit burst coalescing, 100k-row `xitdb_slice_viewport`).
- New deterministic ATDD specs verify:
  1. Typing `"j"`, `"k"`, `"f"`, `"["`, `"]"`, and `"q"` inside `"search_box"` or an open `Command_Palette` edits filter text **without** scrolling `vlist`, unpinning `pinned_moment`, or quitting.
  2. Triggering an actor-bound UI shortcut or Command Palette item dispatches a typed message directly to a `sleipnir` worker actor mailbox.
  3. Saving and restoring UI workspace state (`splitter` widths + `scope_memory` focus targets) round-trips cleanly through `xitdb` with zero memory leaks.
