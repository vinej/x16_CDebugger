;ACME
; =====================================================================
; x16lib example :: bounce.asm
; =====================================================================
; A frame-locked sprite bouncing around the screen, driven by 8.8
; fixed-point velocity, with collision against a target box.
;
; Sound: a PSG blip on every wall bounce, with a per-frame volume decay
; envelope; an FM note on the YM2151 while the sprite overlaps the target
; box drawn near the middle of the screen, released when it leaves.
;
; Exercises: VSYNC frame lock, sprites, palette, 8.8 fixed point, AABB
; collision, PSG, YM2151 FM, tilemap text, and number formatting.
;
;   .\build.ps1 -Source examples\bounce.asm -Run
;
; Press any key to stop.
;
; Needs real VSYNC, so run it windowed. Under -testbench there is no
; video, no VSYNC interrupt, and vsync_wait never returns.
; =====================================================================

!cpu 65c02
!source "x16.asm"

X16_USE_VERA    = 1
X16_USE_SCREEN  = 1
X16_USE_SPRITE  = 1
X16_USE_PALETTE = 1
X16_USE_IRQ     = 1
X16_USE_FIXED   = 1
X16_USE_COLLIDE = 1
X16_USE_INPUT   = 1
X16_USE_NUMBER  = 1
X16_USE_PSG     = 1
X16_USE_YM      = 1
X16_USE_TILE    = 1

SPRITE_VRAM = $13000            ; the KERNAL's sprite image area
SPRITE_SIZE = 16                ; 16x16 pixels

; Sprite coordinates are DISPLAY coordinates, and in the default 80x60
; text mode the X16's display is 640x480 -- the KERNAL leaves HSCALE and
; VSCALE at 128. Only screen modes 2, 3 and $80 halve it to 320x240.
;
; So the play area is the full 640x480. That will not fit in the 8-bit
; integer part of a plain 8.8 word, which is why the position below is
; three bytes: an 8-bit fraction under a 16-bit pixel coordinate.
PLAY_W = 640
PLAY_H = 480

; The target box the sprite collides with, in display pixels. Deliberately
; past x=255, where a byte-sized collide8 could not reach it.
;
; Aligned to the 8x8 text grid so draw_box can outline it with tilemap
; cells -- otherwise the FM note fires with nothing on screen to explain
; why, which is exactly as confusing as it sounds.
BOX_X = 304                     ; column 38
BOX_Y = 200                     ; row 25
BOX_W = 80                      ; 10 cells
BOX_H = 80                      ; 10 cells

BOX_COL  = BOX_X / 8
BOX_ROW  = BOX_Y / 8
BOX_COLS = BOX_W / 8
BOX_ROWS = BOX_H / 8

BOX_CHAR = $A0                  ; screen code: reverse space, a solid cell
BOX_ATTR = $0E                  ; light blue on black

; --- audio -----------------------------------------------------------
; PSG voice 0 plays the bounce blip.
;   freq_word = Hz / (25000000/512 / 2^17) = Hz * 2.684
;   880 Hz (A5) -> 2362 = $093A
BLIP_VOICE  = 0
BLIP_FREQ   = 2362
BLIP_FRAMES = 15                ; envelope length; volume = frames * 4

; YM2151 channel 0 plays a note while the sprite is inside the box.
FM_CHANNEL = 0
FM_PATCH   = 1                  ; a ROM instrument patch
FM_NOTE    = $44                ; (octave 4 << 4) | note 4, packed as FMNOTE

* = $0801
    +basic_stub

; ---------------------------------------------------------------------
main
    jsr screen_cls
    jsr draw_box
    jsr sprite_init_all
    jsr build_sprite_image

    ; Make palette entry 2 a bright green so the sprite stands out.
    ldx #2
    lda #$F0                    ; green<<4 | blue
    ldy #$00                    ; red
    jsr pal_set

    ; Point sprite 0 at the image, 16x16, in front of everything.
    lda #<SPRITE_VRAM
    sta X16_P0
    lda #>SPRITE_VRAM
    sta X16_P1
    lda #^SPRITE_VRAM
    sta X16_P2
    ldx #0
    lda #SPRITE_MODE_8BPP
    jsr sprite_image

    ldx #0
    lda #SPRITE_SIZE_16         ; width
    ldy #SPRITE_SIZE_16         ; height
    stz X16_P0                  ; palette offset
    jsr sprite_size

    ldx #0
    lda #SPRITE_Z_FRONT
    jsr sprite_flags

    jsr sprites_on
    jsr init_audio
    jsr irq_install

