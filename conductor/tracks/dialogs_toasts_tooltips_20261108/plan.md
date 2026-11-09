# Implementation Plan: `dialogs_toasts_tooltips_20261108`

## Phase 1: Red-First `@(scenario)` ATDD Specifications
- [x] Task: Add `@(scenario)` executable specifications in `tests/spec_dialogs.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`
    - [x] Add `@(scenario)` specs for `ui_confirm_dialog` focus trapping, `Enter` / `Esc` handling, and pre-modal focus restoration.
    - [x] Add `@(scenario)` specs for `ui_prompt` text editing inside a modal and result extraction.
    - [x] Add `@(scenario)` specs for `Toast_Manager` expiration lifecycle and corner stacking.
    - [x] Add `@(scenario)` specs for `ui_tooltip` hover threshold activation and screen clamping.

## Phase 2: Dialogs, Toasts & Tooltips Implementation (`bifrost/dialogs.odin`)
- [x] Task: Implement Turnkey Dialogs (`ui_confirm_dialog`, `ui_alert`, `ui_prompt`)
    - [x] Implement focus trapping modal container and button layout.
    - [x] Implement `Dialog_Result` state transition machine and focus scope restoration.
- [x] Task: Implement Toast Notification System (`Toast_Manager`, `ui_toast_stack`)
    - [x] Implement fixed-capacity toast ring buffer and timer-based expiration.
    - [x] Implement out-of-flow corner box stack renderer with severity color themes.
- [x] Task: Implement Hover Tooltips (`ui_tooltip`)
    - [x] Implement hover duration tracking and geometry placement solver with screen clamp.

## Phase 3: Showcase & Verification
- [x] Task: Integrate dialogs and toasts into `examples/widget_gallery/main.odin` and verify all test suites
    - [x] Add buttons to trigger confirm modals, prompts, toasts, and hoverable tooltips in `examples/widget_gallery/main.odin`.
    - [x] Verify `odin run tools/bifrost_gen -- --atdd tests`, `odin test bifrost`, `odin test tests`, and Windows target checks pass with zero memory leaks.
