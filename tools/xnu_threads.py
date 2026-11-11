#!/usr/bin/env python3
"""Symbolise the 'ios12-dump:' thread dump printed by the ios12-tablet kernel.

usage: xnu_threads.py <unstripped kernel Mach-O> <serial log>
"""
import bisect
import re
import subprocess
import sys

kernel, log = sys.argv[1], sys.argv[2]
syms = []
for line in subprocess.run(['llvm-nm', '-n', '--defined-only', kernel],
                           capture_output=True, text=True).stdout.splitlines():
    p = line.split()
    if len(p) >= 3:
        syms.append((int(p[0], 16), p[2]))
addrs = [a for a, _ in syms]


def sym(v):
    if v < 0xfffffff000000000:
        return hex(v)
    i = bisect.bisect_right(addrs, v) - 1
    if i < 0:
        return hex(v)
    a, n = syms[i]
    off = v - a
    return f'{n}+{off:#x}' if off < 0x100000 else hex(v)


for line in open(log, errors='replace'):
    line = line.rstrip('\r\n')
    if 'ios12-dump:' not in line:
        continue
    m = re.search(r'thread (0x[0-9a-f]+) tid (\d+) state (0x[0-9a-f]+) event (0x[0-9a-f]+) cont (0x[0-9a-f]+|0x0|\(null\)) kernel_task (\d)', line)
    if m:
        ev = int(m.group(4), 16)
        cont = m.group(5)
        cont_s = sym(int(cont, 16)) if cont.startswith('0x') else cont
        print(f"tid {m.group(2):>4} state {m.group(3):>5} event {sym(ev) if ev else '-':40} cont {cont_s}")
        continue
    if ' bt ' in line:
        frames = [sym(int(x, 16)) for x in re.findall(r'0x[0-9a-f]+', line)]
        print('        ' + ' <- '.join(frames))
        continue
    print(line)
