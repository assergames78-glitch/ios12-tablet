/* Stand-in "kernel" for loader tests: prints over the Pi 3 mini UART. */
	.text
	.globl	_start
_start:
	mov	x19, x0			/* boot_args (physical) */
	adr	x0, msg
	bl	puts
	mov	x0, x19
	bl	puthex
	adr	x0, msg2
	bl	puts
	ldr	x0, [x19]		/* Revision | Version | pad */
	bl	puthex
	adr	x0, nl
	bl	puts
1:	wfe
	b	1b

putc:	/* w0 */
	ldr	x1, =0x3F215054
2:	ldr	w2, [x1]
	tbz	w2, #5, 2b
	ldr	x1, =0x3F215040
	str	w0, [x1]
	ret

puts:	/* x0 = string */
	mov	x20, x30
	mov	x21, x0
3:	ldrb	w0, [x21], #1
	cbz	w0, 4f
	bl	putc
	b	3b
4:	mov	x30, x20
	ret

puthex:	/* x0 = value */
	mov	x22, x30
	mov	x23, x0
	mov	x24, #60
5:	lsr	x0, x23, x24
	and	x0, x0, #15
	cmp	x0, #10
	add	x1, x0, #'0'
	add	x2, x0, #('a' - 10)
	csel	x0, x1, x2, lt
	bl	putc
	subs	x24, x24, #4
	b.pl	5b
	mov	x30, x22
	ret

msg:	.asciz	"xnu stand-in: boot_args at 0x"
msg2:	.asciz	", revision/version word 0x"
nl:	.asciz	"\r\n"
	.ltorg
