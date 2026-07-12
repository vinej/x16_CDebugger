/* =====================================================================
 * x16clib example :: bounce.c
 * =====================================================================
 * A frame-locked sprite bouncing around the screen on 8.8 fixed-point
 * velocity, colliding with a target box.
 *
 * Sound: a PSG blip on every wall bounce, with a per-frame volume decay
 * envelope; an FM note on the YM2151 while the sprite overlaps the box
 * drawn near the middle of the screen, released when it leaves.
 *
 * Exercises: VSYNC frame lock, sprites, palette, 8.8 fixed point, 16-bit
 * AABB collision, PSG, YM2151 FM, and tilemap text.
 *
 *   .\build.ps1 -Source examples\bounce.c -Run
 *
 * Press any key to stop.
 *
 * Needs real VSYNC, so run it windowed. Under -testbench there is no
 * video, no VSYNC interrupt, and x16_vsync_wait() never returns.
 * =====================================================================
 */

#include <x16/x16.h>

#define SPRITE_VRAM     0x13000UL       /* the KERNAL's sprite image area */
#define SPRITE_PIXELS   16              /* 16x16 */

/* Sprite coordinates are DISPLAY coordinates, and in the default 80x60
** text mode the X16's display is 640x480 -- the KERNAL leaves HSCALE and
** VSCALE at 128. Only screen modes 2, 3 and 0x80 halve it to 320x240.
*/
#define PLAY_W          640
#define PLAY_H          480

/* The target box, in display pixels. Deliberately past x=255, where a
** byte-sized x16_collide8() could not reach it.
**
** Aligned to the 8x8 text grid so draw_box can outline it with tilemap
** cells -- otherwise the FM note fires with nothing on screen to explain
** why, which is exactly as confusing as it sounds.
*/
#define BOX_X           304
#define BOX_Y           200
#define BOX_W           80
#define BOX_H           80

#define BOX_CHAR        0xA0            /* reverse space: a solid cell */
#define BOX_ATTR        0x0E            /* light blue on black */

/* PSG voice 0 plays the bounce blip. 880 Hz (A5) is 2362 steps. */
#define BLIP_VOICE      0
#define BLIP_FRAMES     15              /* envelope length; volume = frames*4 */

/* YM2151 channel 0 plays a note while the sprite is inside the box. */
#define FM_CHANNEL      0
#define FM_PATCH        1               /* a ROM instrument patch */

/* Position in 8.8, held as a pixel word plus a fraction byte. The full
** 8.8 value needs 17 bits (the play area is 640 wide), and a `long`
** would carry it -- but KickC 0.8.6 has no code fragments for runtime
** 32-bit shifts, so the fields are kept apart and every operation stays
** on int-sized types, which all three toolchains compile. The pixel is
** simply the word; no shift needed at the point of use.
*/
static int pos_x = 64;                  /* pixel part */
static int pos_y = 48;
static unsigned char frac_x = 0;        /* fraction part */
static unsigned char frac_y = 0;
static int vel_x = X16_FIX(1, 128);     /* 1.5 pixels per frame */
static int vel_y = X16_FIX(0, 192);     /* 0.75 */

static unsigned char blip_timer;
static unsigned char hit, hit_prev;
static unsigned char have_fm;

/* ------------------------------------------------------------------ */

static void init_audio(void)
{
    x16_psg_init();                     /* all 16 voices to zero volume */

    /* x16_ym_init resets the chip and loads the default patch set;
    ** without it x16_ym_patch_rom has nothing to select from.
    */
    have_fm = x16_ym_init();
    if (have_fm) {
        x16_ym_patch_rom(FM_CHANNEL, FM_PATCH);
        x16_ym_vol(FM_CHANNEL, 0);      /* 0 = the patch's own volume */
        x16_ym_pan(FM_CHANNEL, X16_YM_PAN_BOTH);
    }
}

/* Retrigger the bounce sound: set pitch and waveform, then hand the
** envelope to update_blip.
*/
static void start_blip(void)
{
    x16_psg_set_freq(BLIP_VOICE, X16_PSG_HZ(880));
    x16_psg_set_wave(BLIP_VOICE, X16_PSG_WAVE_PULSE, 32);  /* 50%: a square */
    blip_timer = BLIP_FRAMES;
}

/* One step of the volume envelope, once per frame. PSG volume is 0-63,
** so scaling the remaining frames by 4 decays from 60 to silence over a
** quarter of a second.
*/
static void update_blip(void)
{
    unsigned char vol = 0;

    if (blip_timer) {
        --blip_timer;
        vol = blip_timer << 2;          /* at most 60 */
    }
    x16_psg_set_vol(BLIP_VOICE, vol, X16_PSG_PAN_BOTH);
}

/* Play on the EDGE, not on the level.
**
** `hit` is true for every frame the sprite overlaps the box. Retriggering
** the note on each of those frames would restart the envelope 60 times a
** second, which sounds like a buzz rather than a note.
*/
static void update_fm_note(void)
{
    if (!have_fm || hit == hit_prev) {
        return;
    }
    hit_prev = hit;

    if (hit) {
        x16_ym_note_bas(FM_CHANNEL, X16_YM_NOTE(4, 4), X16_YM_RETRIGGER);
    } else {
        x16_ym_release_note(FM_CHANNEL);
    }
}

/* ------------------------------------------------------------------ */

