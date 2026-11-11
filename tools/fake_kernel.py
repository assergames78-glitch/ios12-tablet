#!/usr/bin/env python3
"""Make a tiny fake xnu-style Mach-O to test the loader without a real kernel.

Its "kernel" prints 'xnu stand-in: boot_args at <x0>' on the Pi 3 mini UART,
then the first 8 bytes of boot_args (Revision/Version/virtBase low bits),
and spins. Code is position-independent and runs with the MMU off.

usage: fake_kernel.py <code.bin> <out.macho>
"""
import struct
import sys

code = open(sys.argv[1], 'rb').read()
VMADDR = 0xfffffff007004000          # same base a real iOS 12 kernel uses
HDR = 0x4000                          # code starts one 16K page into the file

# load commands: one LC_SEGMENT_64 (__TEXT) + LC_UNIXTHREAD
seg = struct.pack('<II16sQQQQIIII', 0x19, 72, b'__TEXT', VMADDR, 0x4000,
                  HDR, len(code), 5, 5, 0, 0)
# ARM_THREAD_STATE64 (flavor 6, count 68 words): x0..x28, fp, lr, sp, pc, cpsr+pad
regs = [0] * 32 + [VMADDR, 0]         # index 32 = pc
thread = struct.pack('<IIII', 0x5, 16 + 34 * 8, 6, 68) + struct.pack('<34Q', *regs)
cmds = seg + thread
hdr = struct.pack('<IIIIIIII', 0xfeedfacf, 0x0100000c, 0, 2, 2, len(cmds), 1, 0)
blob = (hdr + cmds).ljust(HDR, b'\0') + code
open(sys.argv[2], 'wb').write(blob)
print(f'{sys.argv[2]}: fake kernel, {len(blob)} bytes, entry {VMADDR:#x}')
