# Project Workflow

## Guiding Principles

1. **The Plan is the Source of Truth:** All implementation work is tracked in the active track's `plan.md`.
2. **Zero-Leak Frame & State Discipline:** All per-frame layout trees, paint maps, and ANSI diff buffers use `context.temp_allocator` (`defer free_all(context.temp_allocator)`), while `Input_State`, `Command_Palette`, and `Screen` double buffers avoid per-frame heap allocations. Every `odin test` suite must pass with zero leaks under Odin's tracking allocator.
3. **Strict Style & Vet Cleanliness:** All packages must pass `odin check` and `odin test` with `-vet -strict-style`.
4. **Headless Deterministic Testing:** Every UI layout, rendering, input, scroll, filter, splitter, and actor-bridge component must be testable headlessly without requiring an interactive TTY.

## Task Workflow

1. Select the next `[ ]` task in the active track's `plan.md` and mark it `[~]`.
2. Write or update deterministic unit/ATDD tests covering the target behavior.
3. Implement idiomatic Odin code in `bifrost/` to satisfy the specification.
4. Run verification:
   - `odin test bifrost -vet -strict-style`
   - `odin test tests`
5. Mark the task `[x]` in `plan.md` and commit changes using Conventional Commits.
