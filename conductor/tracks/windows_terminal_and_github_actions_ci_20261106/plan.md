# Implementation Plan: `windows_terminal_and_github_actions_ci_20261106`

## Phase 1: Cross-Platform Terminal Split & Windows Console VT Backend
- [x] Task: Separate POSIX and Windows terminal implementations behind a unified `Terminal` interface (`bifrost/terminal.odin`, `bifrost/terminal_posix.odin`, `bifrost/terminal_windows.odin`)
    - [x] Move POSIX `termios`, `ioctl(TIOCGWINSZ)`, and `SIGWINCH` self-pipe logic into `when ODIN_OS != .Windows` / `terminal_posix.odin`.
    - [x] Implement Windows `Terminal` raw mode (`GetConsoleMode`/`SetConsoleMode` with `ENABLE_VIRTUAL_TERMINAL_PROCESSING` & `ENABLE_VIRTUAL_TERMINAL_INPUT`, `SetConsoleOutputCP(65001)`), `terminal_winsize` (`GetConsoleScreenBufferInfo`), and `poll_next_event` in `terminal_windows.odin`.
    - [x] Make pipe-based terminal polling helpers in `tests/driver_bifrost.odin` and `tests/dsl_bifrost.odin` cross-platform across POSIX and Windows.

## Phase 2: Multi-OS GitHub Actions CI Matrix (`.github/workflows/ci.yml`)
- [x] Task: Create `.github/workflows/ci.yml` for `ubuntu-latest`, `macos-latest`, and `windows-latest`
    - [x] Configure Odin toolchain setup and recursive submodule checkout (`deps/sleipnir`, `deps/xitdb`).
    - [x] Run `tools/bifrost_gen -- --atdd tests`, unit test suites (`bifrost`, `bifrost/codegen`), ATDD suite (`tests`), and headless verification for all 5 `examples/*` TUIs across all matrix OS targets.
