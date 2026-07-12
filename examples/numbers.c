/* =====================================================================
 * x16clib example :: numbers.c
 * =====================================================================
 * A tour of the arithmetic the library adds to C, and of the arithmetic
 * it deliberately does not.
 *
 * C already has int, long, and printf. So this library ports none of the
 * assembly library's int16, int32, number or bits modules -- cc65 does
 * those better. What it adds is what C lacks on a 6502:
 *
 *   8.8 fixed point      for per-frame motion, in <x16/fixed.h>
 *   the VERA multiplier  signed 16x16 -> 32 in hardware
 *   the ROM's floats     several thousand bytes cc65 would otherwise link
 *
 *   .\build.ps1 -Source examples\numbers.c -Run
 *
 * Runs headless too: it never waits for VSYNC. printf here rather than
 * conio's cprintf, because printf goes out through the KERNAL's CHROUT
 * and so shows up under x16emu's -echo, while conio writes screen codes
 * straight into VRAM. printf also turns '\n' into the CR the X16 wants.
 * =====================================================================
 */

#include <stdio.h>
#include <x16/x16.h>

/* Print an 8.8 fixed-point value as a decimal. The fraction is the low
** byte over 256, and three digits is exact for every value it can hold.
**
** Scale by 125/32 rather than 1000/256 -- the same ratio, but 255*1000
** overflows a 16-bit int and 255*125 does not. On a 6502 that matters:
** cc65's int is 16 bits, and it wraps silently.
*/
static void put_fixed(const char *label, int v)
{
    unsigned int frac;
    const char *sign = "";

    if (v < 0) {
        sign = "-";
        v = -v;
    }
    frac = (unsigned int)(v & 0xFF) * 125u / 32u;
    printf("%s = %s%d.%03u\n", label, sign, v >> 8, frac);
}

static void heading(const char *s)
{
    printf("\n%s\n", s);
}

int main(void)
{
    x16_float a, b;
    char buf[X16_FP_STRLEN];

    x16_screen_cls();

    /* --- what C gives you already --------------------------------- */
    heading("NATIVE C");
    printf("  30000 + 5000 = %ld\n", 30000L + 5000L);
    printf("  7 * 11 * 13  = %u\n", 7u * 11u * 13u);
    printf("  1000000 / 7  = %ld\n", 1000000L / 7L);

    /* --- 8.8 fixed point ------------------------------------------ */
    heading("FIXED 8.8");
    put_fixed("  1.5 * 2.0 ", x16_mul88(X16_FIX(1, 128), X16_FIX(2, 0)));
    put_fixed(" -1.5 * 2.0 ", x16_mul88(-X16_FIX(1, 128), X16_FIX(2, 0)));
    put_fixed("  0.75 * 0.5", x16_mul88(X16_FIX(0, 192), X16_FIX(0, 128)));
    printf("  1000 * 1000 = %lu\n", x16_umul16(1000, 1000));

    /* --- the VERA hardware multiplier ------------------------------ */
    heading("VERA FX");
    if (x16_vera_has_fx()) {
        printf("  1000 * 1000 = %ld\n", x16_fx_mult(1000, 1000));
        printf(" -1000 * 1000 = %ld\n", x16_fx_mult(-1000, 1000));
    } else {
        printf("  not present on this VERA\n");
    }

    /* --- the ROM's floating point library --------------------------
    ** An implicit accumulator, so this reads as a sequence of operations
    ** rather than as an expression. Note f_div is FAC / mem, the
    ** intuitive direction; f_rdiv is the ROM's own mem / FAC.
    */
    heading("ROM FLOAT");

    x16_f_from_s16(10);
    x16_f_store(a);
    x16_f_from_s16(4);
    x16_f_store(b);

    x16_f_load(a);
    x16_f_div(b);                       /* 10 / 4 */
    x16_f_to_str_trim(buf);
    printf("  10 / 4      = %s\n", buf);

    x16_f_load(a);
    x16_f_rdiv(b);                      /* 4 / 10 -- the reciprocal form */
    x16_f_to_str_trim(buf);
    printf("  4 / 10      = %s\n", buf);

    x16_f_from_s16(2);
    x16_f_store(b);
    x16_f_from_s16(10);
    x16_f_pow(b);                       /* 10 ^ 2 */
    x16_f_to_str_trim(buf);
    printf("  10 ^ 2      = %s\n", buf);

    x16_f_from_s16(2);
    x16_f_sqrt();
    x16_f_to_str_trim(buf);
    printf("  sqrt(2)     = %s\n", buf);

    x16_f_from_s16(1);
    x16_f_exp();
    x16_f_to_str_trim(buf);
    printf("  e           = %s\n", buf);

    /* 4 * atan(1) is pi. */
    x16_f_from_s16(1);
    x16_f_atan();
    x16_f_store(a);
    x16_f_from_s16(4);
    x16_f_mul(a);
    x16_f_to_str_trim(buf);
    printf("  4 * atan(1) = %s\n", buf);

    printf("\n");
    return 0;
}
