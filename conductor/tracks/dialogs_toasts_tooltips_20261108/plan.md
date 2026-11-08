# Implementation Plan: `dialogs_toasts_tooltips_20261108`

## Phase 1: Red-First `@(scenario)` ATDD Specifications
- [ ] Task: Add `@(scenario)` executable specifications in `tests/spec_dialogs.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`
    - [ ] Add `@(scenario)` specs for `ui_confirm_dialog` focus trapping, `Enter` / `Esc` handling, and pre-modal focus restoration.
    - [ ] Add `@(scenario)` specs for `ui_prompt` text editing inside a modal and result extraction.
    - [ ] Add `@(scenario)` specs for `Toast_Manager` expiration lifecycle and corner stacking.
    - [ ] Add `@(scenario)` specs for `ui_tooltip` hover threshold activation and screen clamping.

## Phase 2: Dialogs, Toasts & Tooltips Implementation (`bifrost/dialogs.odin`)
- [ ] Task: Implement Turnkey Dialogs (`ui_confirm_dialog`, `ui_alert`, `ui_prompt`)
    - [ ] Implement focus trapping modal container and button layout.
    - [ ] Implement `Dialog_Result` state transition machine and focus scope restoration.
- [ ] Task: Implement Toast Notification System (`Toast_Manager`, `ui_toast_stack`)
    - [ ] Implement fixed-capacity toast ring buffer and timer-based expiration.
    - [ ] Implement out-of-flow corner box stack renderer with severity color themes.
- [ ] Task: Implement Hover Tooltips (`ui_tooltip`)
    - [ ] Implement hover duration tracking and geometry placement solver with screen clamp.

## Phase 3: Showcase & Verification
- [ ] Task: Integrate dialogs and toasts into `examples/widget_gallery/main.odin` and verify all test suites
    - [ ] Add buttons to trigger confirm modals, prompts, toasts, and hoverable tooltips in `examples/widget_gallery/main.odin`.
    - [ ] Verify `odin run tools/bifrost_gen -- --atdd tests`, `odin test bifrost`, `odin test tests`, and Windows target checks pass with zero memory leaks.
