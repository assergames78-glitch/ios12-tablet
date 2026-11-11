/*
 * Tablet screen output for the loader.
 *
 * fbcon_putc: no font yet, so every printed line advances a thin green
 *   progress strip down the left edge (shows how far the loader got).
 * board_draw_logo: clears all of video memory to black and draws the boot
 *   logo centred in every frame, like iBoot does before starting iOS.
 */
#include <stddef.h>
#include "board.h"

#if defined(BOARD_TABLET)
static int line;

void fbcon_putc(char c)
{
	if (c != '\n')
		return;
	int y0 = 40 + line * 6;
	if (y0 + 4 >= FB_H)
		return;
	for (int y = y0; y < y0 + 4; y++)
		for (int x = 0; x < 120; x++)
			mmio_w32(FB_BASE + (uint64_t)y * FB_STRIDE + (uint64_t)x * 4, 0xff00ff00);
	line++;
}

#define FB_FRAME (FB_STRIDE * FB_H)
#define FB_VRAM  0x00db0000ULL      /* from /chosen/atag,videolfb */

void board_draw_logo(const uint8_t *logo, size_t len)
{
	/* black, opaque, everywhere */
	for (uint64_t a = FB_BASE; a < FB_BASE + FB_VRAM; a += 4)
		mmio_w32(a, 0xff000000);

	if (len < 8)
		return;
	const uint32_t *hdr = (const uint32_t *)logo;
	uint32_t w = hdr[0], h = hdr[1];
	if (w == 0 || h == 0 || w > FB_W || h > FB_H || len < 8 + (size_t)w * h * 4)
		return;
	const uint32_t *px = hdr + 2;
	uint32_t x0 = (FB_W - w) / 2, y0 = (FB_H - h) / 2;

	for (uint64_t frame = 0; (frame + 1) * FB_FRAME <= FB_VRAM; frame++) {
		uint64_t base = FB_BASE + frame * FB_FRAME;
		for (uint32_t y = 0; y < h; y++)
			for (uint32_t x = 0; x < w; x++)
				mmio_w32(base + (uint64_t)(y0 + y) * FB_STRIDE + (uint64_t)(x0 + x) * 4,
				    px[y * w + x]);
	}
}
#else
void board_draw_logo(const uint8_t *logo, size_t len) { (void)logo; (void)len; }
#endif
