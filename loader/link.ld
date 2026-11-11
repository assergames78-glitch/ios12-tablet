ENTRY(_head)
SECTIONS
{
	. = LOAD_ADDR;
	.text   : { *(.text) *(.text.*) }
	.rodata : { *(.rodata) *(.rodata.*) }
	.data   : { *(.data) *(.data.*) }
	. = ALIGN(16);
	__bss_start = .;
	.bss    : { *(.bss) *(.bss.*) *(COMMON) }
	__bss_end = .;
	. = ALIGN(16);
	. += 0x10000;
	stack_top = .;
	_end = .;
	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