; ---------------------------------------------------------------------
loop
    jsr vsync_wait              ; frame-locked: exactly 60 Hz

    jsr move_sprite
    jsr draw_sprite
    jsr check_collision
    jsr update_blip             ; advance the PSG envelope, once a frame

    jsr key_get                 ; non-blocking
    beq loop

; ---------------------------------------------------------------------
done
    jsr irq_remove
    jsr silence_audio
    jsr sprites_off
    jsr screen_cls
    rts

; =====================================================================
; Audio
; =====================================================================

; ---------------------------------------------------------------------
; init_audio -- silence the PSG, reset the FM chip, pick an instrument.
;
; ym_init resets the YM2151 and loads the default patch set; without it
; ym_patch has nothing to select from.
; ---------------------------------------------------------------------
init_audio
    jsr psg_init                ; all 16 PSG voices to zero volume

    jsr ym_init
    bcs @no_fm                  ; no YM present: run silently

    sec                         ; carry set: X is a ROM patch index
    lda #FM_CHANNEL
    ldx #FM_PATCH
    jsr ym_patch

    lda #FM_CHANNEL             ; channel in A, payload in X -- always
    ldx #0                      ; attenuation 0 = the patch's own volume
    jsr ym_vol

    lda #FM_CHANNEL
    ldx #3                      ; pan: both speakers
    jsr ym_pan
@no_fm
    rts

silence_audio
    jsr psg_init
    lda #FM_CHANNEL
    jmp ym_release_note

; ---------------------------------------------------------------------
; start_blip -- retrigger the bounce sound.
;
; Sets the pitch and waveform, then hands the envelope to update_blip.
; Called from the bounce path, which runs inside the frame loop, so it
; must stay short.
; ---------------------------------------------------------------------
start_blip
    lda #<BLIP_FREQ
    sta X16_P0
    lda #>BLIP_FREQ
    sta X16_P1
    ldx #BLIP_VOICE
    jsr psg_set_freq

    ldx #BLIP_VOICE
    lda #PSG_WAVE_PULSE
    ldy #32                     ; 50% duty -- a square wave
    jsr psg_set_wave

    lda #BLIP_FRAMES
    sta blip_timer
    rts

; ---------------------------------------------------------------------
; update_blip -- one step of the volume envelope, once per frame.
;
; PSG volume is 0-63, so scaling the remaining frames by 4 gives a
; linear decay from 60 down to silence over a quarter of a second.
; ---------------------------------------------------------------------
update_blip
    lda blip_timer
    beq @silent

    dec blip_timer
    lda blip_timer
    asl
    asl                         ; frames * 4, at most 60
    ldx #BLIP_VOICE
    ldy #PSG_PAN_BOTH
    jmp psg_set_vol
@silent
    lda #0
    ldx #BLIP_VOICE
    ldy #PSG_PAN_BOTH
    jmp psg_set_vol

; ---------------------------------------------------------------------
; Advance the position by the velocity, bouncing at the edges.
;
; Position is 24-bit: pos_x+0 is the fraction, pos_x+1/+2 the 16-bit
; pixel coordinate. Velocity is a signed 8.8 word, so adding it to the
; high half means sign-extending its integer byte -- $FF when negative,
; $00 when positive -- and letting the carry ripple up.
; ---------------------------------------------------------------------
move_sprite
    clc                         ; x += vx, 24-bit
    lda pos_x
    adc vel_x
    sta pos_x
    lda pos_x+1
    adc vel_x+1
    sta pos_x+1
    lda vel_x+1                 ; sign-extend the velocity's integer byte
    bmi @vx_neg
    lda #$00
    bra @vx_hi
@vx_neg
    lda #$FF
