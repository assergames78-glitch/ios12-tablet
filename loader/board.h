/* Per-board settings for the loader. Pick one with -DBOARD_QEMU_PI3 or -DBOARD_TABLET. */
#pragma once
#include <stdint.h>

static inline void mmio_w32(uint64_t a, uint32_t v) { *(volatile uint32_t *)a = v; }
static inline uint32_t mmio_r32(uint64_t a) { return *(volatile uint32_t *)a; }

#if defined(BOARD_QEMU_PI3)
/* QEMU -M raspi3b: 1 GB RAM at 0 (top 64 MB is GPU memory), peripherals at 0x3F000000. */
#define BOARD_NAME      "qemu raspi3b"
#define BOARD_PHYS_BASE 0x04000000ULL                 /* above the loader image */
#define BOARD_MEM_SIZE  (0x3C000000ULL - BOARD_PHYS_BASE)
#define BOARD_BOOT_ARGS "-pi3 serial=3 debug=0x8 -v cpus=1"

#define AUX_ENABLES   0x3F215004
#define AUX_MU_IO     0x3F215040
#define AUX_MU_LSR    0x3F215054
static inline void board_init(void) { mmio_w32(AUX_ENABLES, 1); }
static inline void board_putc(char c)
{
	while (!(mmio_r32(AUX_MU_LSR) & 0x20)) { }
	mmio_w32(AUX_MU_IO, (uint8_t)c);
}
static inline void board_fail(void) { }
static inline void board_video(uint64_t *base, uint64_t *row, uint64_t *w, uint64_t *h, uint64_t *depth)
{ *base = 0; *row = 0; *w = 0; *h = 0; *depth = 0; }

#elif defined(BOARD_TABLET)
/* MT6737T tablet. RAM 0x40000000.., Linux "System RAM" 0x43030000-0x99ffffff.
 * 0x40080000 = this loader, 0x44000000 = LK's ramdisk, 0x4e000000 = LK's DTB. */
#define BOARD_NAME      "MT6737T tablet"
#define BOARD_PHYS_BASE 0x50000000ULL
#define BOARD_MEM_SIZE  (0x99000000ULL - BOARD_PHYS_BASE)
#define BOARD_BOOT_ARGS "serial=0 debug=0x8 -v cpus=1"

#define FB_BASE   0x9f210000ULL
#define FB_W      800
#define FB_H      1280
#define FB_STRIDE (FB_W * 4)
#define WDT_MODE  0x10212000ULL

void fbcon_putc(char c);
static inline void board_init(void) { mmio_w32(WDT_MODE, 0x22000000); }
static inline void board_putc(char c) { fbcon_putc(c); }
static inline void board_fail(void)
{   /* red bar across the top: loader gave up */
	for (int y = 0; y < 32; y++)
		for (int x = 0; x < FB_W; x++)
			mmio_w32(FB_BASE + y * FB_STRIDE + x * 4, 0xffff0000);
}
static inline void board_video(uint64_t *base, uint64_t *row, uint64_t *w, uint64_t *h, uint64_t *depth)
{ *base = FB_BASE; *row = FB_STRIDE; *w = FB_W; *h = FB_H; *depth = 32; }

#else
#error "define BOARD_QEMU_PI3 or BOARD_TABLET"
#endif
