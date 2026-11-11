#!/usr/bin/env python3
"""Build an Apple Device Tree (ADT) blob for xnu-4903.

The flattened ADT format (pexpert/pexpert/device_tree.h):
  node   := u32 nProperties, u32 nChildren, property[nProperties], node[nChildren]
  property := char name[32] (NUL-terminated), u32 length, value (padded to 4)

usage: mkadt.py <board> <out.adt>      board: qemu-pi3 | tablet
"""
import struct
import sys


def u32(*v):
    return struct.pack('<%dI' % len(v), *v)


def u64(*v):
    return struct.pack('<%dQ' % len(v), *v)


def s(text):
    return text.encode() + b'\0'


def strs(*items):
    return b''.join(s(i) for i in items)


class Node:
    def __init__(self, name, **props):
        self.props = [('name', s(name))]
        for k, v in props.items():
            self.props.append((k.replace('__', '-').replace('_dash_', '-'), v))
        self.children = []

    def prop(self, name, value):
        self.props.append((name, value))
        return self

    def add(self, child):
        self.children.append(child)
        return child

    def pack(self):
        out = u32(len(self.props), len(self.children))
        for name, value in self.props:
            assert len(name) < 32, name
            out += name.encode().ljust(32, b'\0') + u32(len(value))
            out += value + b'\0' * ((4 - len(value) % 4) % 4)
        for c in self.children:
            out += c.pack()
        return out


def cpus(n, timebase_hz):
    node = Node('cpus')
    for i in range(n):
        cpu = Node('cpu%d' % i)
        cpu.prop('device_type', s('cpu'))
        cpu.prop('compatible', s('arm,cortex-a53'))
        cpu.prop('reg', u32(i))                 # MPIDR Aff0
        cpu.prop('cpu-id', u32(i))
        cpu.prop('state', s('running' if i == 0 else 'waiting'))
        cpu.prop('timebase-frequency', u32(timebase_hz))
        cpu.prop('bus-frequency', u32(100000000))
        cpu.prop('memory-frequency', u32(400000000))
        cpu.prop('peripheral-frequency', u32(100000000))
        cpu.prop('fixed-frequency', u32(24000000))
        cpu.prop('clock-frequency', u32(1200000000))
        node.add(cpu)
    return node


def common_root(model, compatible):
    root = Node('device-tree')
    root.prop('compatible', strs(compatible, 'AppleARM'))
    root.prop('model', s(model))
    root.prop('target-type', s(model))
    root.prop('#address-cells', u32(2))
    root.prop('#size-cells', u32(2))

    chosen = root.add(Node('chosen'))
    chosen.prop('debug-enabled', u32(1))
    chosen.prop('firmware-version', s('ios12-tablet-loader'))
    chosen.prop('random-seed', bytes(range(64)))
    chosen.prop('dram-vendor-id', u32(0))
    chosen.add(Node('memory-map'))
    root.add(Node('defaults'))
    return root


def qemu_pi3():
    root = common_root('Pi3,1', 'Pi3,1')
    root.add(cpus(4, 19200000))
    armio = root.add(Node('arm-io'))
    armio.prop('device_type', s('bcm2837-io'))
    armio.prop('compatible', s('bcm2837-io'))
    # ranges: child base, parent (physical) base, size  -- read as uintptr_t[]
    armio.prop('ranges', u64(0, 0x3F000000, 0x01000000))
    return root


def tablet():
    root = common_root('MT6737T,1', 'MT6737T,1')
    root.add(cpus(4, 13000000))           # MT6735 arch timer: 13 MHz
    armio = root.add(Node('arm-io'))
    # Reuse the BCM2837 SoC hooks for now; real MT6737 drivers come later.
    armio.prop('device_type', s('bcm2837-io'))
    armio.prop('compatible', s('mt6737t-io'))
    armio.prop('ranges', u64(0, 0x10000000, 0x01000000))
    return root


BOARDS = {'qemu-pi3': qemu_pi3, 'tablet': tablet}

if __name__ == '__main__':
    board, out = sys.argv[1], sys.argv[2]
    blob = BOARDS[board]().pack()
    open(out, 'wb').write(blob)
    print(f'{out}: {len(blob)} bytes ADT for {board}')
