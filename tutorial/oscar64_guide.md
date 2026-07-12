# C on the Commander X16 with Oscar64 — language, library, and CPU guide

This is the Oscar64 quarter of the toolchain guides; cc65 is covered by
[ca65_guide.md](ca65_guide.md), llvm-mos by [llvm_guide.md](llvm_guide.md)
and KickC by [kickc_guide.md](kickc_guide.md). The library API itself is
in [userguide.md](userguide.md). Everything here was learned porting
x16clib's 27 modules to Oscar64 1.32.272 and getting the same 119-test
suite green that the KickC port runs, so each claim traces to a compile
error, a listing, or an instruction-level emulator trace.

Oscar64 (https://github.com/drmortalwombat/oscar64) is a single native
Windows/Linux executable, no runtime dependencies. Unzip a release and:

```
oscar64 -tm=x16 -n -i=src_oscar64 -o=GAME.PRG game.c
```

`-tm=x16` selects the Commander X16 target (and defines `__X16__`);
`-n` compiles to native 6502 code instead of Oscar64's interpreted
bytecode — always pass it, the bytecode default is a size optimization
that costs roughly an order of magnitude in speed. `-i=` adds the
library tree. The output is a ready-to-RUN PRG.

One flag deserves its own warning. **Do not add `-O2`.** Oscar64
1.32.272 dies with an unexplained access violation ("Addressing
Error... at location 0x00007ff7...") compiling some translation units
of this library's test suite at `-O2`; the default optimization with
`-n` compiles everything and is already competitive (`bounce.prg` is
2455 bytes — smaller than both the cc65 and KickC builds). If a future
Oscar64 fixes it, `-O2` is worth retrying; nothing in the library
depends on avoiding it.

## 1. The C language Oscar64 compiles

Real C99, and then some. After KickC's dialect this feels like a
different sport: `long` and `float` exist, division and modulo exist,
32-bit shifts exist, `bool` converts, initializers can be expressions,
and most of C++ (templates, lambdas, namespaces, constexpr) is
available if you want it. The cc65 test suites port essentially
verbatim.

### Type sizes

| type | size |
|---|---|
| `char` | 8-bit, **unsigned by default** (like cc65; unlike most PCs) |
| `int` | 16-bit |
| `long` | 32-bit |
| `float` | 32-bit IEEE-ish, in software |

`char` being unsigned matters in the same places it does under cc65:
`char c = -1; if (c < 0)` is never true. Spell `signed char` when you
mean it.

### One program, no linker

Like KickC, Oscar64 compiles the whole program in one pass and strips
every function it can prove unreachable; there are no object files and
no archives. What replaces the archive is built into the language:

```c
/* at the bottom of x16/vera.h */
#pragma compile("vera.c")
```

A header that names its implementation pulls it into any program that
includes the header. That is why `src_oscar64/x16/` holds headers and
implementations side by side — **`#pragma compile` resolves relative to
the header's own directory and nothing else**. Not the `-i=` paths, and
`../` traversal is quietly stripped. Put the .c next to the .h or the
pragma will not find it.

## 2. Calling convention: zero-page names, not registers

Oscar64 places parameters and locals in a zero-page register file and
inline assembly reads them **by name**:

```c
char x16_bank_get(void);        /* the header */

char foo_add(char a, char b) {
    return __asm {
        lda a
        clc
        adc b
        sta accu
    };
}
```

Two things in that example are load-bearing:

- **Results leave through `accu`.** Oscar64's accumulator is a 4-byte
  zero-page slot named `accu` in assembly; a `return __asm {...}`
  expression reads its value from there — `accu` alone for a char,
  `accu`/`accu + 1` for an int, all four bytes for a `long`. Cast for
  pointers: `return (void*)__asm {...};`.
- **Writes to C locals from assembly are silently lost.** `sta r`
  followed by `return r;` returns garbage: the optimizer keeps locals
  in its own registers and never reads your store. `volatile` does not
  help. Results must leave via `accu` or via a module-level global
  (absolute addressing works fine). This is the single most dangerous
  trap in the port — it fails silently, at run time.

Pointer parameters live in zero page, so `lda (src),y` against a
parameter assembles and works — no copying into pinned slots, which is
what let this port delete every `__address()` pin the KickC build
needed. Walking a parameter (`inc src`) inside the asm block is fine as
long as no C code reads it afterwards.

## 3. The inline assembler: NMOS only, one per line

Oscar64's `__asm` blocks are the same shape as KickC's — labels are
local to the block, C symbols resolve by name, `symbol+1` arithmetic
works — with four rules of its own:

- **The instruction set is NMOS 6502, not 65C02.** `bra`, `stz`,
  `phx/plx/phy/ply`, `trb/tsb` are rejected with a parse error — good.
  Worse: bare `inc` (accumulator mode) and `lda (zp)` (no index)
  **compile silently and emit garbage bytes** that the X16's 65C02
  executes as something else entirely. The port ran a mechanical
  downgrade (`stz` → `lda #0`+`sta` with a flag/register liveness audit
  at every site, `bra` → `jmp`, `trb/tsb` → `and`/`ora` read-modify-
  write, `(zp)` → `(zp),y` with Y proven free) and then grepped the
  result for every 65C02 mnemonic. Do the same to anything you port.
- **One instruction per line.** `lda c jsr $ffd2` on one line is a
  parse error.
- **Comments inside a block are `/* */`, never `//`.** A `//` comment
  inside `__asm` breaks the parse of the *next* line. And a block
  comment as the very first line of a block breaks the following
  instruction if it has an immediate operand — hoist leading comments
  above the `__asm {`.
- **Numbers are C-style.** `0x9f25`, not `$9f25`; `#0xf3`, not
  `#%11110011`. The data directive is `byt`:

```c
    jsr 0xff6e                  /* KERNAL JSRFAR */
    byt 0x06, 0xfe, 0x04        /* entry $FE06, bank 4 */
```

Branch range is checked ("Branch target out of range") — a far branch
is a compile error, not a silent wrap.

Function-scoped labels mean self-modifying code works *within* one
function (`sta ld+1` ... `ld: lda 0xffff` — the bank window and the
zx0 match copier do exactly this, like the original assembly library)
but a cross-function patch is inexpressible, which is why the PCM
stream pointer lives in `__zeropage` instead.

## 4. Zero page: what Oscar64 owns and what you get

The x16 target's layout (decoded from listings; the runtime relocates
the C64 map up by $20):

| range | owner |
|---|---|
| $00/$01 | RAM/ROM bank registers (hardware) |
| $02–$21 | KERNAL r0–r15 — Oscar64 stays clear ✓ |
| $23–$54+ | Oscar64's work registers, IP, `accu`, SP, register file |
| $F7–$FF | **`__zeropage` region — all nine bytes a program gets** |

Declare a global `__zeropage` to place it there: the library spends
eight of the nine bytes (mouse scratch ×4, SAVE's start pointer ×2, the
PCM stream pointer ×2) and leaves one. There is no `zp_reserve`
equivalent and no way to grow the region from source, so a program that
needs more zero page keeps its own data in parameters (already zp) or
self-modifying operands.

The register file's ceiling under pressure is the compiler's business,
not a contract — the library's interrupt dispatcher saves $02–$8F plus
$F7–$FF (151 bytes) around C callbacks for exactly that reason.

## 5. Encoding: ASCII by default

Oscar64 string and char literals stay ASCII unless told otherwise —
the right default for the X16 KERNAL after `x16_screen_mode()`, and the
reason the test harness needed no `#pragma encoding` dance. `'S'` is
$53. (cc65's `-t cx16` and KickC's default both PETSCII-ify literals;
this port inherits their explicit-hex habit anyway so the four trees
match byte for byte.)

## 6. The standard library Oscar64 ships

Full `<stdio.h>` (printf with floats), `<stdlib.h>`, `<string.h>`,
`<math.h>` — `examples\numbers.c`, the printf tour that KickC could not
build at all, compiles unchanged. C64-shaped hardware headers also
ship; ignore them on the X16 and use this library's `<x16/*.h>`.

One warning from the feasibility check: the SDK-shipped X16 VERA
helpers were not trustworthy in this version — the library's own
`x16_vera_*` routines are the tested path.

## 7. Quirks that cost an afternoon each

- **`Type volatile name` won't parse.** Oscar64 rejects the postfix
  qualifier position on typedef'd pointers: `x16_irq_handler volatile
  v;` is an error, `volatile x16_irq_handler v;` is fine.
- **`void main(void)` is an error** — crt.c declares `int main()`, and
  the mismatch is fatal. Return an int.
- **`#error` output is garbled** ("Missing or invalid error message"),
  but the line number is right.
- **The target macro is `__X16__`** (plus `__OSCAR64C__` for the
  compiler itself).
- **Diagnose with `-g`:** it writes `prog.asm` (a full annotated
  disassembly), `prog.map` (section placement) and `prog.lbl` next to
  the PRG. The listing is how every silent-codegen claim in this guide
  was verified; when an asm block misbehaves, read it before guessing.

## 8. x16clib specifics under Oscar64

- Build anything with `build_oscar64.ps1`:

  ```powershell
  .\build_oscar64.ps1 -Source examples\bounce.c -Run
  .\build_oscar64.ps1 -Test              # 119 tests, three PRGs
  .\build_oscar64.ps1 -Test -Windowed    # with live video and IRQs
  ```

- The suite is split into three programs to stay line-for-line
  comparable with the KickC suite (which needed the split for zero
  page; Oscar64 does not).
- A C interrupt callback may call anything, including other `x16_*`
  routines: the dispatcher parks $02–$8F and $F7–$FF (151 bytes, ~2.5%
  of a frame) around it, and only when a callback is installed.
- Programs that return to BASIC must call `x16_irq_remove()` first if
  they hooked interrupts — no exit destructors here, same as KickC.
- The sizes, for the curious: `bounce.prg` is 2455 bytes under Oscar64,
  2576 under KickC, ~4300 under cc65 and llvm-mos.

## 9. Gotcha checklist

Things that compile fine and then bite, in the order they will bite:

1. Assembly wrote a C local; the value evaporated. Use `sta accu` in a
   `return __asm {}` or a module global.
2. A bare `inc` or `lda (ptr)` emitted garbage bytes silently. NMOS
   only; grep your asm for 65C02 mnemonics.
3. A `//` comment inside `__asm` broke the next line's parse.
4. `-O2` crashed the compiler with an access-violation dump.
5. Forgot `-n`: the program runs, at bytecode speed.
6. `#pragma compile("x16/foo.c")` didn't resolve — the path is
   header-relative only; keep .h and .c side by side.
7. `char` is unsigned; a `< 0` test on one is dead code.
8. Ten `__zeropage` bytes wanted, nine exist ($F7–$FF).
