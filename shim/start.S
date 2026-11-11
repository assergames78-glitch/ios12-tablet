/*
 * ios12-tablet boot shim, stage 0: colour bars.
 *
 * Loaded by the tablet's MediaTek LK bootloader exactly like a 64-bit Linux
 * kernel (Image.gz + appended DTB inside an Android boot.img). On entry:
 *   x0 = physical address of the device tree, MMU off.
 *
 * It paints the bootloader's framebuffer (from /chosen/atag,videolfb):
 *   base 0x9f210000, 800x1280, 32 bpp, stride 3200 bytes.
 * Top third    = 0x00ff0000, middle = 0x0000ff00, bottom = 0x000000ff,
 * so the colours on screen reveal the panel's pixel order.
 * A white 16-pixel border proves the stride and size are right.
 */

#define FB_BASE   0x9f210000
#define FB_VRAM   0x00db0000	/* whole video memory: 3 frames + extra */
#define FB_W      800
#define FB_H      1280
#define FB_STRIDE (FB_W * 4)

/* MT6735 TOPRGU watchdog (DT: mediatek,mt6735-rgu @ 0x10212000).
 * WDT_MODE needs key 0x22 in bits 31:24; enable bit 0 clear = disabled. */
#define WDT_MODE  0x10212000
#define WDT_OFF   0x22000000

	.text			/* one section: header must be the first bytes */
	.globl _head
_head:
	/* arm64 Linux Image header (Documentation/arm64/booting.rst) */
	b	start			/* code0 */
	.long	0			/* code1 */
	.quad	0x80000			/* text_offset: load at base + 0x80000 */
	.quad	_end - _head		/* image_size */
	.quad	0x2			/* flags: little endian, 4K pages */
	.quad	0, 0, 0			/* reserved */
	.ascii	"ARM\x64"		/* magic */
	.long	0			/* reserved (PE header offset) */

start:
	mov	x20, x0			/* keep DTB pointer for later stages */

	/* stop the hardware watchdog, or it resets us within seconds */
	ldr	x1, =WDT_MODE
	ldr	w2, =WDT_OFF
	str	w2, [x1]
	dsb	sy

	/* paint every frame in video memory: we don't know which one is shown */
	ldr	x1, =FB_BASE		/* x1 = row pointer */
	ldr	x9, =(FB_BASE + FB_VRAM - FB_STRIDE)	/* last row that fits */
frame:
	mov	x2, #0			/* x2 = y within this frame */
row:
	cmp	x1, x9
	b.gt	done
	/* pick this row's colour by third of the screen */
	/* top byte = alpha: MediaTek's overlay treats 0x00 as fully transparent */
	ldr	w3, =0xffff0000
	cmp	x2, #(FB_H / 3)
	b.lt	1f
	ldr	w3, =0xff00ff00
	cmp	x2, #(2 * FB_H / 3)
	b.lt	1f
	ldr	w3, =0xff0000ff
1:
	/* white border: first/last 16 rows */
	cmp	x2, #16
	b.lt	white_row
	ldr	x4, =(FB_H - 16)
	cmp	x2, x4
	b.ge	white_row
	b	paint
white_row:
	ldr	w3, =0xffffffff
paint:
	mov	x5, #0			/* x5 = x */
	mov	x6, x1
col:
	mov	w7, w3
	cmp	x5, #16			/* white left/right border */
	b.lt	2f
	cmp	x5, #(FB_W - 16)
	b.lt	3f
2:	ldr	w7, =0xffffffff
3:	str	w7, [x6], #4
	add	x5, x5, #1
	cmp	x5, #FB_W
	b.lt	col

	add	x1, x1, #FB_STRIDE
	add	x2, x2, #1
	cmp	x2, #FB_H
	b.lt	row
	b	frame

done:
	dsb	sy
hang:
	wfe
	b	hang

	.ltorg
	.balign	16
	.globl _end
_end:
