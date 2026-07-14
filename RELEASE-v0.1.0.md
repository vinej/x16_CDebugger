This first release brings step-by-step source-level debugging of Commander X16 programs directly into VSCode — set breakpoints and drive execution with **F5 / F10 / F11 / Shift+F11** against real machine code running in the Box16 emulator, using the [VS64](https://marketplace.visualstudio.com/items?itemName=rosc.vs64) extension.

Eight toolchains are supported, one VS64 project folder each. All builds run the same **bounce demo** (a sprite bouncing around the screen with PSG and YM2151 sound), so the debug experience is directly comparable across them.

## What's included

**C toolchains** (build against the [x16clib](https://github.com/vinej/x16_clib) C library):
- **Oscar64** — full F5 debugging (globals/statics)
- **cc65** — full F5 debugging; the one toolchain whose debugger also shows **local variables**
- **llvm-mos** — full F5 debugging (globals/statics)

**Assembly toolchains** (build against the [x16lib](https://github.com/vinej/x16_library) assembly library):
- **ACME** — x16lib's reference dialect
- **ca65**
- **KickAssembler** (needs Java)
- **dasm** — full F5 debugging via a synthesized cc65-format `.dbg`, even though VS64 ships no dasm toolkit

**Prog8** — build/run plus *symbolic* debugging in Box16 (no F5 source-level debugging: VS64 has no prog8/64tass toolkit).

## How it works

C source-level debugging is enabled by a **Box16 fork** (branch `binary-monitor`) that adds a **VICE binary monitor server**, which VS64 talks to over TCP. This fork also carries monitor latency fixes (sub-millisecond paused servicing, `TCP_NODELAY`) and checkpoint extensions.

## Known limitations

- **Locals show only for cc65.** Oscar64 (`.dbj` carries no locals) and llvm-mos (VS64 doesn't extract DWARF locals) show globals/statics only — inspect locals via globals or the memory view.
- **Prog8** has symbolic debugging only, not F5 source-level stepping.
- **Stepping into library calls** is limited by VS64's cc65 debug-info resolver, which discards line records for sources not listed in `project-config.json`'s `sources`.

## Setup

The distribution is **source/config only**. Third-party binaries (compilers, emulators, the Box16 fork, the support libraries, ROM) are **not tracked in this repo** — after cloning, set them up once as described in the README's Setup section. Nothing is installed system-wide except the VS64 extension itself.

---

Version **Alpha 0.1** — works across all toolchains but wants more testing.
