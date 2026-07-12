# x16clib User Guide

A function-by-function guide to **x16clib**, the C library for the
Commander X16. Every function in the library is listed here with its
parameters and a small example.

For background, design notes and hardware pitfalls, see the
[README](../README.md). This guide is about *using* the API.

---

## Table of contents

1. [Getting started](#getting-started)
2. [`x16/vera.h` — VRAM data ports](#x16verah--vram-data-ports)
3. [`x16/screen.h` — screen mode, text, cursor](#x16screenh--screen-mode-text-cursor)
4. [`x16/palette.h` — the VERA palette](#x16paletteh--the-vera-palette)
5. [`x16/tile.h` — tilemap cells and layers](#x16tileh--tilemap-cells-and-layers)
6. [`x16/sprite.h` — hardware sprites](#x16spriteh--hardware-sprites)
7. [`x16/bitmap.h` — 320x240 bitmap drawing](#x16bitmaph--320x240-bitmap-drawing)
8. [`x16/verafx.h` — VERA FX acceleration](#x16verafxh--vera-fx-acceleration)
9. [`x16/psg.h` — the 16-voice PSG](#x16psgh--the-16-voice-psg)
10. [`x16/ym.h` — the YM2151 FM chip](#x16ymh--the-ym2151-fm-chip)
11. [`x16/pcm.h` — PCM audio and streaming](#x16pcmh--pcm-audio-and-streaming)
12. [`x16/adpcm.h` — IMA ADPCM decoding](#x16adpcmh--ima-adpcm-decoding)
13. [`x16/input.h` — joystick, mouse, keyboard](#x16inputh--joystick-mouse-keyboard)
14. [`x16/irq.h` — VSYNC, raster and collision interrupts](#x16irqh--vsync-raster-and-collision-interrupts)
15. [`x16/bank.h` — banked RAM](#x16bankh--banked-ram)
16. [`x16/mem.h` — KERNAL block operations](#x16memh--kernal-block-operations)
17. [`x16/load.h` — load and save](#x16loadh--load-and-save)
18. [`x16/dos.h` — the DOS command channel](#x16dosh--the-dos-command-channel)
19. [`x16/bmx.h` — BMX image files](#x16bmxh--bmx-image-files)
20. [`x16/zx0.h` — ZX0 decompression](#x16zx0h--zx0-decompression)
21. [`x16/fixed.h` — 8.8 fixed point](#x16fixedh--88-fixed-point)
22. [`x16/math.h` — game math](#x16mathh--game-math)
23. [`x16/collide.h` — bounding-box overlap](#x16collideh--bounding-box-overlap)
24. [`x16/clip.h` — line clipping](#x16cliph--line-clipping)
25. [`x16/buffers.h` — ring buffer and stack](#x16buffersh--ring-buffer-and-stack)
26. [`x16/float.h` — ROM floating point](#x16floath--rom-floating-point)

---

## Getting started

### Compiling a program

With **cc65** (the prebuilt library ships in `dist_ca65\`):

```
cl65 -t cx16 -O -I include_ca65 -o PROG.PRG prog.c dist_ca65\x16c.lib
```

With **llvm-mos** (`-mreserve-zp=16` is required — the link fails
without it):

```
mos-cx16-clang -Os -mreserve-zp=16 -I include_llvm \
    -o PROG.PRG prog.c dist_llvm\libx16c.a
```

The API is identical under both toolchains; every example in this guide
builds unchanged under either. Include the umbrella header and you have
everything — the linker keeps only the modules you actually call:

```c
#include <x16/x16.h>

int main(void)
{
    x16_screen_cls();
    x16_screen_puts("HELLO FROM X16CLIB\r");
    return 0;
}
```

Run it in the emulator:

```
x16emu -prg PROG.PRG -run
```

### Three rules that apply everywhere

1. **`X16_INC_*` is not `VERA_INC_*`.** This library's increment
   constants are raw indices (0–15). cc65's `<cx16.h>` constants with
   the same names are pre-shifted (its `VERA_INC_1` is `0x10`). Pass
   `X16_INC_*` to `x16_*` functions and `VERA_INC_*` to cc65's;
   never mix them.

2. **Part of VRAM is write-only.** `$1F9C0–$1FFFF` — the PSG, the
   palette and the sprite attributes — reads back the last value *your
   program* wrote, not the hardware's state. Initialise before you
   read-modify-write (`x16_sprite_init_all()`, `x16_psg_init()`).

3. **The scratch block is not reentrant.** The library keeps 16
   zero-page bytes. An interrupt handler must not call an `x16_*`
   routine that uses them — unless it is a callback installed through
   `x16/irq.h`, whose wrapper saves and restores everything for you.

One diagnostic from the umbrella header:

```c
unsigned char x16_zp_base(void);
```

Returns the zero-page address the linker gave that scratch block.
Purely informational:

```c
printf("scratch block at $%02X\n", x16_zp_base());
```

---

## `x16/vera.h` — VRAM data ports

VERA has two data ports. Point one at a VRAM address with an
auto-increment, then stream bytes through it. For a *single* VRAM byte
use cc65's `vpeek()`/`vpoke()`; these routines are for runs.

**Increment constants** (`X16_INC_0` … `X16_INC_640`): how far the
address steps after each access. Beyond powers of two there are
row-sized steps: `X16_INC_40`, `X16_INC_80` (text rows), `X16_INC_320`
(a bitmap row). Or with `X16_DECR` to walk backwards.

**VRAM landmarks**: `X16_VRAM_BITMAP` (0x00000), `X16_VRAM_SPRITE_DATA`
(0x13000), `X16_VRAM_TEXT` (0x1B000), `X16_VRAM_CHARSET` (0x1F000),
`X16_VRAM_PSG` (0x1F9C0), `X16_VRAM_PALETTE` (0x1FA00),
`X16_VRAM_SPRITE_ATTR` (0x1FC00).

### `void x16_vera_addr0(unsigned char inc, unsigned long addr)`
### `void x16_vera_addr1(unsigned char inc, unsigned long addr)`

Point data port 0 (or 1) at a 17-bit VRAM address, with an increment.

- `inc` — an `X16_INC_*` constant, optionally `| X16_DECR`.
- `addr` — the VRAM address; only bit 16 of the high half matters.

```c
/* Step through the text tilemap two bytes at a time: screen codes
** only, skipping the colour attributes. */
x16_vera_addr0(X16_INC_2, X16_VRAM_TEXT);
```

### `void x16_vera_fill(unsigned char value, unsigned int count)`

Write `value` `count` times through port 0, which must already point at
the destination. The increment decides the shape: `X16_INC_1` fills a
run, `X16_INC_320` stripes down a bitmap column. Count 0 writes nothing.

```c
x16_vera_addr0(X16_INC_2, X16_VRAM_TEXT);
x16_vera_fill('*', 80);                 /* stars across the top row */
```

### `void x16_vera_copy(unsigned int count)`

Copy `count` bytes from port 0 (source) to port 1 (destination), each
walking at its own increment.

```c
/* Duplicate the top text row onto the second row. */
x16_vera_addr0(X16_INC_1, X16_VRAM_TEXT);
x16_vera_addr1(X16_INC_1, X16_VRAM_TEXT + 256);
x16_vera_copy(160);
```

Note: `x16_vera_copy()` leaves port 1 selected. Call a KERNAL screen
routine afterwards only through `x16/screen.h`, which resets ADDRSEL.

### `unsigned char x16_vera_has_fx(void)`

Returns 1 if the VERA firmware carries the FX register set (v0.3.1+,
emulator R44+), else 0. Call it before using anything in
`x16/verafx.h`.

```c
if (x16_vera_has_fx()) {
    x16_fx_clear(320u * 240u, X16_VRAM_BITMAP);
} else {
    x16_gfx_clear(0);                   /* software fallback */
}
```

---

## `x16/screen.h` — screen mode, text, cursor

Wrappers over the KERNAL's screen editor. Their extra value over raw
KERNAL calls: each one clears ADDRSEL first, so they stay safe after
`x16_vera_addr1()`/`x16_vera_copy()` have left port 1 selected.

**Mode constants**: `X16_MODE_80x60`, `X16_MODE_80x30`,
`X16_MODE_40x60`, `X16_MODE_40x30`, `X16_MODE_40x15`, `X16_MODE_20x30`,
`X16_MODE_20x15`, `X16_MODE_22x23`, `X16_MODE_64x50`, `X16_MODE_64x25`,
`X16_MODE_32x50`, `X16_MODE_32x25`, and `X16_MODE_320x240` (the bitmap
mode cc65's `videomode()` cannot reach).

### `unsigned char x16_screen_set_mode(unsigned char mode)`

Switch screen modes. Returns 1 on success, 0 if the mode is
unsupported.

```c
if (!x16_screen_set_mode(X16_MODE_40x30)) {
    x16_screen_puts("MODE NOT AVAILABLE\r");
}
```

### `unsigned char x16_screen_get_mode(void)`

The current mode, as one of the constants above.

```c
unsigned char saved = x16_screen_get_mode();
x16_screen_set_mode(X16_MODE_320x240);
/* ...draw... */
x16_screen_set_mode(saved);             /* put it back */
```

### `void x16_screen_reset(void)`

KERNAL `CINT`: back to the default text mode, default charset, cleared
screen. The heavy hammer.

```c
x16_screen_reset();                     /* undo everything visual */
```

### `void x16_screen_cls(void)`

Clear the screen and home the cursor.

```c
x16_screen_cls();
```

### `void x16_screen_chrout(unsigned char c)`

Print one PETSCII character — KERNAL `CHROUT` with ADDRSEL forced to 0
first. Control codes work (`'\r'` is newline).

```c
x16_screen_chrout('A');
x16_screen_chrout('\r');
```

### `void x16_screen_puts(const char *s)`

Print a NUL-terminated string. Truncated at 255 bytes.

```c
x16_screen_puts("SCORE: 1000\r");
```

### `void x16_screen_color(unsigned char fg, unsigned char bg)`

Colour of every character printed from now on. Both 0–15 (the standard
palette: 0 black, 1 white, 2 red, …; cc65's `COLOR_*` constants in
`<cx16.h>` name them).

```c
x16_screen_color(7, 0);                 /* yellow on black */
x16_screen_puts("WARNING\r");
```

### `void x16_screen_border(unsigned char color)`

The border colour, 0–15.

```c
x16_screen_border(2);                   /* red border */
```

### `void x16_screen_locate(unsigned char row, unsigned char col)`

Move the cursor. Note the order: row first, like the KERNAL, not x/y.

```c
x16_screen_locate(10, 5);               /* row 10, column 5 */
x16_screen_puts("HERE");
```

### `void x16_screen_get_cursor(unsigned char *row, unsigned char *col)`

Read the cursor position back.

```c
unsigned char r, c;
x16_screen_get_cursor(&r, &c);
x16_screen_locate(r + 1, c);            /* one row down, same column */
```

### `void x16_screen_charset(unsigned char charset)`

Select the character set: `X16_CHARSET_ISO`, `X16_CHARSET_PET_UPPER`
(upper case + graphics, the power-on default) or
`X16_CHARSET_PET_LOWER` (upper + lower case).

```c
x16_screen_charset(X16_CHARSET_PET_LOWER);
x16_screen_puts("Now with lower case\r");
```

---

## `x16/palette.h` — the VERA palette

256 entries of 12-bit colour, one 16-bit word each, format `0x0RGB`:
`0x0F00` pure red, `0x00F0` pure green, `0x000F` pure blue. Remember
the palette is in the write-only region — you can read back only what
you wrote yourself.

### `void x16_pal_set(unsigned char index, unsigned int color)`

Set one entry.

```c
x16_pal_set(1, 0x0F80);                 /* entry 1: orange */
```

### `void x16_pal_load(const unsigned int *src, unsigned char first, unsigned char count)`

Bulk-load `count` colours (1–128; 0 loads nothing) from RAM into
entries `first` … `first + count - 1`.

```c
static const unsigned int fire[4] = { 0x0000, 0x0800, 0x0F40, 0x0FF0 };
x16_pal_load(fire, 16, 4);              /* entries 16-19 */
```

---

## `x16/tile.h` — tilemap cells and layers

The `x16_tile_*` routines address **layer 1** — the text screen in the
default modes — and read the layer's registers at run time, so they
keep working after a mode change. A text cell is two bytes: screen
code, then colour attribute (`fg | bg << 4`).

**Config constants** for `x16_layer_set_config()`: colour depth
`X16_LAYER_BPP_1/2/4/8`, `X16_LAYER_BITMAP` (bitmap instead of tile
mode), `X16_LAYER_T256C` (256-colour text), map size
`X16_LAYER_MAPW_32/64/128/256` and `X16_LAYER_MAPH_32/64/128/256`.

### `void x16_layer_on(unsigned char layer)`
### `void x16_layer_off(unsigned char layer)`

Enable or disable one layer (0 or 1) without touching the other.

```c
x16_layer_off(0);                       /* hide the playfield…      */
x16_layer_on(1);                        /* …keep the text HUD shown */
```

### `void x16_layer_set_config(unsigned char layer, unsigned char config)`

Write the layer's config byte, assembled from the constants above.

```c
/* Layer 0: a 64x32 tilemap of 4bpp tiles. */
x16_layer_set_config(0, X16_LAYER_MAPW_64 | X16_LAYER_MAPH_32 |
                        X16_LAYER_BPP_4);
```

### `void x16_layer_set_mapbase(unsigned char layer, unsigned char mapbase)`

Where the layer's map lives. `mapbase` is the VRAM address `>> 9`, so
the map must be 512-byte aligned.

```c
x16_layer_set_mapbase(0, 0x10000UL >> 9);   /* map at VRAM $10000 */
```

### `void x16_layer_set_tilebase(unsigned char layer, unsigned char tilebase)`

Where the tile images live plus the tile size:
`(addr >> 11) << 2`, or'd with the size bits (bit 0: tile width 16,
bit 1: tile height 16; both clear means 8x8).

```c
x16_layer_set_tilebase(0, (0x14000UL >> 11) << 2);  /* 8x8 tiles at $14000 */
```

### `void x16_layer_scroll_x(unsigned char layer, unsigned int value)`
### `void x16_layer_scroll_y(unsigned char layer, unsigned int value)`

12-bit hardware scroll, 0–4095.

```c
unsigned int cam = 0;
for (;;) {
    x16_vsync_wait();
    x16_layer_scroll_x(0, cam++ & 0x0FFF);   /* scroll the playfield */
}
```

### `void x16_tile_setptr(unsigned char col, unsigned char row)`

Point data port 0 at a layer-1 cell, auto-incrementing, and leave
ADDRSEL at 0. Stream cells through `VERA.data0` afterwards.

```c
x16_tile_setptr(0, 5);                  /* start of row 5 */
```

### `void x16_tile_put(unsigned char col, unsigned char row, unsigned char code, unsigned char attr)`

Write one cell: screen code + colour attribute.

```c
x16_tile_put(10, 5, 0x01, 0x61);        /* 'A', white on blue */
```

### `unsigned int x16_tile_get(unsigned char col, unsigned char row)`

Read one cell back as `code | attr << 8`. Unpack with
`X16_TILE_CODE(v)` and `X16_TILE_ATTR(v)`.

```c
unsigned int v = x16_tile_get(10, 5);
if (X16_TILE_CODE(v) == 0x01) { /* there is an 'A' there */ }
```

---

## `x16/sprite.h` — hardware sprites

128 sprites, an 8-byte attribute record each. Two things to remember:
the attribute RAM is **write-only** (call `x16_sprite_init_all()` once
so read-modify-writes have a known shadow), and coordinates are in
**640x480 display space** whatever the screen mode.

**Constants**: colour depth `X16_SPRITE_4BPP` / `X16_SPRITE_8BPP`;
Z-depth `X16_SPRITE_Z_DISABLED` / `_BEHIND` / `_MIDDLE` / `_FRONT`;
flips `X16_SPRITE_HFLIP` / `X16_SPRITE_VFLIP`; sizes
`X16_SPRITE_SIZE_8/16/32/64`; and the `X16_SPRITE_ATTR_*` byte offsets
for `x16_sprite_setptr()`.

### `void x16_sprite_init_all(void)`

Zero all 128 records: every sprite disabled, and the write-only RAM
given a known shadow. Call once at startup.

```c
x16_sprite_init_all();
x16_sprites_on();
```

### `void x16_sprites_on(void)`
### `void x16_sprites_off(void)`

The sprite renderer as a whole.

```c
x16_sprites_off();                      /* hide everything at once */
```

### `void x16_sprite_pos(unsigned char sprite, unsigned int x, unsigned int y)`

Position sprite 0–127; `x` and `y` are 10-bit, in 640x480 space.

```c
x16_sprite_pos(0, 320, 240);            /* dead centre */
```

### `void x16_sprite_get_pos(unsigned char sprite, unsigned int *x, unsigned int *y)`

Read a position back (from the shadow — see the write-only note).

```c
unsigned int sx, sy;
x16_sprite_get_pos(0, &sx, &sy);
x16_sprite_pos(0, sx + 1, sy);          /* nudge right */
```

### `void x16_sprite_image(unsigned char sprite, unsigned char mode, unsigned long addr)`

Point a sprite at its pixel data in VRAM.

- `mode` — `X16_SPRITE_4BPP` or `X16_SPRITE_8BPP`.
- `addr` — must be 32-byte aligned; the low five bits are dropped.

```c
x16_sprite_image(0, X16_SPRITE_8BPP, 0x13000UL);
```

### `void x16_sprite_flags(unsigned char sprite, unsigned char flags)`

Write attribute byte 6 whole: collision mask (bits 7:4), Z-depth,
vflip, hflip. A sprite becomes visible when its Z-depth is non-zero.

```c
x16_sprite_flags(0, X16_SPRITE_Z_FRONT | X16_SPRITE_HFLIP);
```

### `void x16_sprite_z(unsigned char sprite, unsigned char z)`

Change only the Z-depth, preserving the rest of byte 6. This is a
read-modify-write, so it needs the shadow from `x16_sprite_init_all()`.

```c
x16_sprite_z(0, X16_SPRITE_Z_DISABLED); /* hide sprite 0, keep flags */
```

### `void x16_sprite_size(unsigned char sprite, unsigned char width, unsigned char height, unsigned char pal_offset)`

Size codes (`X16_SPRITE_SIZE_8/16/32/64`, independently per axis) and
the palette offset 0–15 (colour index = pixel value + 16*offset, for
4bpp images).

```c
x16_sprite_size(0, X16_SPRITE_SIZE_16, X16_SPRITE_SIZE_16, 0);
```

### `void x16_sprite_setptr(unsigned char sprite, unsigned char offset)`

Point data port 0 at one byte of a sprite's record
(`X16_SPRITE_ATTR_*`), auto-incrementing — for streaming several fields
through `VERA.data0` yourself.

```c
x16_sprite_setptr(0, X16_SPRITE_ATTR_X_L);  /* then write x lo, x hi… */
```

A complete minimal sprite:

```c
x16_sprite_init_all();
x16_sprite_image(0, X16_SPRITE_8BPP, X16_VRAM_SPRITE_DATA);
x16_sprite_size(0, X16_SPRITE_SIZE_16, X16_SPRITE_SIZE_16, 0);
x16_sprite_pos(0, 320, 240);
x16_sprite_flags(0, X16_SPRITE_Z_FRONT);
x16_sprites_on();
```

---

## `x16/bitmap.h` — 320x240 bitmap drawing

An 8bpp framebuffer at VRAM $00000: one byte per pixel, rows of
`X16_GFX_WIDTH` (320), `X16_GFX_HEIGHT` (240) rows. Only
`x16_gfx_pset()`, the circles and text clip; **lines, rects and frames
do not** — keep their arguments on screen, or pre-clip with
`x16/clip.h`.

### `unsigned char x16_gfx_init(void)`

Switch to 320x240@256c on layer 0 with 40x30 text on layer 1. Returns
1 on success. Everything below assumes this mode (though the drawing
routines only touch VRAM, so they also work on an off-screen buffer).

```c
if (!x16_gfx_init()) return 1;
```

### `void x16_gfx_clear(unsigned char color)`

Fill the whole framebuffer with one colour.

```c
x16_gfx_clear(0);                       /* black */
```

### `void x16_gfx_pset(unsigned int x, unsigned char y, unsigned char color)`

Plot one pixel. Clipped: off-screen coordinates are safely ignored.

```c
x16_gfx_pset(160, 120, 2);              /* red dot in the middle */
```

### `void x16_gfx_hline(unsigned int x, unsigned char y, unsigned int len, unsigned char color)`

Horizontal run of `len` pixels starting at (x, y). Unclipped.

```c
x16_gfx_hline(0, 120, 320, 1);          /* white line across */
```

### `void x16_gfx_vline(unsigned int x, unsigned char y, unsigned char len, unsigned char color)`

Vertical run. `len` is 1–255 (a 240-row screen never needs more).
Unclipped.

```c
x16_gfx_vline(160, 0, 240, 1);          /* white line down */
```

### `void x16_gfx_rect(unsigned int x, unsigned char y, unsigned int w, unsigned char h, unsigned char color)`

Filled rectangle. Unclipped.

```c
x16_gfx_rect(100, 80, 120, 80, 6);      /* filled blue box */
```

### `void x16_gfx_frame(unsigned int x, unsigned char y, unsigned int w, unsigned char h, unsigned char color)`

Rectangle outline, one pixel thick. Unclipped.

```c
x16_gfx_frame(99, 79, 122, 82, 1);      /* white border around it */
```

### `void x16_gfx_line(unsigned int x0, unsigned char y0, unsigned int x1, unsigned char y1, unsigned char color)`

Bresenham line, any direction. Unclipped — see `x16_clip_line()` for
endpoints that may leave the screen.

```c
x16_gfx_line(0, 0, 319, 239, 5);        /* green diagonal */
```

### `void x16_gfx_circle(unsigned int cx, unsigned char cy, unsigned char r, unsigned char color)`
### `void x16_gfx_disc(unsigned int cx, unsigned char cy, unsigned char r, unsigned char color)`

Circle outline and filled disc. Radius 0–120. These DO clip, at every
edge.

```c
x16_gfx_circle(160, 120, 60, 1);        /* ring */
x16_gfx_disc(160, 120, 20, 2);          /* solid red centre */
```

### `void x16_gfx_char(unsigned int x, unsigned char y, unsigned char color, unsigned char code)`

Draw one glyph from the KERNAL's charset at VRAM $1F000. Set bits
become `color`, clear bits stay transparent. `code` is a **screen
code**, not PETSCII. Clips.

```c
x16_gfx_char(8, 8, 1, 0x01);            /* screen code 1 = 'A' */
```

### `void x16_gfx_text(unsigned int x, unsigned char y, unsigned char color, const char *s)`

A NUL-terminated string, 8 pixels per character. ASCII letters convert
to screen codes for you, so plain strings read as expected. Clips.

```c
x16_gfx_text(100, 4, 1, "GAME OVER");
```

### `unsigned char x16_gfx_flood(unsigned int x, unsigned char y, unsigned char color)`

Scanline flood fill of the 4-connected region under the seed. Filling
with the colour already there is a no-op. Returns 1 when the region was
filled completely, 0 when the internal span stack (170 deep) overflowed
and the fill is incomplete — only pathological shapes (long thin
spirals) do that.

```c
x16_gfx_circle(160, 120, 60, 1);
x16_gfx_flood(160, 120, 3);             /* fill the inside cyan */
```

---

## `x16/verafx.h` — VERA FX acceleration

Hardware multiply, 4x-speed fills and copies, hardware lines and filled
triangles. **Requires VERA firmware v0.3.1+** — check
`x16_vera_has_fx()` first; on older VERA these routines quietly do the
wrong thing. Every routine here leaves FX disabled and DCSEL at 0 on
the way out.

### `void x16_fx_off(void)`

Disable FX and restore DCSEL. Safe whether or not FX was ever enabled;
you rarely need it, since the other routines already clean up.

```c
x16_fx_off();                           /* belt and braces */
```

### `long x16_fx_mult(int a, int b)`

Signed 16x16 → 32 multiply in hardware. Far faster than
`x16_umul16()`, and signed — but it clobbers four bytes of VRAM scratch
at `X16_VRAM_FX_SCRATCH` ($1F800, an unused corner).

```c
long area = x16_fx_mult(dx, dy);
```

### `void x16_fx_fill(unsigned char value, unsigned int count, unsigned long addr)`

Fill `count` bytes of VRAM at `addr` with `value`, about four times
faster than a byte loop (the 32-bit cache writes four bytes per
access). A remainder count is finished one byte at a time.

```c
x16_fx_fill(2, 320u * 240u, X16_VRAM_BITMAP);   /* red screen, fast */
```

### `void x16_fx_clear(unsigned int count, unsigned long addr)`

`x16_fx_fill()` with value 0.

```c
x16_fx_clear(320u * 240u, X16_VRAM_BITMAP);     /* fast black */
```

### `void x16_fx_copy(unsigned long src, unsigned long dst, unsigned int count)`

VRAM-to-VRAM copy through the 32-bit cache, about 4x a byte loop.
`dst` must be **4-byte aligned**; `src` needs no alignment.

```c
/* Copy the top half of the framebuffer onto the bottom half. */
x16_fx_copy(X16_VRAM_BITMAP, X16_VRAM_BITMAP + 38400UL, 38400u);
```

### `void x16_fx_transp_on(void)`
### `void x16_fx_transp_off(void)`

Transparent VRAM writes: while on, a zero byte written to a data port
leaves the target alone, so colour 0 acts as transparency for blits.
Note that every *other* `x16_fx_*` routine turns this off again on its
way out — enable, do your writes, disable.

```c
x16_fx_transp_on();
x16_vera_addr0(X16_INC_1, X16_VRAM_BITMAP + 100);
x16_vera_fill(0, 8);                    /* writes nothing: 0 is transparent */
x16_fx_transp_off();
```

### `void x16_fx_line(unsigned int x0, unsigned char y0, unsigned int x1, unsigned char y1, unsigned char color)`

The same endpoints as `x16_gfx_line()`, but VERA carries the Bresenham
error: the CPU does one store per pixel. Assumes the `x16_gfx_init()`
framebuffer. Does **not** clip.

```c
x16_fx_line(0, 239, 319, 0, 7);         /* yellow diagonal, hardware */
```

### `void x16_fx_triangle(const x16_point *a, const x16_point *b, const x16_point *c, unsigned char color)`

Filled triangle; vertices in any order. `x16_point` is
`{ unsigned int x; unsigned char y; }` — **do not reorder its fields**,
they are copied byte-for-byte onto the assembly's operand block. The
rasterisation is half-open: the bottom row is not drawn, so two
triangles sharing an edge paint it once, not twice.

```c
x16_point a = { 160,  20 };
x16_point b = {  40, 200 };
x16_point c = { 280, 200 };
x16_fx_triangle(&a, &b, &c, 4);         /* purple triangle */
```

---

## `x16/psg.h` — the 16-voice PSG

A voice is four bytes in VRAM: frequency word, pan|volume,
waveform|width. The PSG is in the write-only region, so call
`x16_psg_init()` before anything that read-modify-writes
(`x16_psg_note_off()`, the envelopes).

**Constants**: panning `X16_PSG_PAN_LEFT` / `_RIGHT` / `_BOTH` (neither
bit set is silence); waveforms `X16_PSG_WAVE_PULSE` / `_SAWTOOTH` /
`_TRIANGLE` / `_NOISE`.

**`X16_PSG_HZ(hz)`** converts a pitch in Hz to the frequency word
(`freq = hz * 2.68435…`). A literal folds at compile time; a variable
costs one 32-bit multiply. `X16_PSG_HZ(440)` is 1181.

### `void x16_psg_init(void)`

Silence all 16 voices and give the write-only region a known shadow.
Call first.

```c
x16_psg_init();
```

### `void x16_psg_set_freq(unsigned char voice, unsigned int freq)`

Set voice 0–15's frequency word. It writes the high byte first so the
pitch never passes through a garbage intermediate value.

```c
x16_psg_set_freq(0, X16_PSG_HZ(440));   /* A4 */
```

### `void x16_psg_set_vol(unsigned char voice, unsigned char vol, unsigned char pan)`

Volume 0–63 plus an `X16_PSG_PAN_*` constant.

```c
x16_psg_set_vol(0, 40, X16_PSG_PAN_BOTH);
```

### `void x16_psg_set_wave(unsigned char voice, unsigned char wave, unsigned char width)`

Waveform and width 0–63: the duty cycle for `PULSE`, an XOR amount for
the other waveforms.

```c
x16_psg_set_wave(0, X16_PSG_WAVE_PULSE, 32);    /* square wave */
```

A beep, complete:

```c
x16_psg_init();
x16_psg_set_freq(0, X16_PSG_HZ(440));
x16_psg_set_wave(0, X16_PSG_WAVE_PULSE, 32);
x16_psg_set_vol(0, 40, X16_PSG_PAN_BOTH);       /* sounds now */
```

### `void x16_psg_note_off(unsigned char voice)`

Volume to zero, panning kept. Safe from an ISR.

```c
x16_psg_note_off(0);
```

### `void x16_psg_voice_ptr(unsigned char voice, unsigned char offset)`

Point data port 0 at one register (offset 0–3) of a voice,
auto-incrementing — for driving the PSG registers yourself.

```c
x16_psg_voice_ptr(0, 0);                /* then stream 4 bytes to data0 */
```

### The ASR envelopes

The volume decay everybody hand-rolls in the frame loop. Attack ramps
up to `peak`, sustain holds, release ramps to silence. Set the voice's
frequency, wave and pan first; the envelope drives only the volume
bits.

### `void x16_psg_env_start(unsigned char voice, unsigned char peak, unsigned char attack, unsigned char sustain, unsigned char release)`

Arm an envelope.

- `peak` — target volume 0–63.
- `attack` — volume steps per frame going up; 0 jumps straight to peak.
- `sustain` — frames to hold; 255 holds until `x16_psg_env_release()`.
  0 releases at once.
- `release` — volume steps per frame going down; 0 holds at the peak
  until `x16_psg_env_stop()`.

### `void x16_psg_env_release(unsigned char voice)`

Enter the release phase now (the "key up" of a held note).

### `void x16_psg_env_stop(unsigned char voice)`

Silence and disarm immediately.

### `void x16_psg_env_tick(void)`

Advance every armed envelope one step. Call once per frame — from a
VSYNC callback is fine, the IRQ wrapper saves the zero page for you.

All four together:

```c
x16_psg_init();
x16_psg_set_freq(0, X16_PSG_HZ(880));
x16_psg_set_wave(0, X16_PSG_WAVE_PULSE, 32);
x16_psg_set_vol(0, 0, X16_PSG_PAN_BOTH);        /* pan only, vol 0 */
x16_psg_env_start(0, 60, 8, 20, 4);             /* ping */

for (;;) {
    x16_vsync_wait();
    x16_psg_env_tick();
    if (key_pressed)  x16_psg_env_release(0);   /* let it fade */
    if (panic_button) x16_psg_env_stop(0);      /* silence now */
}
```

---

## `x16/ym.h` — the YM2151 FM chip

Two ways in, and they do not mix freely: `x16_ym_write()` hits chip
registers directly (fast, complete access, but leaves the ROM driver's
volume/pan shadows stale); everything else goes through the ROM driver
and keeps those shadows coherent. Pick one style per program.

Note the argument order: `x16_ym_write()`/`x16_ym_poke()` take
`(register, value)`; the note API takes `(channel, ...)`.

**Constants**: panning `X16_YM_PAN_OFF/LEFT/RIGHT/BOTH`;
`X16_YM_NOTE(octave, semitone)` packs a note (octave 0–7, semitone
1–12 with 1 = C); `X16_YM_NOTE_RELEASE` (0) releases;
`X16_YM_RETRIGGER` / `X16_YM_HOLD` for the retrigger argument.

### `unsigned char x16_ym_init(void)`

Reset the chip and load the default instrument patches. Returns 0 if
the machine has no YM2151. Must precede the patch functions.

```c
if (!x16_ym_init()) { x16_screen_puts("NO FM CHIP\r"); return 1; }
```

### `unsigned char x16_ym_write(unsigned char reg, unsigned char value)`

Raw register write — the only route to the LFO and per-operator
envelopes. Returns 0 if the chip stayed busy.

```c
x16_ym_write(0x0F, 0x00);               /* noise off */
```

### `void x16_ym_poke(unsigned char reg, unsigned char value)`

The same write, through the ROM driver, keeping its shadows coherent.
Use this one if you also use the note API.

```c
x16_ym_poke(0x0F, 0x00);
```

### `unsigned char x16_ym_busy(void)`

1 while the chip is busy. Not an error — just wait.

```c
while (x16_ym_busy()) { }
```

### `unsigned char x16_ym_patch_rom(unsigned char channel, unsigned char patch)`

Load a ROM instrument (0–162) onto channel 0–7.

```c
x16_ym_patch_rom(0, 16);                /* an organ-ish preset */
```

### `unsigned char x16_ym_patch_ram(unsigned char channel, const void *patch)`

Load an instrument definition from RAM.

```c
extern const unsigned char my_patch[]; /* your own voice data */
x16_ym_patch_ram(1, my_patch);
```

### `unsigned char x16_ym_note_bas(unsigned char channel, unsigned char note, unsigned char retrigger)`

Play a packed note from `X16_YM_NOTE()`; 0 releases. This is the one
for playing tunes.

```c
x16_ym_note_bas(0, X16_YM_NOTE(4, 10), X16_YM_RETRIGGER);   /* A-4 */
```

### `void x16_ym_note(unsigned char channel, unsigned char kc, unsigned char kf, unsigned char retrigger)`

A raw YM2151 key code and key fraction — the key fraction is a pitch
bend, which `x16_ym_note_bas()` cannot express.

```c
x16_ym_note(0, 0x4A, 32, X16_YM_HOLD);  /* bend without retriggering */
```

### `void x16_ym_release_note(unsigned char channel)`

Key up: start the patch's release envelope.

```c
x16_ym_release_note(0);
```

### `unsigned char x16_ym_vol(unsigned char channel, unsigned char atten)`

Channel volume as attenuation: 0 is the patch's own volume, larger is
quieter.

```c
x16_ym_vol(0, 8);                       /* a bit quieter */
```

### `unsigned char x16_ym_pan(unsigned char channel, unsigned char pan)`

An `X16_YM_PAN_*` constant.

```c
x16_ym_pan(0, X16_YM_PAN_LEFT);
```

### `unsigned char x16_ym_drum(unsigned char channel, unsigned char note)`

Play a percussion note, 25–87, using the ROM's drum mapping.

```c
x16_ym_drum(7, 35);                     /* kick, roughly */
```

### `unsigned char x16_ym_get_pan(unsigned char channel)`
### `unsigned char x16_ym_get_vol(unsigned char channel)`

Read the ROM driver's shadows. They agree with the chip only if you
have written through `x16_ym_poke`/`_vol`/`_pan`, not raw
`x16_ym_write`.

```c
unsigned char v = x16_ym_get_vol(0);
x16_ym_vol(0, v + 4);                   /* fade one step */
```

---

## `x16/pcm.h` — PCM audio and streaming

VERA's PCM channel is a 4 KB FIFO. Samples are two's-complement
signed. **Startup order matters**: rate 0, prime the FIFO, then the
real rate — starting on an empty FIFO underruns at once.

**Constants** for `x16_pcm_ctrl()`: `X16_PCM_VOLUME(v)` (0–15),
`X16_PCM_STEREO`, `X16_PCM_16BIT`, `X16_PCM_RESET`.
`X16_PCM_RATE_MAX` (128) is full speed, 48828 Hz; rate 0 stops.

### `void x16_pcm_ctrl(unsigned char ctrl)`

Set format and volume in one control byte.

```c
x16_pcm_ctrl(X16_PCM_16BIT | X16_PCM_VOLUME(15));   /* 16-bit mono, max */
```

### `unsigned char x16_pcm_rate(unsigned char rate)`

Set the sample rate: 128 is 48828 Hz, so `rate = hz / 381.5` roughly;
64 is ~24.4 kHz. Returns the rate actually written (`rate` clamped to
128) — the register cannot be read back, so the return value is the
only way to see what landed.

```c
unsigned char r = x16_pcm_rate(200);    /* r == 128: it clamped */
```

### `void x16_pcm_reset(void)`

Clear the FIFO, keeping the current format and volume. Immediate
silence.

```c
x16_pcm_reset();
```

### `unsigned char x16_pcm_full(void)`
### `unsigned char x16_pcm_empty(void)`

FIFO status flags, 1 or 0.

```c
while (!x16_pcm_full()) x16_pcm_put(next_sample());
```

### `void x16_pcm_put(unsigned char sample)`

Push one sample byte. The hardware drops it if the FIFO is full. Safe
from an ISR.

```c
x16_pcm_put(0);                         /* one byte of silence */
```

### `void x16_pcm_write(const void *src, unsigned int count)`

Push a block, up to the FIFO's 4 KB. Does **not** throttle: bytes
written past a full FIFO are discarded. Meant for priming; pace longer
data with `x16_pcm_full()` or use the streamer.

```c
x16_pcm_rate(0);                        /* stopped */
x16_pcm_ctrl(X16_PCM_VOLUME(15));
x16_pcm_write(clip, sizeof clip);       /* prime */
x16_pcm_rate(64);                       /* ~24 kHz, plays now */
```

### The AFLOW streamer

Plays a buffer longer than 4 KB: VERA raises the AFLOW interrupt when
the FIFO drops below a quarter full and the handler refills it. The
FIFO is primed before the DAC starts, so playback cannot underrun at
t=0. Requires enabled interrupts. Note `x16_irq_remove()` stops a
stream — with the handler unhooked, nothing could acknowledge AFLOW.

### `void x16_pcm_stream_start(const void *data, unsigned int count, unsigned char rate)`

Start streaming `count` bytes from `data`. Set format and volume with
`x16_pcm_ctrl()` first. `rate` 0 primes without playing.

### `void x16_pcm_stream_stop(void)`

Stop refilling. What is already queued keeps playing; call
`x16_pcm_reset()` for immediate silence.

### `unsigned char x16_pcm_stream_active(void)`

1 while data remains to hand over. Reaches 0 once the last byte is in
the FIFO — which may still be playing.

```c
x16_pcm_ctrl(X16_PCM_VOLUME(15));
x16_pcm_stream_start(song, sizeof song, 64);
while (x16_pcm_stream_active()) {
    /* game keeps running; the interrupt does the refilling */
}
x16_pcm_stream_stop();
```

---

## `x16/adpcm.h` — IMA ADPCM decoding

4:1 audio compression: 16-bit samples stored as 4-bit deltas, so a
second of 16-bit mono at 16 kHz is 8 KB instead of 32. This is the
canonical IMA/DVI algorithm from WAV files, low nibble first. Decoder
state carries across calls, so a long sample decodes a slice at a time.

### `void x16_adpcm_init(void)`

Reset the decoder: predictor 0, step index 0.

```c
x16_adpcm_init();
```

### `void x16_adpcm_set_state(int predictor, unsigned char index)`

An IMA WAV block header carries an initial predictor and step index —
set them before decoding that block's payload.

```c
x16_adpcm_set_state(hdr_predictor, hdr_index);
```

### `int x16_adpcm_predictor(void)`
### `unsigned char x16_adpcm_index(void)`

Read the state back — to checkpoint a stream you will resume later.

```c
int save_p = x16_adpcm_predictor();
unsigned char save_i = x16_adpcm_index();
```

### `int x16_adpcm_nibble(unsigned char code)`

Decode one 4-bit code to a signed 16-bit sample.

```c
int s = x16_adpcm_nibble(byte & 0x0F);  /* low nibble decodes first */
```

### `void x16_adpcm_block(const void *src, void *dst, unsigned int count)`

Decode `count` **source** bytes into signed 16-bit little-endian
samples: two samples — four bytes — out for every byte in, so `dst`
must hold `count * 4` bytes.

```c
x16_adpcm_init();
x16_adpcm_block(compressed, samples, sizeof compressed);
x16_pcm_ctrl(X16_PCM_16BIT | X16_PCM_VOLUME(15));
x16_pcm_stream_start(samples, sizeof compressed * 4, 64);
```

---

## `x16/input.h` — joystick, mouse, keyboard

Thin wrappers over the KERNAL: no driver to install, and the SNES pad's
full button set exposed.

**Joystick bits are active low** — a pressed button reads 0:
`X16_JOY_B/Y/SELECT/START/UP/DOWN/LEFT/RIGHT/A/X/L/R`.
**Mouse buttons** (active high, normal): `X16_MOUSE_LEFT/RIGHT/MIDDLE`.
**Keyboard unpackers**: `X16_KEY_CHAR(v)`, `X16_KEY_COUNT(v)`.

### `void x16_joy_scan(void)`

Sample every joystick. The KERNAL's IRQ already does this once a frame;
you only need it if you have taken the interrupt over.

```c
x16_joy_scan();                         /* only with the IRQ taken over */
```

### `unsigned int x16_joy_get(unsigned char joy, unsigned char *present)`

Read pad `joy`: 0 is the keyboard-as-joystick, 1–4 are gamepads.
Returns the button bits (active low); `*present` becomes 1 or 0.

```c
unsigned char present;
unsigned int b = x16_joy_get(1, &present);
if (present && !(b & X16_JOY_LEFT))  x--;   /* note the ! */
if (present && !(b & X16_JOY_RIGHT)) x++;
```

### `void x16_mouse_show(unsigned char cursor)`
### `void x16_mouse_hide(void)`

Show the mouse pointer — `0xFF` keeps the current cursor sprite, a
smaller number selects cursor sprite n — or hide it.

```c
x16_mouse_show(0xFF);
```

### `unsigned char x16_mouse_get(unsigned int *x, unsigned int *y)`

Returns the button mask (`X16_MOUSE_*`); writes the position through
the pointers.

```c
unsigned int mx, my;
if (x16_mouse_get(&mx, &my) & X16_MOUSE_LEFT) {
    x16_gfx_pset(mx >> 1, my >> 1, 1);  /* 640x480 -> 320x240 */
}
```

### `unsigned char x16_key_get(void)`

The next key as PETSCII, or 0 if nothing is waiting. Non-blocking.

```c
unsigned char c = x16_key_get();
if (c == 'Q') running = 0;
```

### `unsigned char x16_key_wait(void)`

Blocks until a key arrives.

```c
x16_screen_puts("PRESS ANY KEY\r");
x16_key_wait();
```

### `unsigned int x16_key_peek(void)`

The next key without consuming it, plus the queue depth, packed as
`key | queued << 8`. **When the queue is empty only the count is
meaningful** — always test it first:

```c
unsigned int p = x16_key_peek();
if (X16_KEY_COUNT(p) && X16_KEY_CHAR(p) == 'Y') {
    x16_key_get();                      /* now consume it */
}
```

---

## `x16/irq.h` — VSYNC, raster and collision interrupts

`x16_irq_install()` chains onto the KERNAL's IRQ vector — the KERNAL
still scans the keyboard and acknowledges VSYNC. The library unhooks
itself at exit even if you forget.

**Callbacks may be written in plain C.** Before calling one, the
library saves cc65's zero-page runtime and its own scratch (42 bytes,
~950 cycles, only when a callback is installed), so a callback may call
anything — C code, any `x16_*` routine. It must still stay short, and
save/restore any VERA state it touches (CTRL, and the address of any
data port it reprograms).

Handler types:

```c
typedef void (*x16_irq_handler)(void);
typedef void __fastcall__ (*x16_sprcol_handler)(unsigned char groups);
```

### `void x16_irq_install(void)`

Start counting frames. Idempotent; the raster and collision installers
call it for you.

```c
x16_irq_install();
```

### `void x16_irq_remove(void)`

Restore the previous handler and disable every source this library owns
— **including AFLOW, so a PCM stream in progress stops** (nothing else
could acknowledge it). Idempotent. Called automatically at program
exit.

```c
x16_irq_remove();
```

### `unsigned char x16_irq_frames(void)`

The frame counter, wrapping at 256. Byte subtraction wraps correctly,
so deltas stay valid across the wrap:

```c
unsigned char start = x16_irq_frames();
do_work();
elapsed = (unsigned char)(x16_irq_frames() - start);
```

### `void x16_vsync_wait(void)`

Block until the next frame boundary. Waits for the counter to *change*,
so it can neither miss a frame nor spin twice within one. Requires
enabled interrupts — under the emulator's headless `-testbench` (no
video, no VSYNC) it would hang.

```c
for (;;) {
    update();
    x16_vsync_wait();                   /* one iteration per frame */
    draw();
}
```

### `void x16_irq_line_install(unsigned int line, x16_irq_handler handler)`
### `void x16_irq_line_remove(void)`

Call `handler` when VERA's beam reaches `line` (0–511; the visible
display is 0–479), every frame. This is how a fixed status bar sits
over a scrolling playfield: change the display registers at the split
and change them back at VSYNC.

```c
void split(void)
{
    x16_layer_scroll_x(0, 0);           /* HUD region doesn't scroll */
}

x16_irq_line_install(400, split);
/* per frame, before line 400: x16_layer_scroll_x(0, cam); */
```

### `void x16_irq_sprcol_install(x16_sprcol_handler handler)`
### `void x16_irq_sprcol_remove(void)`

Hardware sprite collisions: VERA compares the collision masks of every
sprite pair once per frame (mask = top nibble of attribute byte 6, set
via `x16_sprite_flags()`). Two sprites collide when their masks share a
bit AND their rectangles overlap. `handler` may be `NULL` — the groups
still accumulate for polling.

### `unsigned char x16_sprite_collisions(void)`

Read **and clear** the collision groups seen since the last call; 0
means none. Atomic against the accumulating interrupt. Requires
`x16_irq_sprcol_install()` (a NULL handler is how you poll).

```c
x16_irq_sprcol_install(NULL);           /* poll mode */
for (;;) {
    x16_vsync_wait();
    if (x16_sprite_collisions()) {      /* something touched something */
        on_hit();
    }
}
```

---

## `x16/bank.h` — banked RAM

`RAM_BANK` selects which 8 KB bank appears at $A000–$BFFF
(`X16_BANK_SIZE` = 8192). Bank 0 belongs to the KERNAL; banks 1–255 are
yours. Offsets are 0–8191 into the window. Every routine here saves and
restores `RAM_BANK`, and the bulk copies auto-advance across bank
boundaries.

### `void x16_bank_set(unsigned char bank)`
### `unsigned char x16_bank_get(void)`

Select / read the current bank. Both safe from an ISR.

```c
unsigned char old = x16_bank_get();
x16_bank_set(3);
/* ...use BANK_RAM[] from <cx16.h> directly... */
x16_bank_set(old);
```

### `unsigned char x16_bank_peek(unsigned char bank, unsigned int offset)`
### `void x16_bank_poke(unsigned char bank, unsigned int offset, unsigned char value)`

One byte, any bank, without disturbing the current mapping.

```c
x16_bank_poke(3, 0, 42);
if (x16_bank_peek(3, 0) == 42) { /* round trip */ }
```

### `void x16_mem_to_bank(const void *src, unsigned char bank, unsigned int offset, unsigned int count)`
### `void x16_bank_to_mem(unsigned char bank, unsigned int offset, void *dst, unsigned int count)`

Bulk copies between low RAM and banked RAM. A run that reaches the end
of a bank continues at offset 0 of the next.

```c
char level[4096];
x16_mem_to_bank(level, 2, 0, sizeof level);     /* stash in bank 2  */
x16_bank_to_mem(2, 0, level, sizeof level);     /* and fetch back   */
```

### `void x16_bank_copy_far(unsigned char src_bank, unsigned int src_offset, unsigned char dst_bank, unsigned int dst_offset, unsigned int count)`

Banked RAM to banked RAM. Only one bank fits in the window at a time,
so it bounces through a 128-byte low-RAM buffer. Both sides
auto-advance across bank edges.

```c
x16_bank_copy_far(2, 0, 3, 0, X16_BANK_SIZE);   /* clone bank 2 -> 3 */
```

### The whole-bank allocator

Hands out bank *numbers* from a bitmap over banks 1–255; it never
touches `RAM_BANK` itself. Before `x16_bank_alloc_init()` nothing is
allocatable, so a forgotten init fails cleanly.

### `void x16_bank_alloc_init(unsigned char first, unsigned char last)`

Define the pool, both bounds inclusive, `first <= last`. Calling it
again resets the pool.

### `unsigned char x16_bank_alloc(void)`

The lowest free bank, or 0 when the pool is exhausted.

### `void x16_bank_free(unsigned char bank)`

Give a bank back. There is no ownership record: freeing a bank that was
never allocated quietly marks it allocatable — don't.

### `unsigned char x16_bank_reserve(unsigned char bank)`

Claim a specific bank. Returns 1 if it was free and is now yours, 0 if
already taken or outside the pool.

```c
x16_bank_alloc_init(1, 63);             /* a 512K machine, minus bank 0 */

unsigned char b = x16_bank_alloc();
if (b == 0) die("OUT OF BANKS");

x16_bank_reserve(63);                   /* keep 63 for the save file */
/* ... */
x16_bank_free(b);
```

---

## `x16/mem.h` — KERNAL block operations

Wrappers over the KERNAL's `MEMORY_FILL`, `MEMORY_COPY`, `MEMORY_CRC`
and `MEMORY_DECOMPRESS` — hand-unrolled loops, far faster than C.

**The special property**: addresses in $9F00–$9FFF are *not*
incremented during the operation. Pass `X16_VERA_DATA0` or
`X16_VERA_DATA1` as a source or target and the operation streams
through VERA's data port at whatever increment the port is set to —
which is how you fill, copy, CRC or **decompress straight into VRAM**.

### `void x16_mem_fill(void *dst, unsigned int count, unsigned char value)`

Set `count` bytes at `dst` to `value`. Count 0 fills nothing.

```c
char buf[512];
x16_mem_fill(buf, sizeof buf, 0);
```

### `void x16_mem_copy(const void *src, void *dst, unsigned int count)`

Copy `count` bytes; the regions may overlap.

```c
x16_mem_copy(buf, buf + 1, 511);        /* overlapping shift is fine */
```

### `unsigned int x16_mem_crc(const void *addr, unsigned int count)`

CRC-16/IBM-3740 of a block. An empty block returns the algorithm's
initial value, 0xFFFF.

```c
if (x16_mem_crc(save, sizeof save) != expected) { /* corrupt */ }
```

### `void *x16_mem_decompress(const void *src, void *dst)`

Decompress a raw LZSA2 block — **the depacker is in ROM, free**.
Returns one past the last output byte, so the unpacked length is the
return value minus `dst`. Cannot decompress in place. Compress assets
with:

```
lzsa -r -f2 original.bin compressed.lzsa
```

(the `-r` matters: a raw block, no frame header).

```c
/* Unpack a compressed tileset straight into video memory --
** no staging buffer, no second copy. */
x16_vera_addr0(X16_INC_1, X16_VRAM_SPRITE_DATA);
x16_mem_decompress(tiles_lzsa, X16_VERA_DATA0);
```

---

## `x16/load.h` — load and save

Device 8 (`X16_DEVICE_SD`) is the SD card. Filenames are
**(pointer, length)**, not NUL-terminated — pass `strlen(name)` or a
literal count.

The **secondary address** (`sa`) says how to treat the file's 2-byte
PRG header; it does not choose where the bytes land:

| Constant | Meaning |
|---|---|
| `X16_SA_ADDR` | skip the header, load at `dest` |
| `X16_SA_HEADER` | skip it, load where the header itself says |
| `X16_SA_RAW` | no header: load the whole file at `dest` |

### `unsigned char x16_fs_load(const char *name, unsigned char len, unsigned char device, unsigned char sa, void *dest, unsigned int *end)`

Load a file. Returns 0 on success, else the KERNAL error code. `*end`
receives the address one past the last byte loaded — pass `NULL` if you
don't care.

```c
char buf[8192];
unsigned int end;
if (x16_fs_load("LEVEL1.BIN", 10, X16_DEVICE_SD,
                X16_SA_RAW, buf, &end) == 0) {
    unsigned int size = end - (unsigned int)buf;
}
```

### `unsigned char x16_fs_save(const char *name, unsigned char len, unsigned char device, const void *start, const void *end)`

Write `[start, end)` — `end` exclusive — as a PRG with the usual 2-byte
header. Returns 0 on success, else the KERNAL error code.

```c
if (x16_fs_save("SCORES.DAT", 10, X16_DEVICE_SD,
                scores, scores + sizeof scores) != 0) {
    x16_dos_status();                   /* ask WHY -- see x16/dos.h */
}
```

### `unsigned char x16_fs_vload(const char *name, unsigned char len, unsigned char device, unsigned long vaddr)`

Load straight into VRAM at `vaddr`, skipping the PRG header. No cc65
equivalent exists. Returns 0 on success.

```c
x16_gfx_init();
x16_fs_vload("TITLE.BIN", 9, X16_DEVICE_SD, X16_VRAM_BITMAP);
```

### `void x16_fs_setname(const char *name, unsigned char len)`

KERNAL `SETNAM`, for driving `OPEN` and friends yourself via
`<cbm.h>`.

```c
x16_fs_setname("DATA,S,R", 8);
```

One trap worth knowing: KERNAL `OPEN` **succeeds for a missing file**;
the error only surfaces later. When a load or read misbehaves, ask the
DOS status (below) for the real reason.

---

## `x16/dos.h` — the DOS command channel

`x16_fs_load()`/`x16_fs_save()` report *that* they failed, never *why*.
The answer lives on channel 15: every command is answered with a status
line like `62,FILE NOT FOUND,00,00`. Codes below `X16_DOS_OK_BELOW`
(20) are success; `X16_DOS_NO_CHANNEL` (255) means the channel would
not open. The first status read after power-on returns 73, the DOS
version banner — by design.

### `void x16_dos_set_device(unsigned char device)`

Which drive the commands go to. Defaults to 8, the SD card.

```c
x16_dos_set_device(9);                  /* a second drive */
```

### `unsigned char x16_dos_status(void)`

Read the drive's pending status line; returns the numeric code.

### `const char *x16_dos_msg(void)`

The reply text of the last command, NUL-terminated. The next command
overwrites it — copy it if you need to keep it.

```c
if (x16_fs_save("A.DAT", 5, 8, buf, buf + 100) != 0) {
    x16_dos_status();
    printf("%s\n", x16_dos_msg());      /* e.g. "63,FILE EXISTS,00,00" */
}
```

### `unsigned char x16_dos_cmd(const char *cmd, unsigned char len)`

Send a raw DOS command and fetch the reply. Length 0 sends nothing and
just reads the pending status.

```c
x16_dos_cmd("CP2", 3);                  /* switch to partition 2 */
```

### `unsigned char x16_dos_delete(const char *name, unsigned char len)`
### `unsigned char x16_dos_mkdir(const char *name, unsigned char len)`
### `unsigned char x16_dos_rmdir(const char *name, unsigned char len)`
### `unsigned char x16_dos_chdir(const char *name, unsigned char len)`

One-call wrappers; each returns the status code. Filenames are
(pointer, length). For `chdir`, `"//"` is the root.

```c
x16_dos_mkdir("SAVES", 5);
x16_dos_chdir("SAVES", 5);
/* ...write save files here... */
x16_dos_chdir("//", 2);                 /* back to the root */
x16_dos_delete("OLD.DAT", 7);
x16_dos_rmdir("TEMP", 4);
```

### `unsigned char x16_dos_rename(const char *oldname, unsigned char oldlen, const char *newname, unsigned char newlen)`

Rename a file.

```c
x16_dos_rename("SCORES.DAT", 10, "SCORES.BAK", 10);
```

---

## `x16/bmx.h` — BMX image files

BMX is the X16's native bitmap format — the one the community's tools
and Prog8 write. Version 1: a 16-byte header, the palette in VERA's own
layout, then the pixels.

Error codes: `X16_BMX_ERR_IO` (open/read/write failed — including a
file that simply is not there), `X16_BMX_ERR_FORMAT` (not a BMX, or not
version 1), `X16_BMX_ERR_PACKED` (compressed BMX not supported).

The image description (field order is load-bearing — do not reorder):

```c
typedef struct {
    unsigned int  width;
    unsigned int  height;
    unsigned char bpp;          /* 1, 2, 4 or 8 */
    unsigned char palstart;     /* first palette index */
    unsigned int  palcount;     /* 1-256 entries */
    unsigned char border;
    unsigned int  stride;       /* VRAM bytes between row starts */
} x16_bmx_info;
```

### `unsigned char x16_bmx_load(const char *name, unsigned char len, unsigned char device, unsigned long vaddr)`

Load a BMX: palette into the VERA palette, pixels into VRAM at `vaddr`.
Returns 0 on success, else an `X16_BMX_ERR_*` code. Rows land `stride`
bytes apart (320 by default, the full-screen stride) — so a 320-wide
image loads contiguously and a narrower one lands as a "stamp".

```c
x16_gfx_init();
if (x16_bmx_load("TITLE.BMX", 9, X16_DEVICE_SD, X16_VRAM_BITMAP)) {
    x16_dos_status();
    x16_screen_puts(x16_dos_msg());     /* the real reason */
}
```

### `void x16_bmx_get_info(x16_bmx_info *out)`

Read what the last load found (or what the next save will write).

```c
x16_bmx_info info;
x16_bmx_get_info(&info);
printf("%ux%u, %ubpp\n", info.width, info.height, info.bpp);
```

### `void x16_bmx_set_info(const x16_bmx_info *in)`

Describe the image before saving. `bpp` defaults to 8, `palcount` to
256, `stride` to 320.

### `unsigned char x16_bmx_save(const char *name, unsigned char len, unsigned char device, unsigned long vaddr)`

Write a BMX from VRAM. Describe the image first. Caveat: the palette
region is write-only, so the palette you save is only meaningful if
this program set those entries itself.

```c
x16_bmx_info shot = { 320, 240, 8, 0, 256, 0, 320 };
x16_bmx_set_info(&shot);
x16_bmx_save("SHOT.BMX", 8, X16_DEVICE_SD, X16_VRAM_BITMAP);
```

---

## `x16/zx0.h` — ZX0 decompression

ZX0 packs tighter than the ROM's LZSA2, at the cost of carrying the
decoder in your program. RAM to RAM **only**: the match copier reads
the output back, so unlike `x16_mem_decompress()` it cannot write
through VERA's data port, and cannot decompress in place.

Compress with `salvador` (or `zx0` in its default mode — this decodes
the modern v2 stream, not `-classic`):

```
salvador data.bin data.zx0
```

### `void *x16_zx0_decompress(const void *src, void *dst)`

Returns one past the last output byte.

```c
char out[4096];
unsigned int n = (char *)x16_zx0_decompress(packed, out) - out;
```

---

## `x16/fixed.h` — 8.8 fixed point

C has no fixed-point type and a 6502 has no multiplier; these are the
two operations a sprite-mover needs. An 8.8 value is a signed 16-bit
int holding 256 times the real number: `0x0180` is 1.5, `0xFF00` is
-1.0.

**Macros**: `X16_FIX(whole, frac_256)` builds a constant;
`X16_FIX_WHOLE(v)` takes the pixel part (an arithmetic shift, rounding
toward negative infinity).

### `unsigned long x16_umul16(unsigned int a, unsigned int b)`

Unsigned 16x16 → 32 multiply.

```c
unsigned long bytes = x16_umul16(width, height);
```

### `int x16_mul88(int a, int b)`

Signed 8.8 multiply: `(a * b) >> 8`, staying in 8.8.

```c
int speed = X16_FIX(1, 128);            /* 1.5 */
int scaled = x16_mul88(speed, X16_FIX(2, 0));   /* 3.0 == 0x0300 */
```

The canonical use — sub-pixel movement (see `examples/bounce.c`):

```c
int x = X16_FIX(160, 0), vx = X16_FIX(0, 96);   /* 0.375 px/frame */
for (;;) {
    x16_vsync_wait();
    x += vx;
    x16_sprite_pos(0, X16_FIX_WHOLE(x) * 2, 240);
}
```

---

## `x16/math.h` — game math

**Angles are bytes**: a full circle is 256, so 64 is 90° and
wrap-around is free. Angle 0 is east (+x) and 64 is south (+y — the
screen's y axis points down). `x16_atan2()` and the sine tables agree
on that, so a heading feeds straight back into movement.

### `void x16_rnd_seed(unsigned int seed)`

Seed the PRNG. A seed of 0 is nudged to 1 (xorshift's fixed point).
Seed from the frame counter for a different sequence each run.

```c
x16_rnd_seed(x16_irq_frames() | 0x100);
```

### `unsigned char x16_rnd8(void)`
### `unsigned int x16_rnd16(void)`

John Metcalf's 16-bit xorshift: period 65535, a handful of cycles —
cheap enough per object per frame.

```c
unsigned char dice = (x16_rnd8() % 6) + 1;
unsigned int anywhere = x16_rnd16() % 320;
```

### `signed char x16_sin8(unsigned char angle)`
### `signed char x16_cos8(unsigned char angle)`

Sine and cosine scaled to -127…127.

```c
x += (x16_cos8(heading) * speed) >> 7;
y += (x16_sin8(heading) * speed) >> 7;
```

### `unsigned char x16_sin8u(unsigned char angle)`
### `unsigned char x16_cos8u(unsigned char angle)`

The same wave biased by 128, giving 1…255 — handy for volumes and
scales that must not go negative.

```c
x16_psg_set_vol(0, x16_sin8u(t) >> 2, X16_PSG_PAN_BOTH);  /* tremolo */
```

### `unsigned char x16_atan2(signed char dx, signed char dy)`

The angle of a vector, 0–255. `atan2(0, 0)` answers 0 (east).

```c
unsigned char aim = x16_atan2(tx - x, ty - y);  /* face the target */
```

### `unsigned char x16_lerp8(unsigned char a, unsigned char b, unsigned char t)`

Linear interpolation: `t = 0` gives exactly `a`, `t = 255` exactly `b`,
the midpoint at most one off.

```c
unsigned char fade = x16_lerp8(0, 63, t);       /* volume ramp */
```

---

## `x16/collide.h` — bounding-box overlap

Axis-aligned box tests. Edges that merely touch do **not** overlap: a
box at x=0 of width 10 and one at x=10 are adjacent, not colliding.

### `unsigned char x16_collide8(unsigned char ax, unsigned char ay, unsigned char aw, unsigned char ah, unsigned char bx, unsigned char by, unsigned char bw, unsigned char bh)`

Two boxes of unsigned bytes: position and size of A, then of B. Returns
1 on overlap. The edge sums are 9-bit, so a box may run past x=255 —
but a *coordinate* cannot, so this cannot describe the right half of a
640-wide display; use `x16_collide16()` there.

```c
if (x16_collide8(px, py, 16, 16, ex, ey, 16, 16)) {
    player_hit();
}
```

### `unsigned char x16_collide16(const x16_box16 *a, const x16_box16 *b)`

The 16-bit version, for anything in display space (640x480 in the
default modes — sprite coordinates are in those units). `x16_box16` is
`{ unsigned int x, y, w, h; }` — field order is load-bearing, do not
reorder.

```c
x16_box16 player = { 600, 100, 32, 32 };
x16_box16 pickup = { 610, 110,  16, 16 };
if (x16_collide16(&player, &pickup)) collect();
```

---

## `x16/clip.h` — line clipping

Cohen-Sutherland clipping for the line routines, which assume on-screen
endpoints. Coordinates are **signed** and may lie anywhere within
±4095. The clip rectangle is inclusive and defaults to the full 320x240
bitmap. Linking this module does not drag the bitmap module in.

The segment type (field order is load-bearing):

```c
typedef struct { int x0; int y0; int x1; int y1; } x16_line;
```

### `void x16_clip_set(unsigned int xmin, unsigned int ymin, unsigned int xmax, unsigned int ymax)`

Change the rectangle; all four bounds inclusive.

```c
x16_clip_set(0, 0, 319, 199);           /* keep the HUD rows clean */
```

### `unsigned char x16_clip_line(x16_line *seg)`

Clip `*seg` against the rectangle. Returns 1 if any of it is visible —
with `*seg` replaced by the visible part — or 0 if it lies entirely
outside (in which case `*seg` is unspecified).

```c
x16_line seg = { -50, 120, 400, 130 };  /* both ends off screen */
if (x16_clip_line(&seg)) {
    x16_gfx_line(seg.x0, seg.y0, seg.x1, seg.y1, 1);
}
```

---

## `x16/buffers.h` — ring buffer and stack

One static byte FIFO and one static byte LIFO, 256 bytes of storage
each, capacity 255. `get` and `pop` return -1 when empty, like
`getchar()`. **Not safe across an interrupt boundary** — if one side
runs in an ISR, bracket the other side's call in a critical section.

### `void x16_rb_init(void)`

Empty the ring buffer.

### `unsigned char x16_rb_put(unsigned char b)`

Append a byte. Returns 1 if stored, 0 if the buffer was full (the byte
is dropped).

### `int x16_rb_get(void)`

The oldest byte, or -1 when empty.

### `unsigned char x16_rb_count(void)`

How many bytes are queued.

```c
x16_rb_init();
x16_rb_put('A');
x16_rb_put('B');
while (x16_rb_count()) {
    int c = x16_rb_get();               /* 'A' first: FIFO */
    x16_screen_chrout((unsigned char)c);
}
```

### `void x16_stk_init(void)`

Empty the stack.

### `unsigned char x16_stk_push(unsigned char b)`

Push a byte. Returns 1 if pushed, 0 if the stack was full (255 deep).

### `int x16_stk_pop(void)`

The top byte, or -1 when empty.

### `unsigned char x16_stk_depth(void)`

How many bytes are stacked.

```c
x16_stk_init();
x16_stk_push(1);                        /* remembered game states */
x16_stk_push(2);
if (x16_stk_depth()) {
    int last = x16_stk_pop();           /* 2 first: LIFO */
}
```

---

## `x16/float.h` — ROM floating point

A binding to the complete floating-point library in the X16's ROM —
several thousand bytes cc65's own float support would otherwise link
in. Everything operates on **FAC**, an implicit accumulator, so code
reads as a sequence of operations, not expressions.

**Cost**: every call crosses a ROM bank. For hot per-frame arithmetic
use `x16_mul88()` instead; floats are for setup-time math.

**Types**: `x16_float` is a 5-byte in-memory float
(`X16_FP_SIZE` = 5); `X16_FP_STRLEN` (16) is enough for anything the
ROM formats.

### `void x16_f_zero(void)` / `void x16_f_neg(void)` / `void x16_f_abs(void)` / `void x16_f_int(void)`

FAC = 0, -FAC, |FAC|, floor(FAC).

```c
x16_f_from_s16(-3);
x16_f_abs();                            /* FAC = 3 */
```

### `signed char x16_f_sgn(void)`

-1 if FAC < 0, 0 if zero, 1 if positive.

```c
if (x16_f_sgn() < 0) { /* negative */ }
```

### `void x16_f_from_u8(unsigned char v)` / `void x16_f_from_s16(int v)`

Load FAC from an integer.

### `int x16_f_to_s16(void)`

FAC as a 16-bit int, rounding toward zero.

```c
x16_f_from_s16(7);
x16_f_sqrt();
int r = x16_f_to_s16();                 /* 2: sqrt(7) truncated */
```

### `void x16_f_load(const x16_float m)` / `void x16_f_store(x16_float m)`

Move FAC to and from a 5-byte float in memory. This is how you keep
more than one value.

```c
x16_float pi_ish;
x16_f_from_str("3.14159", 7);
x16_f_store(pi_ish);
```

### `void x16_f_add(const x16_float m)` / `x16_f_sub` / `x16_f_mul` / `x16_f_div` / `x16_f_pow`

FAC op= m, in the intuitive direction (`x16_f_sub(b)` is FAC - b).

```c
x16_float a, b;
x16_f_from_s16(10);  x16_f_store(a);
x16_f_from_s16(4);   x16_f_store(b);
x16_f_load(a);
x16_f_div(b);                           /* FAC = 2.5 */
```

### `void x16_f_rsub(const x16_float m)` / `x16_f_rdiv` / `x16_f_rpow`

FAC = m op FAC — the ROM's own operand order, one bank crossing
instead of three. `x16_f_rdiv()` is the reciprocal idiom:

```c
x16_float one;
x16_f_from_u8(1);  x16_f_store(one);
x16_f_from_s16(8);
x16_f_rdiv(one);                        /* FAC = 1/8 = 0.125 */
```

### `signed char x16_f_cmp(const x16_float m)`

-1 if FAC < m, 0 if equal, 1 if FAC > m.

```c
if (x16_f_cmp(limit) > 0) { /* over the limit */ }
```

### `void x16_f_sqrt(void)` / `x16_f_ln` / `x16_f_exp` / `x16_f_sin` / `x16_f_cos` / `x16_f_tan` / `x16_f_atan`

Each replaces FAC with the function of itself. Angles are radians.
sin, cos, tan and atan destroy ARG (the ROM's second accumulator), so
don't interleave them with an in-flight `rsub`/`rdiv`.

```c
x16_f_from_str("0.5", 3);
x16_f_sin();                            /* FAC = sin(0.5) */
```

### `void x16_f_to_str(char *buf)` / `void x16_f_to_str_trim(char *buf)`

Format FAC into `buf` (at least `X16_FP_STRLEN` bytes). Unlike the raw
ROM call — which writes into the stack page — the result is copied out
and is yours to keep. `_trim` drops the leading space BASIC prints
before a positive number.

```c
char buf[X16_FP_STRLEN];
x16_f_to_str_trim(buf);
x16_screen_puts(buf);
```

### `void x16_f_from_str(const char *s, unsigned char len)`

Parse a decimal string — (pointer, length), not NUL-terminated.

```c
x16_f_from_str("-12.5E2", 7);           /* FAC = -1250 */
```

---

## Where to go next

- **`examples/`** — `hello.c`, `bounce.c` (sprites + fixed point) and
  `numbers.c` (the float library), all buildable with either toolchain.
- **The [README](../README.md)** — the "Things the hardware will get
  you wrong" section is worth reading before debugging anything
  strange.
- **Tests** — `test_ca65/runner.c` exercises every function in this
  guide and doubles as a second source of usage examples.
- For **music** (rather than sound effects), use
  [ZSMKit](https://github.com/mooinglemur/zsmkit) alongside this
  library.
