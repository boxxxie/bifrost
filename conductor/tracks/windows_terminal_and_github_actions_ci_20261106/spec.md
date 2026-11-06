# Specification: Track 10 — Windows ConPTY / Console VT Terminal Backend & Multi-OS GitHub Actions CI Matrix (`windows_terminal_and_github_actions_ci_20261106`)

## Overview
Extend `bifrost`'s terminal backend (`bifrost/terminal.odin`) to support native Windows builds via Win32 Console Virtual Terminal sequences (`SetConsoleMode` with `ENABLE_VIRTUAL_TERMINAL_PROCESSING` and `ENABLE_VIRTUAL_TERMINAL_INPUT`) and console buffer resize events, and provision a multi-OS GitHub Actions CI matrix (`.github/workflows/ci.yml`) that verifies codegen, unit suites, `@(scenario)` ATDD suites, and headless example TUIs across Linux, macOS, and Windows.

## Reference Implementations
- `reference/libvaxis` (`src/vaxis/tty.zig` — Windows Console handle setup, VT input/output modes, and resize event polling)
- `reference/bubbletea` (`tty_windows.go`, `termios_windows.go`, `signals_windows.go`)

## Functional Requirements

1. **Cross-Platform Terminal Abstraction (`bifrost/terminal.odin`, `bifrost/terminal_posix.odin`, `bifrost/terminal_windows.odin`):**
   - Guard POSIX-only imports (`core:sys/posix`, `termios`, `ioctl(TIOCGWINSZ)`, `SIGWINCH` self-pipe) behind `when ODIN_OS != .Windows` (or split into `terminal_posix.odin` and `terminal_windows.odin` sharing the unified `Terminal` API).
   - Implement the Windows `Terminal` backend using `core:sys/windows`:
     - Acquire `STD_INPUT_HANDLE` and `STD_OUTPUT_HANDLE`, save original console modes (`GetConsoleMode`) and codepages (`GetConsoleCP`, `GetConsoleOutputCP`), and restore them atomically in `terminal_deinit`.
     - Enable UTF-8 codepages (`SetConsoleCP(65001)`, `SetConsoleOutputCP(65001)`), output VT processing (`ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN`), and input VT / resize / mouse processing (`ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_WINDOW_INPUT | ENABLE_EXTENDED_FLAGS`).
     - Implement `terminal_winsize` via `GetConsoleScreenBufferInfo` (`srWindow` width/height).
     - Implement `poll_next_event` on Windows with `WaitForSingleObject` / `ReadConsoleInputW` / `ReadFile` to feed `Input_Stream_Reader` with the same 25ms `ESC_DISAMBIGUATE_TIMEOUT_MS` bare-`ESC` timeout disambiguation and `WINDOW_BUFFER_SIZE_EVENT` $\to$ `Resize_Event` translation.
   - Ensure `tests/driver_bifrost.odin` and `tests/spec_ansi_parser.odin` compile and pass on both POSIX and Windows (using anonymous Win32 `CreatePipe` or guarded POSIX pipe helpers for non-blocking pipe poll tests).

2. **GitHub Actions Multi-OS CI Pipeline (`.github/workflows/ci.yml`):**
   - Configure a matrix workflow across `ubuntu-latest`, `macos-latest`, and `windows-latest` with submodules checked out (`submodules: recursive`).
   - Execute the full verification pipeline on every push and pull request:
     1. `odin run tools/bifrost_gen -- --atdd tests` (AST ATDD codegen + `@(scenario)` Layer 1 purity check)
     2. `odin test bifrost -vet -strict-style -vet-packages:bifrost`
     3. `odin test bifrost/codegen -vet -strict-style`
     4. `odin test tests -custom-attribute:scenario -vet -strict-style -vet-packages:bifrost,bifrost_tests`
     5. Deterministic headless walkthroughs for all 5 example TUIs (`examples/widget_gallery`, `examples/kanban_board`, `examples/log_monitor`, `examples/xitdb_inspector`, `examples/keymap_workbench`).

## Acceptance Criteria
- `bifrost`, `tests`, and all 5 `examples/*` compile and pass with `-vet -strict-style` on Linux, macOS, and Windows in GitHub Actions CI.
- Zero memory leaks across all unit and `@(scenario)` ATDD specifications on all 3 target OSes.
