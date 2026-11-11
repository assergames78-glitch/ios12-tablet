#!/usr/bin/env python3
"""Fetch single files out of a remote IPSW (a zip) using HTTP range requests,
without downloading the whole multi-GB firmware.

usage: ipsw_fetch.py <ipsw-url> list [substring]
       ipsw_fetch.py <ipsw-url> get <member-path> <out-file>
"""
import io
import sys
import urllib.request
import zipfile

UA = {'User-Agent': 'generic-client'}


class HTTPRangeFile(io.RawIOBase):
    def __init__(self, url):
        self.url, self.pos = url, 0
        req = urllib.request.Request(url, method='HEAD', headers=UA)
        with urllib.request.urlopen(req) as r:
            self.size = int(r.headers['Content-Length'])
        self.fetched = 0

    def seekable(self):
        return True

    def readable(self):
        return True

    def seek(self, off, whence=0):
        self.pos = off if whence == 0 else self.pos + off if whence == 1 else self.size + off
        return self.pos

    def tell(self):
        return self.pos

    def read(self, n=-1):
        if n is None or n < 0:
            n = self.size - self.pos
        if n == 0 or self.pos >= self.size:
            return b''
        end = min(self.pos + n, self.size) - 1
        req = urllib.request.Request(self.url, headers={**UA, 'Range': f'bytes={self.pos}-{end}'})
        with urllib.request.urlopen(req) as r:
            data = r.read()
        self.pos += len(data)
        self.fetched += len(data)
        return data

    def readinto(self, b):
        d = self.read(len(b))
        b[:len(d)] = d
        return len(d)


url, cmd = sys.argv[1], sys.argv[2]
f = HTTPRangeFile(url)
z = zipfile.ZipFile(io.BufferedReader(f, buffer_size=1 << 16))
if cmd == 'list':
    sub = sys.argv[3] if len(sys.argv) > 3 else ''
    for i in z.infolist():
        if sub.lower() in i.filename.lower():
            print(f'{i.file_size:>12}  {i.filename}')
elif cmd == 'get':
    data = z.read(sys.argv[3])
    open(sys.argv[4], 'wb').write(data)
    print(f'{sys.argv[4]}: {len(data)} bytes')
print(f'(downloaded {f.fetched / 1024:.0f} KB of {f.size / 1024 / 1024:.0f} MB)', file=sys.stderr)
