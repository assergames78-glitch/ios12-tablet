#!/bin/bash
# Boot an xnu kernel in QEMU's Raspberry Pi 3 through our loader.
#   scripts/run-qemu.sh path/to/kernel.development.bcm2837 [seconds]
# The kernel's serial console (Pi 3 mini UART) prints to this terminal and
# to qemu.log. QEMU's own CPU-exception log goes to qemu-debug.log.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="${1:?kernel Mach-O}"
SECS="${2:-60}"
bash "$ROOT/loader/build.sh" qemu-pi3 "$KERNEL"
timeout "$SECS" qemu-system-aarch64 -M raspi3b \
  -kernel "$ROOT/loader/out/qemu-pi3/loader.bin" \
  -display none -serial null -serial stdio -monitor none \
  -d guest_errors,unimp,int -D "$ROOT/qemu-debug.log" 2>&1 | tee "$ROOT/qemu.log" || true
echo "---- last CPU exceptions (qemu-debug.log) ----"
grep -a -E 'Taking exception|ESR|ELR|FAR' "$ROOT/qemu-debug.log" | tail -12 || true
