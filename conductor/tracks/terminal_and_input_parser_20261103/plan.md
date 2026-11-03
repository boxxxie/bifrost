# Implementation Plan: `terminal_and_input_parser_20261103`

## Phase 1: Reference Investigation & ATDD Red-First Specs
- [x] Review findings from `track4_libvaxis_parser_and_tty.patch` (documented in [`investigation.md`](./investigation.md)).
- [ ] Write deterministic parser ATDD specifications in `tests/spec_ansi_parser.odin`.

## Phase 2: Streaming ANSI / Kitty / Mouse SGR Parser & POSIX TTY (`bifrost/ansi_parser.odin`, `bifrost/terminal.odin`)
- [ ] Implement `parse_ansi_input` and `Input_Stream_Reader` in `bifrost/ansi_parser.odin`.
- [ ] Implement POSIX `Terminal` raw mode, `SIGWINCH` self-pipe watcher (`poll_next_event`), and atomic capability sequences in `bifrost/terminal.odin`.
- [ ] Verify all unit tests and ATDD specs pass with zero memory leaks.
