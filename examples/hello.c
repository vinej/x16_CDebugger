/* =====================================================================
 * x16clib example :: hello.c
 * =====================================================================
 * The smallest program that proves the whole toolchain works: compile
 * with cc65, autorun from BASIC, print through the KERNAL, and touch
 * VRAM through the library.
 *
 *   .\build.ps1 -Source examples\hello.c -Run
 * =====================================================================
 */

#include <x16/vera.h>
#include <x16/screen.h>

int main(void)
{
    x16_screen_cls();
    x16_screen_puts("HELLO FROM X16CLIB\r");

    /* Star the top text row, straight in VRAM.
    **
    ** A text cell is two bytes: screen code, then colour. Stepping the
    ** data port by 2 writes only the screen codes and leaves the colours
    ** alone -- no read-modify-write, no second loop.
    */
    x16_vera_addr0(X16_INC_2, X16_VRAM_TEXT);
    x16_vera_fill(0x2A, 80);            /* screen code for '*', 80 columns */

    x16_screen_puts(x16_vera_has_fx() ? "VERA FX: YES\r" : "VERA FX: NO\r");

    return 0;
}
