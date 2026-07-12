# Debugging Oscar64 C code for the Commander X16 in VSCode

This document explains how C **source-level** debugging works in this repo —
setting breakpoints on C lines, stepping, inspecting registers and variables
in the VSCode editor — for programs compiled with **Oscar64** and run on the
**Commander X16**, and exactly what was changed to make it work.

## TL;DR

- The **VS64** VSCode extension already contains a complete source-level
  debugger. It talks to emulators over **VICE's binary monitor protocol**
  (a TCP protocol), via its `"vice"` debug type. Its debugger UI, its parsing
  of Oscar64's `.dbj` debug info, and its C-line↔address mapping are all
  emulator-agnostic.
- No stock X16 emulator speaks that protocol, so VS64 could never drive one
  for real debugging.
- **The fix: a fork of the Box16 emulator (`box16-src/`) with a VICE binary
  monitor server added.** VS64 attaches to it and everything works.
- **Oscar64 was not modified.** It already emits the `.dbj` debug info (with
  `-g`) that VS64 and, now, the emulator consume.
- The rest is configuration in this repo (`project-config.json`, `.vscode/`).

```
VSCode  ──DAP──►  VS64 extension  ──VICE binary monitor (TCP 6502)──►  Box16 fork
  editor UI         debugger core                                       emulator
                    + Oscar64 .dbj
```

## Daily use

1. Set breakpoints on C lines in a source file (e.g. `examples/bounce.c`).
2. Press **F5** with **"Attach to Box16 (binary monitor)"** selected in the
   Run and Debug panel (Ctrl+Shift+D).

That single F5 (via its `preLaunchTask`) builds the PRG, kills any stale
emulator, launches the Box16 fork with `-binarymonitor`, waits for it to be
ready, attaches, restarts the program under the debugger, and stops at the
first breakpoint reached. Then F10 steps over, F11 steps into, Shift+F11
steps out, F5 continues; registers (a/x/y/pc/sp/fl) and global/static
variable watches are live in the editor.

Because VS64 resets the machine on attach, **every attach is a clean run from
power-on** — you can breakpoint the very first line of `main()` (or Oscar64's
`crt.c` startup) and it will stop there before any of your code runs.

## Why this architecture

VS64 ships three debug types: `"6502"` (its own bare-CPU emulator — no VERA,
no KERNAL, so real X16 programs hang), `"vice"` (attaches to a VICE emulator
over the binary monitor), and `"x16"` (just spawns x16emu, run-only, no live
debugging). Only the `"vice"` path is a real source-level debugger, and it is
written against a documented wire protocol whose register set and memory
banks are **discovered at runtime** — it hardcodes nothing C64-specific. That
means any emulator implementing the protocol can be debugged by it. So the
cheapest path to X16 C debugging was not to write a VSCode extension, but to
teach an X16 emulator the protocol VS64 already speaks.

Box16 was chosen over x16emu because it is C++ with an existing debugger core
(breakpoints, stepping, pause/resume) to hook the protocol onto, and builds
with Visual Studio 2022. License is 2-clause BSD, so forking is fine.

## Changes to Box16 (the `box16-src/` fork)

All work is on the fork's `binary-monitor` branch. `git log` there tells the
story; the summary:

### New files
- **`src/binary_monitor.h` / `src/binary_monitor.cpp`** — the entire VICE
  binary monitor v2 TCP server (~1300 lines). Plain winsock (the fork force-
  includes `windows.h`, which precludes `winsock2.h`, so it uses the winsock
  1.1 API — sufficient here). Single client, non-blocking, serviced from the
  emulator main loop between instructions, so **no locking** is needed against
  Box16's debugger core or ImGui overlay.
- **`test/binmon_test.py`, `vs64_step_test.py`, `stepover_test.py`,
  `repro_verafill.py`** — stdlib-Python protocol tests (no emulator GUI
  needed): they speak the exact byte sequences VS64 sends and assert
  behavior, including replaying VS64's own step-completion algorithm against
  the real `.dbj`.

### Modified files
- **`src/main.cpp`** (+11 lines) — `binary_monitor_init()` after
  `machine_reset()`, `binary_monitor_shutdown()` on exit, and two
  `binary_monitor_process()` poll points in `emulator_loop()` (every
  iteration while paused; throttled while running).
- **`src/options.cpp` / `src/options.h`** — the `-binarymonitor` and
  `-binarymonitoraddress ip4://host:port` command-line flags (VICE-compatible
  names).
- **`build/vs2022/box16.vcxproj` / `.filters`** — register the new files.

