# Implementation Plan: `sleipnir_actor_action_routing_20261104`

## Phase 1: Red-First Actor Bridge Focus Isolation, Action Dispatch & Persistence Specs
- [x] Task: Add deterministic unit and ATDD tests for `actor_bridge.odin` text-capture isolation, actor command routing, and `xitdb` workspace snapshots
    - [x] Add ATDD specs in `tests/spec_actor_tui_integration.odin` verifying that typing `"kafka"` / `"fail"` / `"quit"` inside `"search_box"` or `Command_Palette` does not scroll `vlist`, unpin historical moments, or trigger quit.
    - [x] Add unit/ATDD tests verifying direct UI action $\to$ `sleipnir` worker `actor.PID` message delivery and `save_ui_workspace_to_xitdb` / `load_ui_workspace_from_xitdb` round-trip restoration.

## Phase 2: `actor_bridge.odin` Split-Brain Removal, Two-Pass Reconcile & Actor Action Router
- [x] Task: Refactor `ui_reduce_single_msg` and `ui_coordinator_flush_frame`, and implement typed actor action sinks + `xitdb` workspace persistence
    - [x] Move Inspector shortcuts (`[`/`]`/`f`, `Ctrl+P`, `q`/`Ctrl+Q`) and `vlist` navigation out of `ui_reduce_single_msg` and onto scoped bindings + virtual-list focus handling, preserving `UI_Msg_Scroll_Viewport`, `UI_Msg_Select_Moment`, and `UI_Msg_Palette_Toggle` programmatic messages.
    - [x] Ensure `ui_coordinator_flush_frame` runs `resolve_input` on Frame 0 and runs a second `resolve_input` pass after rebuilding the layout when `pending_inputs` mutates UI tree topology.
    - [x] Implement `bind_actor_action` / `UI_Action_Sink` for zero-glue `actor.send` dispatch on triggered actions, plus `save_ui_workspace_to_xitdb` / `load_ui_workspace_from_xitdb`.

## Phase 3: Actor Example Upgrades & Full End-to-End Verification (`examples/log_monitor/`, `examples/xitdb_inspector/`)
- [x] Task: Upgrade `log_monitor` and `xitdb_inspector` to declarative focus scopes, actor-bound actions, and live hint bars
    - [x] Refactor `examples/log_monitor/main.odin` and `examples/xitdb_inspector/main.odin` to remove manual focus/quit guards and wire worker commands via actor-bound actions.
    - [x] Run `odin test bifrost -vet -vet-packages:bifrost -strict-style`, `odin test tests -vet -vet-packages:bifrost_tests,bifrost -strict-style`, and compile check all 4 examples with zero memory leaks.
