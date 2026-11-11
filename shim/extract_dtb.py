#!/usr/bin/env python3
"""Extract the DTB appended after a gzip'd arm64 kernel (MediaTek Image.gz-dtb)."""
import struct, sys, zlib

src, dst = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()

# Find where the gzip stream ends; the DTB follows it.
d = zlib.decompressobj(16 + zlib.MAX_WBITS)
d.decompress(data)
end = len(data) - len(d.unused_data)

off = data.find(b'\xd0\x0d\xfe\xed', end)
if off < 0:
    sys.exit('no DTB found after the gzip stream')
size = struct.unpack('>I', data[off + 4:off + 8])[0]
open(dst, 'wb').write(data[off:off + size])
print(f'gzip ends at {end}, DTB at {off}, {size} bytes -> {dst}')