/* Advance one axis, bouncing at the edges.
**
** Clamp as well as reverse. Reversing alone leaves the sprite a fraction
** of a pixel outside the wall for one frame, and on the near edge that is
** a NEGATIVE coordinate: x16_sprite_pos masks it to 10 bits, so the
** sprite flicks across to the far side of the screen before coming back.
*/
static unsigned char step_axis(int *pos, unsigned char *frac, int *vel,
                               int limit)
{
    /* Add the 8.8 velocity: its fraction byte to the fraction (the
    ** sum's high byte is the carry), its pixel half arithmetic-shifted
    ** onto the pixel word.
    */
    int v = *vel;
    int p = *pos;
    unsigned int f = (unsigned int)*frac + (unsigned char)v;
    unsigned char bounced = 0;

    p = p + (v >> 8) + (int)(f >> 8);

    *frac = (unsigned char)f;
    if (p < 0) {
        p = 0;
        *frac = 0;
        bounced = 1;
    } else if (p >= limit) {
        p = limit - 1;
        *frac = 0;
        bounced = 1;
    }
    if (bounced) {
        *vel = 0 - v;
    }
    *pos = p;
    return bounced;
}

static void move_sprite(void)
{
    unsigned char bounced;

    bounced = step_axis(&pos_x, &frac_x, &vel_x, PLAY_W - SPRITE_PIXELS);
    bounced |= step_axis(&pos_y, &frac_y, &vel_y, PLAY_H - SPRITE_PIXELS);

    if (bounced) {
        start_blip();
    }
}

/* x16_collide16, not x16_collide8: the box sits at x=304, which does not
** fit in a byte, and the sprite's own x runs to 624.
*/
static void check_collision(void)
{
    static x16_box16 sprite = { 0, 0, SPRITE_PIXELS, SPRITE_PIXELS };
    static const x16_box16 box = { BOX_X, BOX_Y, BOX_W, BOX_H };

    sprite.x = (unsigned int)pos_x;
    sprite.y = (unsigned int)pos_y;

    hit = x16_collide16(&sprite, &box);
    update_fm_note();
}

/* Outline the collision target in tilemap cells, so you can see what the
** FM note is reacting to. A text cell is 8x8 display pixels, which is why
** BOX_X and BOX_Y are multiples of 8.
*/
static void draw_box(void)
{
    unsigned char col = BOX_X / 8, row = BOX_Y / 8;
    unsigned char cols = BOX_W / 8, rows = BOX_H / 8;
    unsigned char i;

    for (i = 0; i < cols; ++i) {
        x16_tile_put(col + i, row, BOX_CHAR, BOX_ATTR);
        x16_tile_put(col + i, row + rows - 1, BOX_CHAR, BOX_ATTR);
    }
    for (i = 0; i < rows; ++i) {
        x16_tile_put(col, row + i, BOX_CHAR, BOX_ATTR);
        x16_tile_put(col + cols - 1, row + i, BOX_CHAR, BOX_ATTR);
    }
}

/* Paint a filled 16x16 block of palette index 2 into the sprite image. */
static void build_sprite_image(void)
{
    x16_vera_addr0(X16_INC_1, SPRITE_VRAM);
    x16_vera_fill(2, SPRITE_PIXELS * SPRITE_PIXELS);
}

/* ------------------------------------------------------------------ */

/* Three decimal digits, always. printf would cost more zero page than
** this whole program has to spare on llvm-mos. Subtraction rather than
** division, because KickC has no runtime divide at all -- and for one
** byte twice a second, repeated subtraction is no slower anyway.
*/
static void put_u8(unsigned char v)
{
    unsigned char h = 0;
    unsigned char t = 0;

    while (v >= 100) { v -= 100; h++; }
    while (v >= 10)  { v -= 10;  t++; }
    x16_screen_chrout('0' + h);
    x16_screen_chrout('0' + t);
    x16_screen_chrout('0' + v);
    x16_screen_chrout(' ');
}

int main(void)
{
    x16_screen_cls();
    draw_box();
    x16_sprite_init_all();
    build_sprite_image();

    x16_pal_set(2, 0x00F0);             /* entry 2: bright green */

    x16_sprite_image(0, X16_SPRITE_8BPP, SPRITE_VRAM);
    x16_sprite_size(0, X16_SPRITE_SIZE_16, X16_SPRITE_SIZE_16, 0);
    x16_sprite_flags(0, X16_SPRITE_Z_FRONT);
    x16_sprites_on();

    init_audio();
    x16_irq_install();

    do {
        x16_vsync_wait();               /* frame-locked: exactly 60 Hz */

        move_sprite();
        x16_sprite_pos(0, (unsigned int)pos_x, (unsigned int)pos_y);
        check_collision();
        update_blip();

        /* x16_screen_locate/puts go through the KERNAL, which needs
        ** ADDRSEL = 0 -- and they clear it for us. See <x16/screen.h>.
        ** Formatted by hand rather than with printf: printf wants the
        ** whole of llvm-mos's ninety-byte zero page, and this program
        ** already spends sixteen of it on the library's scratch block.
        */
        x16_screen_locate(0, 0);
        x16_screen_puts(hit ? "HIT  FRAME " : "---  FRAME ");
        put_u8(x16_irq_frames());
    } while (x16_key_get() == 0);

    x16_irq_remove();
    x16_psg_init();
    if (have_fm) {
        x16_ym_release_note(FM_CHANNEL);
    }
    x16_sprites_off();
    x16_screen_cls();
    return 0;
}