@vx_hi
    adc pos_x+2
    sta pos_x+2

    ; Clamp to the edge as well as reversing. Reversing alone leaves the
    ; sprite a fraction of a pixel outside the wall for one frame, and on
    ; the left that is a NEGATIVE coordinate: it wraps to $FFFF, and
    ; sprite_pos masks it to 10 bits, so the sprite flicks across to the
    ; far side of the screen before coming back.
    lda pos_x+2
    bmi @clamp_x_lo             ; high byte bit 7 set: gone negative
    lda pos_x+1                 ; pixel >= PLAY_W - SPRITE_SIZE ?
    cmp #<(PLAY_W - SPRITE_SIZE)
    lda pos_x+2
    sbc #>(PLAY_W - SPRITE_SIZE)
    bcc @y                      ; still inside
    lda #<(PLAY_W - SPRITE_SIZE - 1)
    sta pos_x+1
    lda #>(PLAY_W - SPRITE_SIZE - 1)
    sta pos_x+2
    stz pos_x
    jsr negate_vx
    bra @y
@clamp_x_lo
    stz pos_x
    stz pos_x+1
    stz pos_x+2
    jsr negate_vx

@y
    clc                         ; y += vy, 24-bit
    lda pos_y
    adc vel_y
    sta pos_y
    lda pos_y+1
    adc vel_y+1
    sta pos_y+1
    lda vel_y+1
    bmi @vy_neg
    lda #$00
    bra @vy_hi
@vy_neg
    lda #$FF
@vy_hi
    adc pos_y+2
    sta pos_y+2

    lda pos_y+2
    bmi @clamp_y_lo
    lda pos_y+1
    cmp #<(PLAY_H - SPRITE_SIZE)
    lda pos_y+2
    sbc #>(PLAY_H - SPRITE_SIZE)
    bcc @done                   ; still inside
    lda #<(PLAY_H - SPRITE_SIZE - 1)
    sta pos_y+1
    lda #>(PLAY_H - SPRITE_SIZE - 1)
    sta pos_y+2
    stz pos_y
    jsr negate_vy
    bra @done
@clamp_y_lo
    stz pos_y
    stz pos_y+1
    stz pos_y+2
    jsr negate_vy
@done
    rts

negate_vx
    sec
    lda #0
    sbc vel_x
    sta vel_x
    lda #0
    sbc vel_x+1
    sta vel_x+1
    jmp start_blip              ; every wall hit retriggers the blip

negate_vy
    sec
    lda #0
    sbc vel_y
    sta vel_y
    lda #0
    sbc vel_y+1
    sta vel_y+1
    jmp start_blip

; ---------------------------------------------------------------------
draw_sprite
    lda pos_x+1                 ; the 16-bit pixel part, above the fraction
    sta X16_P0
    lda pos_x+2
    sta X16_P1
    lda pos_y+1
    sta X16_P2
    lda pos_y+2
    sta X16_P3
    ldx #0
    jmp sprite_pos

; ---------------------------------------------------------------------
; Software AABB against the target box. Print HIT or --- at the top
; left, plus the frame counter, so the frame lock is visible.
; ---------------------------------------------------------------------
check_collision
    ; collide16, not collide8: the box sits at x=300, which does not fit
    ; in a byte. The sprite's own x runs to 624.
    lda pos_x+1
    sta cl_ax
    lda pos_x+2
    sta cl_ax+1
    lda pos_y+1
    sta cl_ay
    lda pos_y+2
    sta cl_ay+1
    lda #SPRITE_SIZE
    sta cl_aw
    stz cl_aw+1
    lda #SPRITE_SIZE
    sta cl_ah
    stz cl_ah+1

    lda #<BOX_X
    sta cl_bx
    lda #>BOX_X
    sta cl_bx+1
    lda #<BOX_Y
    sta cl_by
    lda #>BOX_Y
    sta cl_by+1
    lda #<BOX_W
    sta cl_bw
    lda #>BOX_W
    sta cl_bw+1
    lda #<BOX_H
    sta cl_bh
    lda #>BOX_H
    sta cl_bh+1
    jsr collide16

    ; Capture the result NOW. screen_locate does clc before jumping into
    ; PLOT, so the carry collide16 returned would be gone by the time we
    ; branched on it.
    lda #0
    rol                         ; A = 1 when the boxes overlap
    sta hit

    jsr update_fm_note

    ldx #0                      ; home the cursor without clearing
    ldy #0
    jsr screen_locate

    lda hit
    beq @miss
    lda #<msg_hit
    ldx #>msg_hit
    bra @print
