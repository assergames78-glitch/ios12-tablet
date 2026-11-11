#!/usr/bin/env python3
"""Explain QEMU's exception log for an xnu boot: map ELR/FAR/LR to kernel symbols.

usage: xnu_exc.py <kernel Mach-O (unstripped)> <qemu-debug.log> [max]
Needs llvm-nm on PATH.
"""
import bisect
import re
import subprocess
import sys

kernel, log = sys.argv[1], sys.argv[2]
limit = int(sys.argv[3]) if len(sys.argv) > 3 else 12

syms = []
for line in subprocess.run(['llvm-nm', '-n', '--defined-only', kernel],
                           capture_output=True, text=True).stdout.splitlines():
    parts = line.split()
    if len(parts) >= 3 and parts[1].lower() in ('t', 's', 'd', 'b'):
        syms.append((int(parts[0], 16), parts[2]))
addrs = [a for a, _ in syms]


def sym(v):
    if not (0xfffffff000000000 <= v < 0xfffffff100000000):
        return ''
    i = bisect.bisect_right(addrs, v) - 1
    if i < 0:
        return ''
    a, n = syms[i]
    return f'{n}+{v - a:#x}'


ESR_EC = {0x15: 'SVC', 0x18: 'MSR/MRS trap', 0x20: 'instr abort (lower EL)', 0x21: 'instr abort',
          0x22: 'PC alignment', 0x24: 'data abort (lower EL)', 0x25: 'data abort',
          0x26: 'SP alignment', 0x2c: 'FP', 0x3c: 'BRK', 0x00: 'unknown/undefined instruction'}

events, cur = [], None
for line in open(log, errors='replace'):
    m = re.search(r'Taking exception (\d+) \[([^\]]+)\]', line)
    if m:
        cur = {'kind': m.group(2)}
        events.append(cur)
        continue
    if cur is None:
        continue
    for key in ('ESR', 'FAR', 'ELR'):
        m = re.search(key + r' (0x[0-9a-f]+)(?:/(0x[0-9a-f]+))?', line)
        if m:
            cur[key] = int(m.group(2) or m.group(1), 16)

print(f'{len(events)} exceptions; first {limit}:')
for e in events[:limit]:
    esr = e.get('ESR', 0)
    ec = (esr >> 26) & 0x3f
    print(f"- {e['kind']}: {ESR_EC.get(ec, hex(ec))} (ESR {esr:#x})")
    if 'ELR' in e:
        print(f"    at  {e['ELR']:#x}  {sym(e['ELR'])}")
    if 'FAR' in e and e['kind'] in ('Data Abort', 'Prefetch Abort'):
        far = e['FAR']
        txt = far.to_bytes(8, 'little')
        hint = f"  (looks like text {txt!r})" if all(32 <= b < 127 for b in txt) else ''
        print(f"    bad address {far:#x}{hint}")