### The protocol subset implemented
Framing is VICE API v2: request `02 02 <u32 len> <u32 id> <u8 cmd> body`,
response `02 02 <u32 len> <u8 type> <u8 err> <u32 id> body`, events use id
`0xFFFFFFFF`. Commands: MEMORY_GET/SET, CHECKPOINT_GET/SET/DELETE/LIST/TOGGLE,
CONDITION_SET, REGISTERS_GET/SET, ADVANCE_INSTRUCTIONS, EXECUTE_UNTIL_RETURN,
PING, BANKS_AVAILABLE, REGISTERS_AVAILABLE, VICE_INFO, EXIT, QUIT, RESET,
AUTOSTART. Events: CHECKPOINT_INFO, REGISTER_INFO, STOPPED, RESUMED.
Checkpoints map onto Box16's existing `debugger_add/remove/activate/
deactivate_breakpoint`; registers map onto `state6502`.

### The five behaviors that took real debugging to get right
These were each found by reverse-engineering VS64's minified bundle and/or a
wire trace, and each has a regression test:

1. **Reset reloads the program.** VS64 sends RESET then AUTOSTART on *every*
   connect, attach included (its handler doesn't gate this on the attach
   flag). RESET therefore re-arms Box16's boot loader (`hypercalls_init()`)
   from the `-prg`, so the program is injected and RUN again — otherwise
   attach lands at the bare BASIC `READY.` prompt.
2. **Reset leaves the machine paused.** VS64 installs breakpoints *after* the
   reset (at configurationDone) and only then resumes with EXIT. So RESET
   holds the CPU paused at the reset vector; if it resumed immediately, the
   program would run past `main()` before any breakpoint was armed and a
   breakpoint on the first line would never hit.
3. **A REGISTER_INFO event on every stop.** VS64's step-completion reads the
   *cached* CPU PC, which is refreshed only by a REGISTER_INFO message. Real
   VICE sends one unsolicited on every stop; without it VS64's cached PC
   stays stale, `getAddressInfo()` returns null, and stepping single-steps
   forever (the program appears to just run). The fork now emits
   REGISTER_INFO before every STOPPED.
4. **Line-granular stepping (the `__asm{}` fix).** VS64 steps one *instruction*
   at a time over the socket and checks the source line after each. A pure
   `__asm{}` function like `x16_vera_fill` (a 256-iteration loop that is one
   source line) meant hundreds of network round-trips per step — which
   hung/"crashed" the session. The fork loads Oscar64's `.dbj` line table
   (auto-derived from the `-prg` path, parsed by a line-prefix scan — no JSON
   library) and makes each ADVANCE advance a whole **source line** internally:
   it single-steps inside the emulator until the line changes, a breakpoint is
   hit, or a safety bound is reached, then reports one STOPPED. So one client
   step = one C line, an `__asm{}` block steps in ~16 ms, and both F10 and F11
   step asm regions as line units. Falls back to single-instruction stepping
   if no `.dbj`.
5. **stdout flush + kill-stale + readiness handshake** — small robustness
   fixes so the one-press F5 flow reliably starts a fresh emulator and
   attaches at the right moment (see `.vscode/tasks.json`).

### Diagnostics
Set the env var `BOX16_BINMON_LOG=<path>` and the fork logs every rx/tx frame
plus the resulting pc/paused state — the tool that pinpointed several of the
bugs above.

## Changes to Oscar64

**None.** Oscar64 is used as-is. What matters:
- Build with `-g` (debug info) so it emits `build/<name>.dbj` — a JSON file
  with, per function, an address→C-line table plus global/static variables
  and types. VS64 parses it for breakpoints/variables; the Box16 fork parses
  its line table for line-granular stepping.
- Build with `-tm=x16` (see `project-config.json`, which also works around a
  VS64 bug where the `machine` attribute never reaches the compiler) and stay
  on an `-O0`/`-O1` build (`-O2`/`-O3` crash Oscar64 1.32.272 on this code).
  These are documented in `README.md`.

## Configuration files in this repo

- **`project-config.json`** — VS64 project: `toolkit: oscar64`, sources, and
  the `-tm=x16` / `-O1` flags.
- **`.vscode/settings.json`** — points VS64 at the repo-local `oscar64/` and,
  for the run-only `"x16"` launch type, `emulator/x16emu.exe`.
- **`.vscode/tasks.json`** — build task, `kill stale box16`, and the
  background `debug in Box16 (binary monitor)` task that launches the fork
  and signals readiness by watching its stdout.
- **`.vscode/launch.json`** — the `"vice"` **attach** config
  `Attach to Box16 (binary monitor)` (localhost:6502) with the
  `preLaunchTask` that makes F5 one-press.

## Rebuilding and testing the fork

Requires Visual Studio 2022 with the Desktop C++ workload.

```powershell
# Build (Release x64)
& "$(& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -find MSBuild\**\Bin\MSBuild.exe)" `
  box16-src\build\vs2022\box16.sln -p:Configuration=Release -p:Platform=x64 -m

# Protocol tests: start the emulator with the monitor, then run the suite
box16-src\build\vs2022\out\x64\Release\box16.exe -ignore_ini -binarymonitor `
  -rom emulator\rom.bin -prg build\bounce.prg -run -sym build\bounce.lbl
python box16-src\test\binmon_test.py --lbl build\bounce.lbl --prg build\bounce.prg
```

## Known limitations

- **Main memory (64 KB CPU view) only** for memory reads — fine for Oscar64
  programs, which live below `$9F00`.
- **Conditional breakpoints** are accepted but fire unconditionally.
- **Only attach mode** is wired in this repo (the task starts the emulator).
- **Local variables**: Oscar64's `.dbj` carries no per-function locals in this
  version, so inspect globals/statics or the memory view.
- **F11 on a call to a pure-`__asm{}` function still enters it** (stops at its
  first asm line) — the emulator can't tell a pure-asm function from a C one
  to auto-skip it. Once inside, stepping is fast; F10 on the call steps over
  it entirely.
- Box16 nr48 vs the repo's R49 ROM: the fork is built from Box16 master, which
  runs the R49 ROM fine; if something looks off in Box16, suspect version skew
  first.
