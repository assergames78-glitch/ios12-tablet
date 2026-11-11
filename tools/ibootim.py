#!/usr/bin/env python3
"""Decode an Apple boot image (IM4P-wrapped 'iBootIm', LZSS) into raw pixels
for the loader: 8-byte header (u32 width, u32 height) + width*height ARGB u32.

usage: ibootim.py <applelogo .im4p or raw iBootIm> <out.logo> [preview.ppm]
"""
import struct
import sys


def der_read(b, i):
    tag = b[i]; i += 1
    ln = b[i]; i += 1
    if ln & 0x80:
        n = ln & 0x7f
        ln = int.from_bytes(b[i:i + n], 'big'); i += n
    return tag, i, ln


def im4p_payload(b):
    tag, i, ln = der_read(b, 0)               # SEQUENCE
    assert tag == 0x30, 'not DER'
    end = i + ln
    items = []
    while i < end:
        t, j, l = der_read(b, i)
        items.append((t, b[j:j + l]))
        i = j + l
    assert items[0][1] == b'IM4P', 'not an IM4P'
    payload = items[3][1]
    if len(items) > 4 and items[4][0] == 0x04:
        print('note: IM4P has a KBAG (encrypted?)', file=sys.stderr)
    return payload


def lzss(src, out_len):
    N, F, TH = 4096, 18, 2
    text = bytearray(b' ' * (N - F) + b'\0' * F)
    r, out, i, flags = N - F, bytearray(), 0, 0
    while len(out) < out_len and i < len(src):
        flags >>= 1
        if not flags & 0x100:
            flags = src[i] | 0xff00; i += 1
        if flags & 1:
            c = src[i]; i += 1
            out.append(c); text[r] = c; r = (r + 1) & (N - 1)
        else:
            if i + 1 >= len(src):
                break
            a, b2 = src[i], src[i + 1]; i += 2
            pos = a | ((b2 & 0xf0) << 4)
            length = (b2 & 0x0f) + TH + 1
            for k in range(length):
                c = text[(pos + k) & (N - 1)]
                out.append(c); text[r] = c; r = (r + 1) & (N - 1)
    return bytes(out)


data = open(sys.argv[1], 'rb').read()
if data[:1] == b'\x30':
    data = im4p_payload(data)
assert data[:8] == b'iBootIm\0', f'not an iBootIm image (starts {data[:8]!r})'
comp, fmt, w, h = struct.unpack_from('<4s4sHH', data, 12)
comp, fmt = comp[::-1], fmt[::-1]
print(f'iBootIm {w}x{h} compression={comp.decode()} format={fmt.decode()}')
bpp = 4 if fmt == b'argb' else 2
raw = lzss(data[0x40:], w * h * bpp) if comp == b'lzss' else data[0x40:]
assert len(raw) >= w * h * bpp, f'short image: {len(raw)} < {w * h * bpp}'

px = []
for k in range(w * h):
    if fmt == b'argb':
        bb, gg, rr, aa = raw[4 * k:4 * k + 4]          # stored B,G,R,A
    else:
        gg, aa = raw[2 * k], raw[2 * k + 1]            # grey + alpha
        rr = bb = gg
    # composite onto black, output opaque 0xFFRRGGBB
    rr, gg, bb = (rr * aa) // 255, (gg * aa) // 255, (bb * aa) // 255
    px.append(0xff000000 | (rr << 16) | (gg << 8) | bb)

open(sys.argv[2], 'wb').write(struct.pack('<II', w, h) + struct.pack(f'<{len(px)}I', *px))
print(f'{sys.argv[2]}: {w}x{h} ARGB')
if len(sys.argv) > 3:
    with open(sys.argv[3], 'wb') as f:
        f.write(f'P6 {w} {h} 255\n'.encode())
        f.write(bytes(c for p in px for c in ((p >> 16) & 255, (p >> 8) & 255, p & 255)))
