# Implementation Plan: `keymap_chord_dsl_and_ast_gen_20261104`

## Phase 1: Red-First Key-Chord, Sub-Mode, Struct-Tag & AST Codegen Tests
- [x] Task: Write deterministic unit and ATDD tests for the Tier 1 runtime DSL and Tier 2 AST code generator
    - [x] Add unit tests in `bifrost/keymap_dsl_test.odin` covering `parse_key_chord` (`"<C-p>"`, `"g g"`, `"<C-w> l"`, `"q|<C-q>"`), 2-step `pending_chord` matching/cancellation, transient `ui_splitter` `Resize` sub-mode, `core:reflect` struct-tag registration, and `ui_focus_breadcrumb_bar` / `ui_key_hint_bar` output.
    - [x] Add AST codegen tests in `bifrost/codegen/codegen_test.odin` verifying `core:odin/parser` discovery of `@(ui_actions)` / `@(ui_action)` declarations, compile-time invalid-chord diagnostics, and generated `ui_actions_gen.odin` compilation.

## Phase 2: Tier 1 Runtime Key-Chord Micro-DSL, Sub-Modes & Contextual Hint Bar (`bifrost/keymap_dsl.odin`)
- [x] Task: Implement `parse_key_chord`, `pending_chord` state, transient widget sub-modes, `core:reflect` action binder, and live breadcrumb/hint bar widgets
    - [x] Implement `Key_Chord`, `parse_key_chord`, `bind_chord`, and 2-key `pending_chord` resolution inside `Input_State` / `splitter_keymap.odin`.
    - [x] Add per-scope transient sub-mode tracking (including `ui_splitter` `Enter` $\to$ `Resize` $\to$ `Escape` mode) and `ui_scope` `@(deferred_in=...)` ergonomic wrapper.
    - [x] Implement `register_actions_struct` (`core:reflect` struct tags) populating `Keymap_Table` + `Command_Palette` + hint metadata, and implement `ui_focus_breadcrumb_bar` + `ui_key_hint_bar`.

## Phase 3: Tier 2 AST Metaprogramming Generator (`bifrost/codegen/`, `tools/bifrost_gen/`)
- [x] Task: Build `bifrost/codegen` and `tools/bifrost_gen` using `core:odin/parser` and `core:odin/ast`
    - [x] Implement `bifrost/codegen/codegen.odin` and `tools/bifrost_gen/main.odin` (following `deps/sleipnir/tools/sleipnir_gen`), generating static keymap/palette initializers and typed action dispatchers (`ui_actions_gen.odin`) with chord validation.
    - [x] Upgrade `examples/kanban_board/main.odin` to replace manual `Key_Event` literals and static footer strings with the new Chord DSL + live `ui_key_hint_bar`.
    - [x] Verify `odin test bifrost -vet -vet-packages:bifrost -strict-style`, `odin test bifrost/codegen -vet -strict-style`, and `odin test tests -vet -vet-packages:bifrost_tests,bifrost -strict-style` pass with zero leaks.
