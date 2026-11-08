# Implementation Plan: `rich_text_and_markdown_20261108`

## Phase 1: Red-First `@(scenario)` ATDD Specifications
- [ ] Task: Add `@(scenario)` executable specifications in `tests/spec_paragraph.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`
    - [ ] Add `@(scenario)` specs for soft word-wrapping algorithm preserving whitespace and breaking only at word boundaries.
    - [ ] Add `@(scenario)` specs for multi-span inline styling across line breaks.
    - [ ] Add `@(scenario)` specs for markdown AST parsing of headers, bullet lists, blockquotes, and code fences.

## Phase 2: Paragraph & Markdown Implementation (`bifrost/paragraph.odin`)
- [ ] Task: Implement `ui_paragraph` Word-Wrapping Engine
    - [ ] Implement line breaker with UTF-8 display width calculation and wrap policies (`.Word`, `.Char`).
    - [ ] Implement text alignment (`.Left`, `.Center`, `.Right`) and span cell rasterization.
- [ ] Task: Implement `ui_markdown` Document Viewer
    - [ ] Implement zero-allocation markdown scanner and block token generator.
    - [ ] Implement header, list, blockquote, and code-block container composition.

## Phase 3: Showcase & Verification
- [ ] Task: Integrate markdown viewer into `examples/widget_showcase/main.odin` and verify all test suites
    - [ ] Render interactive in-app documentation and markdown viewer tab in `examples/widget_showcase/main.odin`.
    - [ ] Verify `odin run tools/bifrost_gen -- --atdd tests`, `odin test bifrost`, `odin test tests`, and Windows target checks pass with zero memory leaks.
