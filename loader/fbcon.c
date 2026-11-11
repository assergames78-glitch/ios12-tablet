/*
 * Tablet "console": no font yet, so every printed line advances a thin green
 * progress strip down the left edge of the screen. Enough to see how far the
 * loader got before handing over to xnu. A real text console comes later.
 */
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
#endif