@miss
    lda #<msg_miss
    ldx #>msg_miss
@print
    jsr screen_puts

    jsr irq_frames              ; and the live frame counter
    sta X16_P0
    stz X16_P1
    jsr u16_to_dec
    jsr screen_puts
    lda #' '                    ; scrub any digit left by a longer number
    jsr screen_chrout
    lda #' '
    jmp screen_chrout

; ---------------------------------------------------------------------
; update_fm_note -- play on the EDGE, not on the level.
;
; `hit` is true for every frame the sprite overlaps the box. Calling
; ym_note_bas each of those frames would retrigger the envelope 60 times
; a second, which sounds like a buzz rather than a note. Compare against
; the previous frame and act only when the state changes.
; ---------------------------------------------------------------------
update_fm_note
    lda hit
    cmp hit_prev
    beq @done                   ; no change: leave the note alone
    sta hit_prev

    ; sta does not touch the flags, and the cmp above already told us
    ; "not equal". Reload to get a Z flag that reflects the new state.
    lda hit_prev
    beq @release                ; just left the box

    clc                         ; carry clear: retrigger the envelope
    lda #FM_CHANNEL             ; channel in A ...
    ldx #FM_NOTE                ; ... packed note in X
    jmp ym_note_bas
@release
    lda #FM_CHANNEL
    jmp ym_release_note
@done
    rts

; ---------------------------------------------------------------------
; draw_box -- outline the collision target in tilemap cells, so you can
; see what the FM note is reacting to.
;
; The box is defined in display pixels; a text cell is 8x8 of them, which
; is why BOX_X and BOX_Y are multiples of 8.
;
; tile_put clobbers X and Y (tile_setptr reuses X as a shift counter), so
; the loop counters live in memory rather than in registers.
; ---------------------------------------------------------------------
draw_box
    lda #BOX_CHAR
    sta X16_P0
    lda #BOX_ATTR
    sta X16_P1

    lda #BOX_COL                ; top and bottom edges
    sta box_i
@horiz
    ldx box_i
    ldy #BOX_ROW
    jsr tile_put
    ldx box_i
    ldy #(BOX_ROW + BOX_ROWS - 1)
    jsr tile_put
    inc box_i
    lda box_i
    cmp #(BOX_COL + BOX_COLS)
    bne @horiz

    lda #BOX_ROW                ; left and right edges
    sta box_i
@vert
    ldx #BOX_COL
    ldy box_i
    jsr tile_put
    ldx #(BOX_COL + BOX_COLS - 1)
    ldy box_i
    jsr tile_put
    inc box_i
    lda box_i
    cmp #(BOX_ROW + BOX_ROWS)
    bne @vert
    rts

; ---------------------------------------------------------------------
; Paint a filled 16x16 block of colour 2 into the sprite image area.
; ---------------------------------------------------------------------
build_sprite_image
    +vera_addr 0, SPRITE_VRAM, VERA_INC_1
    lda #2                      ; palette index
    ldx #<(SPRITE_SIZE * SPRITE_SIZE)
    ldy #>(SPRITE_SIZE * SPRITE_SIZE)
    jmp vera_fill

; ---------------------------------------------------------------------
; Position: fraction, then a 16-bit pixel coordinate (little-endian).
; Velocity: a signed 8.8 word -- $0180 is 1.5 px/frame, $00C0 is 0.75.
; ---------------------------------------------------------------------
pos_x !byte $00
      !word 64                  ; 64.0 pixels
pos_y !byte $00
      !word 48                  ; 48.0 pixels
vel_x !word $0180
vel_y !word $00C0

hit        !byte 0              ; overlapping the box this frame?
hit_prev   !byte 0              ; ...and last frame, for edge detection
blip_timer !byte 0              ; frames left in the PSG envelope
box_i      !byte 0              ; draw_box loop counter

msg_hit  !text "HIT  FRAME ", $00
msg_miss !text "---  FRAME ", $00

; ---------------------------------------------------------------------
!source "x16_code.asm"
