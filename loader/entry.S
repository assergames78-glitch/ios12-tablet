/*
 * ios12-tablet loader: entry point.
 *
 * Loaded like an arm64 Linux kernel (Linux Image header) by:
 *   - QEMU `-M raspi3b -kernel loader.bin`  (enters at EL2)
 *   - the tablet's MediaTek LK via fastboot boot (enters at EL1 or EL2)
 * Drops to EL1 if needed, sets up a stack, and calls loader_main(dtb).
 */
	.text
	.globl	_head
_head:
	b	start			/* code0 */
	.long	0			/* code1 */
	.quad	0x80000			/* text_offset */
	.quad	_end - _head		/* image_size */
	.quad	0x2			/* flags: LE, 4K pages */
	.quad	0, 0, 0
	.ascii	"ARM\x64"
	.long	0

start:
	mov	x19, x0			/* DTB from the previous bootloader */

	/* Park every core except core 0 (QEMU starts all four). */
	mrs	x1, mpidr_el1
	and	x1, x1, #0xff
	cbz	x1, 1f
park:	wfe
	b	park
1:
	mrs	x1, CurrentEL
	lsr	x1, x1, #2
	cmp	x1, #3
	b.eq	from_el3
	cmp	x1, #2
	b.eq	from_el2
	b	el1

from_el3:
	ldr	x1, =0x5b1		/* SCR_EL3: NS, HCE, SMD off, RW (EL2 aarch64) */
	msr	scr_el3, x1
	mov	x1, #(1 << 31)		/* HCR_EL2.RW: EL1 is aarch64 */
	msr	hcr_el2, x1
	ldr	x1, =0x30d00800		/* SCTLR_EL1 RES1 bits, MMU/caches off */
	msr	sctlr_el1, x1
	mov	x1, #0x3c5		/* EL1h, DAIF masked */
	msr	spsr_el3, x1
	adr	x1, el1
	msr	elr_el3, x1
	eret

from_el2:
	mov	x1, #(1 << 31)		/* HCR_EL2.RW */
	msr	hcr_el2, x1
	mov	x1, #3			/* EL1 may use physical counter + timer */
	msr	cnthctl_el2, x1
	msr	cntvoff_el2, xzr
	ldr	x1, =0x30d00800
	msr	sctlr_el1, x1
	mov	x1, #0x3c5
	msr	spsr_el2, x1
	adr	x1, el1
	msr	elr_el2, x1
	eret

el1:
	mov	x1, #(3 << 20)		/* CPACR_EL1.FPEN: allow FP/SIMD */
	msr	cpacr_el1, x1
	isb
	ldr	x1, =stack_top
	mov	sp, x1
	ldr	x1, =__bss_start
	ldr	x2, =__bss_end
2:	cmp	x1, x2
	b.hs	3f
	str	xzr, [x1], #8
	b	2b
3:
	mov	x0, x19
	bl	loader_main
4:	wfe
	b	4b

/* void jump_to_kernel(uint64_t entry_phys, uint64_t boot_args_phys) */
	.globl	jump_to_kernel
jump_to_kernel:
	mov	x2, x0
	mov	x0, x1
	mov	x1, xzr
	dsb	sy
	ic	iallu
	tlbi	vmalle1
	dsb	sy
	isb
	br	x2

	.ltorg
