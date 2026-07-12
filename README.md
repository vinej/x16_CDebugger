# C and assembly debugging for the Commander X16 with VS64

Version Alpha 0.1: need more testing, but seems to work. 

******************************
--> This repo is about a feature for debugging Commander X16 programs directly into VSCode step by step with F10, F11, Shift F11 and F5 — in C (Oscar64, cc65, llvm-mos) and in native assembly (ACME, ca65, KickAssembler)
******************************

This repo is set up for **C and assembly development targeting the Commander
X16**, with the
**[VS64](https://marketplace.visualstudio.com/items?itemName=rosc.vs64) VSCode
extension** for build/run/debug integration. Six toolchains are supported,
one project folder each:

* **C**: [Oscar64](https://github.com/drmortalwombat/oscar64),
  [cc65](https://cc65.github.io/) and
  [llvm-mos](https://github.com/llvm-mos/llvm-mos-sdk), building against the
  [x16clib](https://github.com/vinej/x16_clib) C library;
* **assembly**: [ACME](https://sourceforge.net/projects/acme-crossass/),
  ca65 and [KickAssembler](http://theweb.dk/KickAssembler/), building against
  the [x16lib](https://github.com/vinej/x16_library) assembly library.

The walkthrough below uses the bounce demo — a sprite bouncing around the
screen with PSG and YM2151 sound — as the working example: `bounce.c` for
the C toolchains, `bounce.asm` for the assembly ones (all six builds run the
same demo).

Nothing has to be installed system-wide except the VS64 extension itself —
but the third-party pieces (compilers, emulators, support library, docs) are
**not tracked in this repo**: after cloning, set them up once as described in
[Setup](#setup).

## What's where

The repo hosts **one VS64 project per toolchain**, each in its own subfolder
that you open as its **own VSCode workspace root** (VS64 reads
`project-config.json` only from the workspace root, so the two projects
cannot share a window):

| Path | What it is |
|---|---|
| `oscar64/` | **The Oscar64 project** — open this folder in VSCode. Contains `project-config.json`, `.vscode/` (VS64 settings, tasks, launch configs), `examples/` (`hello.c`, `numbers.c`, `bounce.c`), `src_oscar64/x16/` (x16clib, Oscar64 port — header-driven: each header ends in `#pragma compile(...)`, so including it pulls the implementation in), `build/` (output: `bounce.prg` + Oscar64 listing/debug files) and `build_oscar64.ps1` (stand-alone CLI build/run/test script, no VSCode needed) |
| `cc65/` | **The cc65 project** (C) — same idea for cc65; the one toolchain whose debugger shows **local variables**; see [Debugging with the cc65 toolchain](#debugging-with-the-cc65-toolchain) |
| `llvm/` | **The llvm-mos project** (C) — same idea for llvm-mos; see [Debugging with the llvm-mos toolchain](#debugging-with-the-llvm-mos-toolchain) |
| `acme/` | **The ACME project** (assembly) — x16lib's reference dialect; see [Debugging assembly programs](#debugging-assembly-programs-acme-ca65-kickassembler) |
| `ca65/` | **The ca65 project** (native assembly, not C) — same idea, ca65 dialect of x16lib |
| `kickass/` | **The KickAssembler project** (assembly) — same idea, KickAss dialect of x16lib; needs Java |
| `prog8/` | **The Prog8 project** — build/run tasks + *symbolic* debugging in Box16 (no F5 source-level debugging: VS64 has no prog8/64tass toolkit); see [Prog8](#prog8-build--symbolic-debugging-only) |
| `oscar64-sdk/` | Oscar64 compiler, repo-local copy (v1.32.272, `bin/oscar64.exe`) |
| `cc65-sdk/` | cc65 toolchain, repo-local copy (V2.19) — used by both the `cc65/` and `ca65/` projects |
| `llvm-mos/` | llvm-mos SDK, repo-local full copy (`bin/mos-clang.exe`, `mos-platform/cx16/`, …) |
| `acme-sdk/` | ACME cross-assembler, repo-local copy (`acme.exe`, `ACME_Lib/`) |
| `kickass-sdk/` | KickAssembler, repo-local copy (`KickAss.jar` — Java must be on the PATH) |
| `prog8-sdk/` | Prog8 compiler (`prog8c.jar`, v12.2.1 — needs **Java 11+**) plus `64tass.exe`, repo-local copy |
| `emulator/` | Official X16 emulator (`x16emu.exe`) plus `rom.bin` — shared by both projects |
| `box16/` | [Box16](https://github.com/indigodarkwolf/box16) (nr48.0), an alternative X16 emulator with a much richer built-in debugger |
| `box16-src/` | Box16 fork (branch `binary-monitor`) adding a **VICE binary monitor server** — this is what enables C source-level debugging in VSCode, for both toolchains. Built exe: `build\vs2022\out\x64\Release\box16.exe` |
| `tutorial/` | `oscar64_guide.md` and `userguide.md` for the x16clib library |

## Setup

Setup is the same four steps for both toolchains — only step 3 differs
between Oscar64 and llvm-mos. If you only care about one toolchain, skip the
other's rows in the table and its half of step 3.

### 1. Install the VS64 extension

Install **`rosc.vs64`** from the VSCode marketplace (tested with 2.6.2).
Nothing else is needed system-wide.

### 2. Installing the untracked pieces

The [.gitignore](.gitignore) deliberately keeps every third-party binary and
source tree out of this repo. After cloning, recreate these folders (folder
names and locations must match exactly — the VS64 config, the tasks and
the build script all refer to them):

| Folder | What goes there | Where to get it |
|---|---|---|
| `oscar64-sdk/` | Oscar64 compiler v1.32.272 — install/unpack it so that `oscar64-sdk\bin\oscar64.exe` and `oscar64-sdk\include\` exist | Windows release from [drmortalwombat/oscar64](https://github.com/drmortalwombat/oscar64/releases) |
| `emulator/` | Official X16 emulator: `x16emu.exe` plus `rom.bin` (R49) | Windows zip from [X16Community/x16-emulator releases](https://github.com/X16Community/x16-emulator/releases) — it contains both the emulator and the ROM |
| `oscar64/src_oscar64/` | x16clib, the X16 support library (Oscar64 port); must end up as `oscar64\src_oscar64\x16\*.c/h` | Copy the `src_oscar64/` folder from [vinej/x16_clib](https://github.com/vinej/x16_clib) (the `tutorial/` guides tracked here come from the same repo) |
| `box16-src/` | The Box16 fork with the VICE binary monitor — **required for C source-level debugging** | `git clone -b binary-monitor https://github.com/vinej/box16.git box16-src`, then build it — see [Rebuilding the Box16 fork](#rebuilding-the-box16-fork) |
| `box16/` | *(optional)* Stock Box16 nr48.0 (`Box16.exe`, `SDL2.dll`, `zlibwapi.dll`) for the `run in Box16 (debugger)` task | [indigodarkwolf/box16 releases](https://github.com/indigodarkwolf/box16/releases) |
| `doc/` | *(optional)* X16 reference docs (Programmer's Reference Guide, VERA references) | [X16Community/x16-docs](https://github.com/X16Community/x16-docs) |
| `llvm-mos/` | *(only for the llvm variant)* The **full** llvm-mos SDK — `bin\mos-clang.exe`, `bin\mos-clang++.exe`, `bin\mos-cx16.cfg` and `mos-platform\cx16\include` must all exist; a bare LLVM build (bin/lib/share only) is **not** enough | SDK release from [llvm-mos/llvm-mos-sdk](https://github.com/llvm-mos/llvm-mos-sdk/releases), unpacked so `llvm-mos\bin\mos-clang.exe` exists |
| `cc65-sdk/` | *(only for the cc65 variant)* The cc65 toolchain (V2.19): `bin\`, `include\`, `lib\`, `cfg\`, `asminc\` — the standard install layout | Windows snapshot from [cc65.github.io](https://cc65.github.io/getting-started.html) ([sourceforge builds](https://sourceforge.net/projects/cc65/files/)), unpacked so `cc65-sdk\bin\cc65.exe` exists |
| `cc65/include_ca65/` | *(only for the cc65 variant)* x16clib headers, cc65 port | Copy `include_ca65/` from [vinej/x16_clib](https://github.com/vinej/x16_clib) |
| `cc65/dist_ca65/` | *(only for the cc65 variant)* `x16c.lib`, the prebuilt x16clib archive | Copy `dist_ca65/x16c.lib` from [vinej/x16_clib](https://github.com/vinej/x16_clib) (or rebuild it with that repo's `build_ca65.ps1`) |
| `cc65/src_ca65/` | *(optional, cc65 variant)* x16clib assembly sources — only needed for the [step-into-the-library recipe](#stepping-into-x16clib-under-cc65) | Copy `src_ca65/` from [vinej/x16_clib](https://github.com/vinej/x16_clib) |
| `acme-sdk/` | *(only for the ACME variant)* the ACME cross-assembler: `acme.exe` + `ACME_Lib\` | Copy the `acme/` folder from [vinej/x16_library](https://github.com/vinej/x16_library), or an [ACME release](https://sourceforge.net/projects/acme-crossass/) |
| `kickass-sdk/` | *(only for the KickAssembler variant)* `KickAss.jar` (+ `KickAss.cfg`); **Java must be on the PATH** | Copy the `kickass/` folder from [vinej/x16_library](https://github.com/vinej/x16_library), or [KickAssembler](http://theweb.dk/KickAssembler/) |
| `acme/src_acme/` | *(ACME variant)* x16lib, the X16 assembly support library — reference (ACME) dialect | Copy `src_acme/` from [vinej/x16_library](https://github.com/vinej/x16_library) |
| `ca65/src_ca65/` | *(ca65 variant)* x16lib, ca65 dialect | Copy `src_ca65/` from [vinej/x16_library](https://github.com/vinej/x16_library) — **note: this is x16_library's `src_ca65`, not x16_clib's** |
| `kickass/src_kick/` | *(KickAssembler variant)* x16lib, KickAss dialect | Copy `src_kick/` from [vinej/x16_library](https://github.com/vinej/x16_library) |
| `prog8-sdk/` | *(only for the Prog8 variant)* `prog8c.jar` + `64tass.exe`; prog8c needs **Java 11+** installed | [prog8 releases](https://github.com/irmen/prog8/releases) (`prog8c-<version>-all.jar`, rename to `prog8c.jar`) + a [64tass](https://sourceforge.net/projects/tass64/) Windows build |
| `llvm/include_llvm/` | *(only for the llvm variant)* x16clib headers, llvm-mos port | Copy `include_llvm/` from [vinej/x16_clib](https://github.com/vinej/x16_clib) |
| `llvm/dist_llvm/` | *(only for the llvm variant)* `libx16c.a`, the prebuilt x16clib archive | Copy `dist_llvm/libx16c.a` from [vinej/x16_clib](https://github.com/vinej/x16_clib) (or rebuild it with that repo's `build_llvm.ps1`) |

The remaining ignored paths need nothing from you: every project's `build/`
folder (and `oscar64/build_oscar64/`) is recreated by the first build,
and each project's `.vscode/c_cpp_properties.json` is regenerated by VS64
(the hand-authored `settings.json`, `tasks.json` and `launch.json` *are*
tracked, so the tasks and launch configurations work out of the box).

### 3. Open the project folder and fix its settings paths

Each toolchain is its own VS64 project, opened as its **own workspace
root** — VS64 only reads `project-config.json` from the workspace root, and
the repo root deliberately has none. Do **not** open the repo root to work;
open the project subfolder (each toolchain gets its own VSCode window).

The only per-machine edit is the `vs64.*` absolute paths in each project's
`settings.json`: VS64 does not expand `${workspaceFolder}` in settings, so
they cannot be made portable — replace `c:\quartus\projects\x16_CDebugger`
with your clone location.

Each project's `.vscode\settings.json` names its toolchain with one
setting (each opened in its own window, File → Open Folder…):

| Open as workspace root | Toolchain setting to check | Points at |
|---|---|---|
| `<clone>\oscar64` | `vs64.oscar64InstallDir` | `<clone>\oscar64-sdk` |
| `<clone>\cc65` | `vs64.cc65InstallDir` | `<clone>\cc65-sdk` |
| `<clone>\llvm` | `vs64.llvmInstallDir` | `<clone>\llvm-mos` |
| `<clone>\acme` | `vs64.acmeInstallDir` | `<clone>\acme-sdk` |
| `<clone>\ca65` | `vs64.cc65InstallDir` | `<clone>\cc65-sdk` |
| `<clone>\kickass` | `vs64.kickInstallDir` | `<clone>\kickass-sdk` |

All six also share the same two emulator settings. For example,
[oscar64/.vscode/settings.json](oscar64/.vscode/settings.json) reads:

```jsonc
"vs64.oscar64InstallDir": "c:\\quartus\\projects\\x16_CDebugger\\oscar64-sdk",
"vs64.x16Executable":     "c:\\quartus\\projects\\x16_CDebugger\\emulator\\x16emu.exe",
"vs64.x16Args":           "-rom c:\\quartus\\projects\\x16_CDebugger\\emulator\\rom.bin -scale 2"
```

### 4. First debug (same in both projects)

1. Open the example in the project window — `examples\bounce.c` in the C
   projects, `examples\bounce.asm` in the assembly ones — and set a
   breakpoint on a line (e.g. the first statement of `main`).
2. Press **F5**. The first launch configuration is
   **`Attach to Box16 (binary monitor)`**, which does everything: builds the
   PRG, kills any stale emulator, starts the Box16 fork with the binary
   monitor, waits for it to listen, attaches, restarts the program — and
   stops at your breakpoint. Step with F10/F11/Shift+F11, watch
   globals/statics (e.g. `pos_x`), continue with F5.

If an *x16emu* window appears instead of Box16, the Run and Debug dropdown
(Ctrl+Shift+D) has the wrong configuration selected — pick
**`Attach to Box16 (binary monitor)`** once; VSCode remembers it afterwards.

## The development flow

```
edit .c file  ──►  Ctrl+Shift+B (build)  ──►  F5 (debug in Box16, or run in x16emu)
```

1. **Edit** — open [examples/bounce.c](oscar64/examples/bounce.c). IntelliSense works
   because VS64 generates `.vscode/c_cpp_properties.json` and
   `build/compile_commands.json` from the project file.
2. **Build** — `Ctrl+Shift+B` runs the default VS64 build task. VS64 generates
   a ninja build under `build/` and invokes Oscar64 roughly as:

   ```
   oscar64 -o=build/bounce.prg -n -g -tm=x16 -tf=prg -O0 -O1 -i=src_oscar64 examples/bounce.c
   ```

   (`-n` native 6502 code instead of interpreted bytecode, `-g` debug symbols,
   `-tm=x16` the Commander X16 target.) With `vs64.autoBuild` enabled — as it
   is here — saving a file rebuilds automatically.
3. **Run/Debug** — `F5` runs whichever configuration is selected in
   [.vscode/launch.json](oscar64/.vscode/launch.json):
   * **`Attach to Box16 (binary monitor)`** (the default, first in the
     list) — the full source-level debug flow described in
     [Debugging](#debugging).
   * **`Launch X16 emulator`** (the `"type": "x16"` configuration) — plain
     run, no debugger: builds if needed, then starts
     `x16emu -prg build/bounce.prg -run` plus the `vs64.x16Args`. The bounce
     demo runs frame-locked at 60 Hz; press any key inside the emulator to
     quit.

### Choosing the emulator: standard x16emu or Box16

Both emulators live in the repo and there is a build-and-run task for each
(**Terminal → Run Task…**, defined in [.vscode/tasks.json](oscar64/.vscode/tasks.json)):

| Task | Emulator | Use when |
|---|---|---|
| `run in x16emu (standard)` | `emulator/x16emu.exe` — the official emulator | normal run/test, closest to real hardware behavior |
| `run in Box16 (debugger)` | `box16/Box16.exe` | you want to debug: it loads `build/bounce.lbl` so the debugger shows your function and variable names |

Both tasks trigger the VS64 build first, then launch `build/bounce.prg`
(if you rename the project in `project-config.json`, update the `.prg`/`.lbl`
paths in the tasks too).

The `F5` launch flow always uses the single `vs64.x16Executable` setting —
VS64 cannot select an emulator per launch configuration. It points at the
standard x16emu; to make `F5` start Box16 instead, change
[.vscode/settings.json](oscar64/.vscode/settings.json) to:

```jsonc
"vs64.x16Executable": "c:\\quartus\\projects\\x16_CDebugger\\box16\\Box16.exe",
"vs64.x16Args": "-ignore_ini -rom c:\\quartus\\projects\\x16_CDebugger\\emulator\\rom.bin -sym c:\\quartus\\projects\\x16_CDebugger\\oscar64\\build\\bounce.lbl -scale 2"
```

(Box16 accepts the `-prg <file> -run` arguments VS64 adds automatically, so
everything else keeps working.)

To build a **different example**, change `sources` (and, if you like, `name`)
in [project-config.json](oscar64/project-config.json):

```json
"sources": [ "examples/hello.c" ]
```

### Command line alternative (no VSCode)

The same compile/run is scripted in [build_oscar64.ps1](oscar64/build_oscar64.ps1):

```powershell
.\build_oscar64.ps1 -Source examples\bounce.c -Run   # compile + run windowed
.\build_oscar64.ps1 -Test                            # headless regression suite
```

## How the project file is wired (and why)

[project-config.json](oscar64/project-config.json):

```json
{
    "name": "bounce",
    "toolkit": "oscar64",
    "machine": "x16",
    "format": "prg",
    "sources": [ "examples/bounce.c" ],
    "build": "debug",
    "includes": [ "src_oscar64" ],
    "args": [ "-tm=x16" ],
    "compilerFlags": [ "-O1" ]
}
```

Three entries deserve an explanation — they work around real quirks found
while setting this up:

* **`"args": ["-tm=x16"]` in addition to `"machine": "x16"`** — VS64 2.6.2 has
  a bug in its Oscar64 backend: the `machine` attribute is parsed but never
  actually emitted as `-tm=` on the compiler command line (a broken comparison
  in the generated ninja logic). Without the explicit `-tm=x16` in `args` the
  program would silently be built for the C64. The `machine` attribute is kept
  so the project file does the right thing if a future VS64 fixes this; a
  duplicate `-tm=x16` is harmless.

* **`"build": "debug"`, not `"release"`** — VS64 maps *release* to `-O3` and
  *debug* to `-O0`. **Oscar64 1.32.272 crashes with an access violation at
  `-O2`/`-O3` on this code base** (verified: `-O3` on `bounce.c` crashes the
  compiler). Stay on `debug`.

* **`"compilerFlags": ["-O1"]`** — the compiler flags are appended *after* the
  build-type's `-O0`, and the last `-O` flag wins, so this quietly upgrades
  the debug build to Oscar64's default `-O1` optimization, which is stable and
  already competitive. Verified: `bounce.prg` builds at 2455 bytes and runs.

* **`"includes": ["src_oscar64"]`** — becomes `-i=src_oscar64`, which is how
  `#include <x16/x16.h>` finds the library; the `#pragma compile` lines in the
  headers then pull the matching `.c` files into the whole-program compile.
  Oscar64 finds its own standard headers relative to `oscar64.exe`, so no
  further include paths are needed.

## Debugging

**C source-level debugging in VSCode works — via the Box16 fork in
`box16-src/`.** Neither stock emulator can do it: x16emu and stock Box16 have
no remote-debug protocol, so VS64's real debugger (which speaks VICE's
*binary monitor* TCP protocol) cannot attach to them. The fork adds exactly
that protocol to Box16, and VS64's existing `"vice"` debug type does the
rest — its debugger UI, its Oscar64 `.dbj` debug-info parsing, and its
C-line breakpoint mapping are all emulator-agnostic.

### C source-level debugging (the good path)

One step:

1. Set breakpoints on C lines in [examples/bounce.c](oscar64/examples/bounce.c).
2. **F5** with **`Attach to Box16 (binary monitor)`** selected in the Run
   and Debug dropdown (Ctrl+Shift+D).

That single F5 does everything via its `preLaunchTask`: builds the PRG,
kills any stale emulator instance, starts the Box16 fork with the binary
monitor, waits for its "binary monitor: listening" stdout line, attaches,
restarts the program under the debugger — and stops at the first breakpoint
reached. Stepping (F10/F11/Shift-F11), the registers view (a, x, y, pc, sp,
fl), and watches on globals/statics (e.g. `pos_x`) are all live in the
editor. When the session ends the emulator keeps running; the next F5
reuses it (attach restarts the program anyway).

On attach VS64 resets the machine and re-runs the program (it sends RESET
then AUTOSTART), so the emulator **restarts bounce from the beginning** each
time you attach — that is expected, and the fork's RESET handler reloads the
`-prg` for you. (If you ever see it stop at the BASIC `READY.` prompt after
attaching instead of running the program, that is the symptom of an older
fork build where RESET did not reload — rebuild `box16-src`.)

**Debugging from the very first line works.** VS64 installs your breakpoints
*before* it sends the reset, and the fork keeps them armed across the
reboot — so a breakpoint on the first statement of `main()` (line 254,
`x16_screen_cls();`) stops the restarted program before any of it has run.
Attaching is therefore never "too late": every attach is a clean
run-from-start under the debugger, regardless of how long the emulator has
been sitting there. Breakpoints in Oscar64's `crt.c` startup code (before
`main`) work the same way.

Verified so far by a protocol test harness
(`box16-src\test\binmon_test.py`, 36 assertions — run it against a
`-binarymonitor` instance with the **ca65** build's `.prg`/`.lbl`; the
acme `.lbl` uses a format the harness can't parse) that speaks the exact
byte sequences VS64 sends: breakpoint stops at the exact address, step
into/over/out, resume-and-rehit, delete-and-run-free, and the VS64 attach
semantics (reset + re-arm) all pass, and the fork without the flag behaves
identically to stock (no port opened).

Limits of the fork's monitor as used by VS64: main-memory (64 KB CPU view)
only — fine for these programs, which live below `$9F00`; VICE
condition-string breakpoints (`CHECKPOINT_CONDITION_SET`) are accepted but
ignored — moot for VS64, which disables conditional breakpoints in its own
DAP capabilities; only VS64's *attach* mode is supported (use the task to
start the emulator). Oscar64's `.dbj` carries no local-variable info in
this version, so inspect locals via globals/statics or the memory view.
Box16's own ImGui debugger stays usable while attached — pausing there
shows up in VSCode and vice versa.

Beyond what VS64 uses, the fork's `CHECKPOINT_SET` has two **optional,
backward-compatible extensions** (added for the
[X16_BasicDebugger](https://github.com/vinej/X16_BasicDebugger) /
X16_Prog8Debugger custom debug adapters; wire format documented in that
repo's `docs\binmon-bank-extension.md`): a trailing machine-bank
qualifier, so exec checkpoints in banked ROM/RAM (`$A000-$FFFF`) fire only
in the right bank, and a binary *word-in-ranges* condition evaluated
inside the CPU loop, which lets hook-style breakpoints (e.g. the BASIC
interpreter's statement loop) filter at full emulation speed instead of
per-hit client round-trips. Standard 9-byte VS64 requests take the
unchanged code path — verified by the 36-assertion regression above.

The fork's monitor also gained two latency fixes that **do** benefit all
VS64 debugging here: while paused it now services commands at sub-ms
cadence (the display is refreshed at ~60 Hz instead of once per request),
and the client socket runs with `TCP_NODELAY` (no Nagle/delayed-ACK
stalls on the request/response ping-pong). Stepping — especially the
per-instruction fallback in the cc65/llvm/assembly projects, which issues
many round-trips per F10/F11 — is noticeably snappier as a result.

### The stock emulators (assembly-level only)

Everything below applies to the unmodified emulators — useful when the
binary-monitor fork isn't in play.

### What the panel on the right of the emulator is

When you Start Debugging (F5) with the `"x16"` launch type, VS64 appends
`-debug` to the x16emu command line. The panel that opens on the right is
**x16emu's own built-in machine-language monitor** — it has no connection
back to VSCode.

### VSCode breakpoints *do* reach the emulator (partially)

VS64 loads Oscar64's debug info (`build/bounce.dbj`, produced by `-g`). If a
breakpoint is set on a C line **before** pressing F5, VS64 resolves it to a
machine address and launches `x16emu -debug <address>` — the emulator stops
in its monitor exactly when execution reaches that C line.

Caveats (verified in VS64 2.6.2's code):

* only the **first** breakpoint is forwarded; all others are ignored;
* with no breakpoints set, plain `-debug` is passed, which just arms the
  monitor (press F12 in the emulator to break in).

### Working in the x16emu monitor

Debugging there is assembly-level. Keys (from the official x16-emulator
documentation):

| Key | Action |
|---|---|
| F12 | Break into the debugger |
| F9 | Set breakpoint at cursor position |
| F11 / F10 | Step into / step over |
| F5 | Continue (leave debugger) |
| F1 | Re-sync disassembly to the program counter |
| PAGE UP/DOWN | Scroll memory (with SHIFT: scroll disassembly) |
| TAB | Hide the panel while held |

To map what you see back to the C code, use the files Oscar64 writes next to
the PRG on every build:

* `build/bounce.asm` — full disassembly annotated with the C source lines;
* `build/bounce.map` / `build/bounce.lbl` — addresses of every function and
  global. Look up e.g. `move_sprite` there, then break on that address with
  F9 (or `-debug <addr>`).

### Other assembly-level options

1. **VS64's `"6502"` launch type** (add `{ "type": "6502", "request":
   "launch", "name": "Launch 6502", "preLaunchTask": "${defaultBuildTask}" }`
   to `launch.json`) gives source-level debugging on a **bare CPU
   emulator**: no VERA, no X16 KERNAL, no interrupts. `bounce.c` hangs at
   `x16_vsync_wait()` and all VERA/sprite pokes go nowhere. Only useful for
   stepping through pure algorithm code in isolation — the binary-monitor
   attach flow above supersedes it for real programs.
2. **Stock [Box16](https://github.com/indigodarkwolf/box16)** — installed in
   this repo under `box16/` (version nr48.0) — has a rich built-in ImGui
   debugger: dockable panels for CPU state, memory, VERA/VRAM inspection,
   PSG/YM state, and **symbol file loading**. Assembly-level, not
   VSCode-integrated. Run it via the `run in Box16 (debugger)` task, which
   passes Oscar64's `build/bounce.lbl` with `-sym` so the disassembly and
   breakpoints work with your C function names (`main`, `move_sprite`,
   `step_axis`, …). A `-sym` label file can also contain `break <address>`
   lines to pre-set breakpoints.

   Box16 quirks found while setting this up (both stock and fork):
   * launch it with `-ignore_ini` (the tasks do): a stale/broken ini under
     `%APPDATA%\Box16` otherwise makes it print usage and exit immediately;
   * it does not find `rom.bin` on its own here — the tasks pass
     `-rom emulator\rom.bin` explicitly. The repo's ROM is R49 (KERNAL
     version byte `$31` at `$FF80`) while Box16 nr48.0 was released against
     R48; the combination runs these examples fine, but if something looks
     off in Box16, suspect the version skew first. (The fork in `box16-src/`
     is built from Box16 master, which also runs the R49 ROM fine.)

### Rebuilding the Box16 fork

Requires Visual Studio 2022 with the Desktop C++ workload. Open
`box16-src\build\vs2022\box16.sln` and build Release x64, or headless:

```powershell
& "$(& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -find MSBuild\**\Bin\MSBuild.exe)" `
  box16-src\build\vs2022\box16.sln -p:Configuration=Release -p:Platform=x64 -m
```

The monitor implementation is one new file pair
(`box16-src\src\binary_monitor.{h,cpp}`) hooked into `emulator_loop()`; the
protocol test harness is `box16-src\test\binmon_test.py` (stdlib Python;
start the emulator with `-binarymonitor` first, then
`python box16-src\test\binmon_test.py --lbl build\bounce.lbl`).

### Other notes

* Oscar64's `build/bounce.asm`, `.map` and `.lbl` are regenerated on every
  build — often the fastest way to see what the compiler actually did.
* `bounce.c` needs real video (VSYNC): run it windowed, never under the
  emulator's headless `-testbench` mode, or `x16_vsync_wait()` never returns.

## Debugging with the cc65 toolchain

The same F5 debugging flow works with **[cc65](https://cc65.github.io/)**
(the `cc65/` subfolder is its VS64 project) — and it brings the one feature
neither Oscar64 nor llvm-mos offers: **local variables and function
parameters in the Variables pane**. VS64's cc65 debug-info parser (for
ld65's `--dbgfile` output) is the only one with scope support, reading the
stack-relative `csym` records that `cc65 -g` emits. The trade-off: cc65
generates noticeably slower and larger code than the other two toolchains —
the best *debugging* toolchain is the weakest *shipping* one.

### Setup

Covered by the common [Setup](#setup) section: install the cc65 rows of the
untracked-pieces table (the cc65 toolchain into `cc65-sdk\` at the repo
root, x16clib's `include_ca65\` + `dist_ca65\x16c.lib` into `cc65\`), open
**`cc65\` as its own workspace root**, and fix the absolute paths in
[cc65/.vscode/settings.json](cc65/.vscode/settings.json).

### How the cc65 project is wired

[cc65/project-config.json](cc65/project-config.json):

```json
{
    "toolkit": "cc65",
    "machine": "cx16",
    "sources": [ "examples/bounce.c" ],
    "build": "debug",
    "includes": [ "include_ca65" ],
    "linker": ".\\ld65-cx16.cmd",
    "linkerFlags": [ "-Ln", "build/bounce.lbl" ]
}
```

* **`"machine": "cx16"`** is honored correctly for cc65 (unlike Oscar64's
  `-tm=` bug): VS64 passes `-t cx16` to compiler, assembler and linker.
* **`"linker": ".\\ld65-cx16.cmd"`** works around a real VS64 2.6.2 bug:
  its cc65 link line **hardcodes `c64.lib`** as the runtime library and
  ignores the project `libraries` attribute. ld65 only pulls archive
  members referenced by *preceding* object files, so the correct libraries
  cannot be injected via `linkerFlags` (those land before the objects).
  The wrapper ([cc65/ld65-cx16.cmd](cc65/ld65-cx16.cmd)) drops `c64.lib`
  and appends `dist_ca65\x16c.lib` plus the proper `cx16.lib` runtime,
  forwarding everything else to `cc65-sdk\bin\ld65.exe` untouched. (The
  `.\` prefix matters on machines with `NoDefaultCurrentDirectoryInExePath`
  set.)
* **`"linkerFlags": ["-Ln", "build/bounce.lbl"]`** makes ld65 also write a
  VICE label file, which the Box16 task loads with `-sym` — so Box16's own
  ImGui debugger shows your symbol names too.
* A debug build compiles with `-g` and no optimizer flags (best for
  debugging); VS64 always links with `--dbgfile build/bounce.dbg`, which is
  the debug info VS64 loads for the attach. Harmless link-time note: the
  runtime's `sp-compat.s` prints a deprecation warning about the `sp`
  symbol — ignore it.

### cc65-specific notes

* **Locals work** — but cc65 keeps locals on its software stack, so they
  are only valid once the function prologue has run; at the very first
  instruction of a function they can read as garbage. Step once if a local
  looks wrong.
* Stepping is per-instruction inside the emulator (the Box16 fork's
  line-granular fast path only reads Oscar64 `.dbj`), so stepping over
  long C lines makes more monitor round-trips — same as the llvm project.

### Stepping into x16clib under cc65

By default, **F11 on a library call steps over it** (execution runs to the
next line of your own code). This is a VS64 2.6.2 limitation, not missing
debug info: `bounce.dbg` does carry line records for the library's `.s`
sources (the archive is assembled with `ca65 -g`), but VS64's cc65
debug-info resolver discards line records for every file that is not
listed in `project-config.json`'s `sources`. Two ways to look inside a
library call anyway:

**Option 1 — Box16's own debugger (recommended, zero setup).** While
VSCode is stopped on the call line, switch to the Box16 window: its CPU
panel shows the live disassembly *with your symbol names* (the task loads
ld65's `-Ln` label file via `-sym`), and you can step instruction by
instruction there. VSCode and Box16 stay in sync — continue from either
side.

**Option 2 — the `sources` recipe (real F11 into a chosen module).**
Because the filter is literally "is the file in `sources`?", any library
module you add there becomes debuggable: VS64 assembles it into the
program directly (its object then shadows the archive member — no
duplicate-symbol clash, verified) and its lines pass the filter. The
project is pre-wired for this (`src_ca65/core` is already on the include
path, `--cpu 65C02` already in `assemblerFlags`); you only need
`cc65\src_ca65\` installed (see the untracked-pieces table). Then, to step
into e.g. the sprite module, change one line in
[cc65/project-config.json](cc65/project-config.json):

```json
"sources": [ "examples/bounce.c", "src_ca65/sprite/sprite.s" ]
```

Rebuild (Ctrl+Shift+B) and F11 now walks into `sprite.s` at the
assembly-source level. **To deactivate, remove the module from `sources`
again** — the build falls back to the archive and F11 steps over the
library as before. Add only the module(s) you are actually debugging:
directly-linked modules are always included in the PRG, so listing all of
them costs program size for no benefit.

## Debugging with the llvm-mos toolchain

The same F5 debugging flow also works with the
**[llvm-mos](https://github.com/llvm-mos/llvm-mos-sdk)** C compiler — VS64's
`vice` debug type is toolkit-agnostic and the Box16 fork's binary monitor is
protocol-level, so only the build side changes. The `llvm/` subfolder is a
complete, separate VS64 project for it.

### Setup

Covered by the common [Setup](#setup) section: install the llvm rows of the
untracked-pieces table (the full llvm-mos SDK into `llvm-mos\` at the repo
root, x16clib's `include_llvm\` + `dist_llvm\libx16c.a` into `llvm\`), open
**`llvm\` as its own workspace root**, and fix the absolute paths in
[llvm/.vscode/settings.json](llvm/.vscode/settings.json).

Then everything works as in the Oscar64 project: `Ctrl+Shift+B` builds,
`F5` on **`Attach to Box16 (binary monitor)`** gives one-step C source-level
debugging with breakpoints, stepping and watches on globals.

### How the llvm project is wired

[llvm/project-config.json](llvm/project-config.json):

```json
{
    "toolkit": "llvm",
    "machine": "cx16",
    "sources": [ "examples/bounce.c" ],
    "build": "debug",
    "includes": [ "include_llvm" ],
    "linkerFlags": [ "-mreserve-zp=16", "dist_llvm/libx16c.a" ]
}
```

* **`"machine": "cx16"`** makes VS64 pass `--config mos-cx16.cfg` to every
  compile/assemble/link step — the same mechanism as the SDK's
  `mos-cx16-clang` wrapper. It must be `cx16` (not `x16`): the config file
  name is built literally and only `mos-cx16.cfg` exists.
* **`"linkerFlags"`** carries both the library and `-mreserve-zp=16`.
  The x16clib archive *must* be linked with `-mreserve-zp=16`, otherwise
  `ld.lld` fails with `section '.zp.bss' will not fit in region 'zp'`.
  It sits in `linkerFlags` (not a `libraries` attribute) because VS64 2.6.2
  only honors `libraries` for the cc65/oscar64 toolkits; relative paths
  resolve correctly because VS64 runs ninja with the project folder as cwd.
* A debug build compiles with `-g -O0` plus DWARF-quality flags
  (`-fstandalone-debug`, …) automatically — no `compilerFlags` needed.
* The build produces `build\bounce.prg` **and** `build\bounce.prg.elf`;
  the `.elf` carries the DWARF debug info VS64 loads for the attach.

### llvm-specific limitations

* **Watches/variables: globals and statics only.** VS64 reads the DWARF
  line table (C-line breakpoints and stepping work fully) and the ELF
  symbol table, but does not extract DWARF local-variable info — so locals
  and parameters don't show; inspect them via globals or the memory view.
  (Same practical limitation as Oscar64, whose `.dbj` carries no locals
  either.)
* **Stepping is per-instruction inside the emulator.** The Box16 fork's
  line-granular stepping optimization reads Oscar64's `.dbj`, which llvm
  builds don't produce; VS64 still steps by C line client-side, it just
  issues more monitor round-trips, so stepping over long lines is a bit
  slower.
* No VICE label file is produced, so the Box16 ImGui debugger shows plain
  addresses (VSCode-side symbols are unaffected). The tasks therefore pass
  no `-sym`.

## Debugging assembly programs (ACME, ca65, KickAssembler)

The same F5 flow debugs **native assembly** programs written against
[x16lib](https://github.com/vinej/x16_library) (the assembly sibling of
x16clib: ACME is its reference dialect, and its `src_ca65\` / `src_kick\`
ports are mechanically translated from it). Three projects: `acme\`,
`ca65\`, `kickass\` — each opened as its own workspace root, each with the
same one-F5 attach flow, and each verified to build a **byte-identical**
`bounce.prg` from its dialect of the same demo.

Assembly is where this debugger shines brightest: one instruction is one
source line, so the per-instruction stepping matches the source exactly —
no `__asm{}` opacity (Oscar64), no locals gap (llvm), nothing hidden.
All three also produce a VICE label file that the Box16 task loads with
`-sym`, so Box16's own ImGui debugger shows your symbol names too.

Per-toolkit wiring notes:

* **ACME** ([acme/project-config.json](acme/project-config.json)) — VS64's
  native `acme` toolkit: it assembles with `-r build\bounce.report` and
  parses that report for the line↔address mapping. `"machine": "65c02"`
  becomes `--cpu 65c02` (for ACME the machine attribute selects the CPU;
  `cx16` is not an ACME CPU name). `--vicelabels build/bounce.lbl` in
  `assemblerFlags` writes the Box16 symbol file.
* **ca65** ([ca65/project-config.json](ca65/project-config.json)) — uses
  the `cc65` toolkit with a pure-assembly source. `"machine": "none"`
  suppresses `-t` entirely (x16lib's ca65 dialect wants no target's
  PETSCII re-mapping); `--cpu 65C02` comes via `assemblerFlags`, and the
  link uses x16lib's plain-PRG memory layout via
  `"linkerFlags": ["-C", "bounce.cfg", …]` ([ca65/bounce.cfg](ca65/bounce.cfg),
  same layout as x16_library's `test_ca65\runner.cfg`). VS64's hardcoded
  trailing `c64.lib` is harmless here — a self-contained assembly program
  has no unresolved imports, so no library member is ever pulled in.
  Debug info is ld65's `--dbgfile` output, assembled with `-g`.
* **KickAssembler** ([kickass/project-config.json](kickass/project-config.json)) —
  VS64's native `kick` toolkit runs `java -jar KickAss.jar` (Java required
  on the PATH) with `-debugdump`, whose `.dbg` output VS64 parses.
  `-vicesymbols -symbolfiledir build` in `assemblerFlags` writes
  `build\bounce.vs` for Box16. Note: VS64 supports **one** assembly source
  file per KickAss project (additional `sources` entries are ignored) —
  x16lib's `#import` structure fits that model naturally.

The `examples\bounce.asm` in `ca65\` and `kickass\` are translated from
the ACME original with x16_library's `tools\acme2ca65.py` /
`acme2kick.py`. The kick translation works as-is; the ca65 one needs the
same two hand-fixes the library's own test runner uses: drop the
`!cpu 65c02` line (the `--cpu` flag covers it) and replace `* = $0801` +
`basic_stub` with the `LOADADDR`/`CODE` segment prologue (see the top of
[ca65/examples/bounce.asm](ca65/examples/bounce.asm)).

**64tass is the one x16_library dialect not covered**: VS64 has no 64tass
toolkit, so there is no VSCode-side build or debug-info support. (64tass
programs can still be debugged symbolically inside Box16 itself via its
`--vice-labels` output and `-sym`.)

## Prog8 (build + symbolic debugging only)

[Prog8](https://github.com/irmen/prog8) compiles through **64tass**, which
VS64 does not support — so unlike the six toolchains above there is **no
F5 source-level debugging** for Prog8 (yet: that is the goal of the
separate [X16_Prog8Debugger](https://github.com/vinej/X16_Prog8Debugger)
project). What the `prog8/` folder gives you today, via plain VSCode tasks
(open `prog8\` as its own workspace root; no `project-config.json`, VS64
is not involved):

* **`build project`** (Ctrl+Shift+B) — runs
  `prog8c -target cx16 -asmlist -out build examples/bounce.p8`.
  prog8c needs **Java 11+**; the task calls a JDK-21 `java.exe` by
  absolute path — edit [prog8/.vscode/tasks.json](prog8/.vscode/tasks.json)
  if yours lives elsewhere. `64tass.exe` is found via `prog8-sdk\` which
  the task prepends to `PATH`.
* **`run in x16emu (standard)`** — build + run.
* **`debug in Box16 (symbolic)`** — build, then Box16 with
  `-sym build\bounce.vice-mon-list`: Prog8's generated label file makes
  Box16's built-in debugger fully symbolic, and any `%breakpoint`
  directive in the Prog8 source arms a breakpoint automatically. The
  binary monitor is enabled too, so future tooling can attach.

The example is [prog8/examples/bounce.p8](prog8/examples/bounce.p8) — a
Prog8 port of the same bounce demo used by every other toolchain (sprite,
VSYNC lock, fixed-point velocity, AABB collision, PSG blip; the in-box
note uses a second PSG voice instead of the YM2151, which would need the
KERNAL audio-bank API).

Why full integration is feasible later: prog8c embeds the original source
lines as comments in its generated assembly (default on) and `-asmlist`
produces the 64tass listing — together they yield a `.p8`-line ↔ address
source map; the Box16 fork already provides the runtime control. The
missing piece is a custom VSCode debug adapter, shared with the BASIC
debugger effort — see the X16_Prog8Debugger project charter.

## Verified

* `oscar64 -tm=x16` compile of `examples/bounce.c`: OK (exit 0, 2455 bytes
  with `-O1`, 2569 bytes plain `-O0`).
* `x16emu -prg build\bounce.prg -run`: OK — demo loads, runs, exits on key.
* `Box16 -ignore_ini -rom emulator\rom.bin -prg build\bounce.prg -run -sym
  build\bounce.lbl`: OK — demo runs with symbols loaded.
* Box16 fork binary monitor: all 36 protocol-harness assertions pass
  (transport, memory/registers, exec breakpoints stopping at the exact
  address, step into/over/out, resume-and-rehit, delete, VS64 attach
  semantics); without `-binarymonitor` the fork behaves like stock and
  opens no port. Re-verified after the fork gained the bank-qualifier and
  word-in-ranges checkpoint extensions (standard requests unaffected).
* Oscar64 `-O3` on `bounce.c`: compiler crash (documented above).
* llvm-mos build of `llvm\examples\bounce.c` with VS64's exact debug flags
  (`-g -O0 -fstandalone-debug …`, link with `-mreserve-zp=16` +
  `dist_llvm/libx16c.a`): OK — produces `bounce.prg` (5509 bytes) and
  `bounce.prg.elf` whose DWARF line table has 121 rows for `bounce.c` and
  whose symtab contains `main`, `move_sprite`, `pos_x`, `pos_y`,
  `blip_timer`.
* Box16 fork with the llvm-built PRG: OK — loads it, runs, and prints
  `binary monitor: listening on 127.0.0.1:6502`.
* cc65 build of `cc65\examples\bounce.c` with VS64's exact flags
  (`cc65 -g -t cx16` → `ca65 -g -t cx16` → wrapper `ld65 --dbgfile … -Ln …`
  + `x16c.lib` + `cx16.lib`): OK — `bounce.prg` (5003 bytes); `bounce.dbg`
  has 8935 line records across 88 files including `examples\bounce.c` and
  the x16clib `.s` sources, plus 29 stack-relative `csym` records (locals:
  `pos`, `frac`, `vel`, `limit`, …); `bounce.lbl` written for Box16 `-sym`.
* Box16 fork with the cc65-built PRG: OK — loads it, runs, and prints
  `binary monitor: listening on 127.0.0.1:6502`.
* Assembly toolchains, `bounce.asm` with VS64's exact flags: ACME
  (`--msvc … -f cbm --cpu 65c02 -r bounce.report --vicelabels`) OK —
  3266-byte PRG + report + labels; ca65 (`-g --cpu 65C02` →
  `ld65 --dbgfile -C bounce.cfg -Ln`) OK — PRG + `.dbg` + labels;
  KickAssembler (`-debugdump -vicesymbols`, Java 1.8) OK — PRG + `.dbg` +
  `.vs`. All three PRGs are **byte-identical** (MD5
  `7F2F685178FD49D8C4F226BF2D09D3FD`), and the Box16 fork loads the PRG
  and opens the binary monitor.
* Prog8 12.2.1 (`prog8c -target cx16 -asmlist`, JDK 21): `bounce.p8`
  compiles first-try — 2208-byte PRG, generated asm carries
  `; source: examples\bounce.p8:NN` comments, 64tass listing + 
  `bounce.vice-mon-list` produced; Box16 fork loads the PRG with `-sym`
  and opens the binary monitor.
