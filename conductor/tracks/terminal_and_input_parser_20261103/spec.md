# Specification: Track 4 — POSIX Raw Terminal Backend & ANSI / Kitty / Mouse SGR Parser (`terminal_and_input_parser_20261103`)

## Overview
Build the zero-allocation streaming ANSI / Kitty Keyboard Protocol / Mouse SGR input parser (`bifrost/ansi_parser.odin`) and the POSIX raw terminal lifecycle & `SIGWINCH` self-pipe backend (`bifrost/terminal.odin`), modeled on `reference/libvaxis`.

## Reference Patches & Investigation
- **Investigation Report:** [`investigation.md`](./investigation.md)
- [`.tmp/patches/track4_libvaxis_parser_and_tty.patch`](../../../.tmp/patches/track4_libvaxis_parser_and_tty.patch) (`reference/libvaxis`)

## Functional Requirements (Refined via Investigation)
1. **Zero-Allocation Streaming Escape Sequence Parser (`bifrost/ansi_parser.odin`):**
   - Pure byte-slice state machine `parse_ansi_input(buf: []byte, is_timeout: bool) -> (Input_Event, int, Parse_Status)` where `Parse_Status` is `{.Ok, .Need_More, .Ignored, .Malformed}`.
   - Parses bare `ESC` timeout disambiguation (`is_timeout == true`), `Alt+<utf8>`, legacy CSI/SS3 sequences (`\x1b[A`, `\x1bOP`, `\x1b[1;5C`), CSI tilde keys, Kitty Keyboard Protocol (`\x1b[<cp>:<shifted>:<base>;<mods>:<event>;<text>u`), Mouse SGR 1006 (`\x1b[<btn;col;rowM/m`) & legacy X10 mouse, bracketed paste (`\x1b[200~ ... \x1b[201~`), focus in/out (`\x1b[I`, `\x1b[O`), in-band `XTWINOPS` resize (`\x1b[48;...t`), and UTF-8 scalar runes.
2. **POSIX Raw Terminal Backend (`bifrost/terminal.odin`):**
   - `termios` raw mode entry/restoration, `ioctl(TIOCGWINSZ)` + non-blocking `SIGWINCH` self-pipe (`resize_pipe: [2]posix.FD`) multiplexed via `posix.poll`, and atomic setup/teardown sequences (`?1049h`, `?1000h?1002h?1006h`, `?2004h`, `?1004h`, `>1u` / `<u`, `?25l` / `?25h`).
3. **4-Layer ATDD Specifications (`tests/spec_ansi_parser.odin`):**
   - Deterministic byte-stream fuzz & scenario specs covering 1-byte split reads, bare `ESC` timeout vs `ESC [` lookahead, Kitty shifted/ctrl/release chords, SGR mouse drags/wheel events, and bracketed paste bursts without needing a live TTY.
