/* Kernel Mach-O and Apple Device Tree, embedded at build time. */
	.section .rodata
	.balign	16
	.globl	kernel_start, kernel_end, adt_start, adt_end
kernel_start:
	.incbin	KERNEL_PATH
kernel_end:
	.balign	16
adt_start:
	.incbin	ADT_PATH
adt_end:
	/* Boot logo (tools/ibootim.py output: u32 w, u32 h, w*h ARGB), optional. */
	.balign	16
	.globl	logo_start, logo_end
logo_start:
#ifdef LOGO_PATH
	.incbin	LOGO_PATH
#endif
logo_end:
