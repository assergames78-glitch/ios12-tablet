#!/usr/bin/env python3
"""Turn xnu's genassym.o (really clang -S output) into assym.s.

xnu's genassym.c emits each constant as
    DEFINITION__define__NAME:  .ascii "VALUE"
and osfmk/conf/Makefile.template rewrote that with sed into
    #define NAME VALUE
    #define NAME_NUM VALUE
Modern clang re-prints inline assembly, so single-character values come out
as `.byte 51` instead of `.ascii "3"`, and the old sed silently drops them.
This handles .ascii, .asciz and .byte forms.
"""
import re
import sys

text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
pat = re.compile(r'DEFINITION__define__(\w+):\s*\.(ascii|asciz|byte)\s+([^\n]*)')

seen = set()
out = []
for name, kind, arg in pat.findall(text):
    if name in seen:
        continue
    seen.add(name)
    if kind == 'byte':
        val = ''.join(chr(int(b.strip(), 0)) for b in arg.split(',') if b.strip())
    else:
        val = arg.strip()
        if val.startswith('"') and val.endswith('"'):
            val = val[1:-1]
        val = val.encode().decode('unicode_escape')
    val = val.lstrip('$')
    out.append(f'#define {name} {val}')
    out.append(f'#define {name}_NUM {val.lstrip("$#")}')

if not out:
    sys.exit(f'genassym_to_assym: no DEFINITION__define__ entries in {sys.argv[1]}')
print('\n'.join(out))
