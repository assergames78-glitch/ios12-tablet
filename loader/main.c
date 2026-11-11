/*
 * ios12-tablet loader: puts xnu-4903 (a plain Mach-O kernel) into memory,
 * builds boot_args + an Apple Device Tree, and jumps to it the way iBoot does.
 *
 * Contract (xnu osfmk/arm64/start.s, pexpert/pexpert/arm64/boot.h):
 *   x0 = physical address of boot_args, MMU off, EL1, interrupts masked.
 *   Kernel segments sit at physBase + (vmaddr - virtBase).
 *   boot_args.deviceTreeP is a *kernel virtual* address.
 */
#include <stdint.h>
#include <stddef.h>
#include "board.h"

extern char kernel_start[], kernel_end[], adt_start[], adt_end[];
extern char logo_start[], logo_end[];
void board_draw_logo(const uint8_t *logo, size_t len);
extern void jump_to_kernel(uint64_t entry_phys, uint64_t boot_args_phys);

/* ---- tiny libc ---- */
void *memcpy(void *d, const void *s, size_t n)
{
	uint8_t *dp = d; const uint8_t *sp = s;
	while (n--) *dp++ = *sp++;
	return d;
}
void *memset(void *d, int c, size_t n)
{
	uint8_t *dp = d;
	while (n--) *dp++ = (uint8_t)c;
	return d;
}
static size_t strlen_(const char *s) { size_t n = 0; while (s[n]) n++; return n; }

/* ---- console ---- */
static void puts_(const char *s) { while (*s) { if (*s == '\n') board_putc('\r'); board_putc(*s++); } }
static void puthex(uint64_t v)
{
	puts_("0x");
	for (int i = 60; i >= 0; i -= 4) board_putc("0123456789abcdef"[(v >> i) & 15]);
}
static void kv(const char *k, uint64_t v) { puts_(k); puts_(" = "); puthex(v); puts_("\n"); }
static void die(const char *why) { puts_("LOADER ERROR: "); puts_(why); puts_("\n"); board_fail(); for (;;) __asm__ volatile("wfe"); }

/* ---- Mach-O ---- */
#define MH_MAGIC_64     0xfeedfacf
#define LC_SEGMENT_64   0x19
#define LC_UNIXTHREAD   0x5
struct mach_header_64 { uint32_t magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved; };
struct load_command { uint32_t cmd, cmdsize; };
struct segment_command_64 {
	uint32_t cmd, cmdsize; char segname[16];
	uint64_t vmaddr, vmsize, fileoff, filesize;
	uint32_t maxprot, initprot, nsects, flags;
};

/* ---- boot_args (arm64) ---- */
struct Boot_Video { uint64_t v_baseAddr, v_display, v_rowBytes, v_width, v_height, v_depth; };
struct boot_args {
	uint16_t Revision, Version;
	uint64_t virtBase, physBase, memSize, topOfKernelData;
	struct Boot_Video Video;
	uint32_t machineType;
	uint64_t deviceTreeP;
	uint32_t deviceTreeLength;
	char CommandLine[256];
	uint64_t bootFlags;
	uint64_t memSizeActual;
};

#define ALIGN_UP(x, a) (((x) + (a) - 1) & ~((uint64_t)(a) - 1))

void loader_main(uint64_t dtb)
{
	board_init();
	puts_("\nios12-tablet loader (" BOARD_NAME ")\n");
	kv("previous DTB", dtb);

	const struct mach_header_64 *mh = (const void *)kernel_start;
	kv("kernel image size", (uint64_t)(kernel_end - kernel_start));
	if (mh->magic != MH_MAGIC_64)
		die("payload is not a 64-bit Mach-O kernel");

	/* Pass 1: lowest VM address and entry point. */
	uint64_t vmlow = ~0ULL, pc = 0;
	const uint8_t *lc = (const uint8_t *)(mh + 1);
	for (uint32_t i = 0; i < mh->ncmds; i++) {
		const struct load_command *c = (const void *)lc;
		if (c->cmd == LC_SEGMENT_64) {
			const struct segment_command_64 *sg = (const void *)c;
			if (sg->vmsize && sg->vmaddr && sg->vmaddr < vmlow)
				vmlow = sg->vmaddr;
		} else if (c->cmd == LC_UNIXTHREAD) {
			/* cmd, cmdsize, flavor, count, then x0..x28, fp, lr, sp, pc */
			pc = *(const uint64_t *)(lc + 16 + 32 * 8);
		}
		lc += c->cmdsize;
	}
	if (vmlow == ~0ULL || !pc)
		die("no segments or no entry point in kernel");

	const uint64_t virtBase = vmlow & ~0x1fffffULL;     /* 2 MB aligned */
	const uint64_t physBase = BOARD_PHYS_BASE;
#define V2P(v) (physBase + ((v) - virtBase))
	kv("virtBase", virtBase);
	kv("physBase", physBase);
	kv("entry (virt)", pc);

	/* Pass 2: copy segments. */
	uint64_t top = physBase;
	lc = (const uint8_t *)(mh + 1);
	for (uint32_t i = 0; i < mh->ncmds; i++) {
		const struct load_command *c = (const void *)lc;
		if (c->cmd == LC_SEGMENT_64) {
			const struct segment_command_64 *sg = (const void *)c;
			if (sg->vmsize && sg->vmaddr) {
				uint64_t dst = V2P(sg->vmaddr);
				puts_("  segment "); puts_(sg->segname); puts_(" -> "); puthex(dst); puts_("\n");
				memcpy((void *)dst, kernel_start + sg->fileoff, sg->filesize);
				if (sg->vmsize > sg->filesize)
					memset((void *)(dst + sg->filesize), 0, sg->vmsize - sg->filesize);
				if (dst + sg->vmsize > top)
					top = dst + sg->vmsize;
			}
		}
		lc += c->cmdsize;
	}

	/* Device tree right after the kernel, then boot_args. */
	top = ALIGN_UP(top, 0x4000);
	uint64_t adt_phys = top;
	uint64_t adt_len = (uint64_t)(adt_end - adt_start);
	memcpy((void *)adt_phys, adt_start, adt_len);
	top = ALIGN_UP(top + adt_len, 0x4000);

	struct boot_args *ba = (void *)top;
	memset(ba, 0, sizeof(*ba));
	top = ALIGN_UP(top + sizeof(*ba), 0x4000);

	ba->Revision = 2;
	ba->Version = 2;
	ba->virtBase = virtBase;
	ba->physBase = physBase;
	ba->memSize = BOARD_MEM_SIZE;
	ba->memSizeActual = BOARD_MEM_SIZE;
	ba->topOfKernelData = top;
	ba->deviceTreeP = virtBase + (adt_phys - physBase);
	ba->deviceTreeLength = (uint32_t)adt_len;
	board_video(&ba->Video.v_baseAddr, &ba->Video.v_rowBytes, &ba->Video.v_width,
	    &ba->Video.v_height, &ba->Video.v_depth);
	const char *cmd = BOARD_BOOT_ARGS;
	memcpy(ba->CommandLine, cmd, strlen_(cmd) + 1);

	kv("device tree (phys)", adt_phys);
	kv("boot_args (phys)", (uint64_t)ba);
	kv("topOfKernelData", top);
	puts_("boot-args: "); puts_(cmd); puts_("\n");
	puts_("jumping to xnu...\n\n");

	/* Like iBoot: put up the boot logo, then start the kernel behind it. */
	board_draw_logo((const uint8_t *)logo_start, (size_t)(logo_end - logo_start));

	jump_to_kernel(V2P(pc), (uint64_t)ba);
}
