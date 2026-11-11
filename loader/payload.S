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
