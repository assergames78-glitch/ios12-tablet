#!/bin/bash
# Build the loader for one board with a kernel embedded.
#   loader/build.sh qemu-pi3 path/to/kernel.development.bcm2837
#   loader/build.sh tablet   path/to/kernel.development.bcm2837
# Output: loader/out/<board>/loader.bin (arm64 Linux Image format)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BOARD="${1:?board: qemu-pi3 | tablet}"
KERNEL="$(realpath "${2:?path to xnu Mach-O kernel}")"
OUT="$HERE/out/$BOARD"
CROSS="${CROSS:-aarch64-linux-gnu-}"
mkdir -p "$OUT"

case "$BOARD" in
  qemu-pi3) DEF=BOARD_QEMU_PI3; LOAD=0x80000 ;;
  tablet)   DEF=BOARD_TABLET;   LOAD=0x40080000 ;;
  *) echo "unknown board $BOARD"; exit 1 ;;
esac

python3 "$ROOT/tools/mkadt.py" "$BOARD" "$OUT/adt.bin"

CFLAGS=(-O2 -ffreestanding -nostdlib -fno-builtin -fno-pic -fno-stack-protector
        -mgeneral-regs-only -mstrict-align -Wall -D"$DEF" -I"$HERE")
"${CROSS}gcc" "${CFLAGS[@]}" -c "$HERE/entry.S" -o "$OUT/entry.o"
"${CROSS}gcc" "${CFLAGS[@]}" -c "$HERE/main.c"  -o "$OUT/main.o"
"${CROSS}gcc" "${CFLAGS[@]}" -c "$HERE/fbcon.c" -o "$OUT/fbcon.o"
LOGO_DEF=()
if [ -n "${LOGO:-}" ] && [ -f "$LOGO" ]; then
  LOGO_DEF=(-DLOGO_PATH="\"$(realpath "$LOGO")\"")
  echo "boot logo: $LOGO"
fi
"${CROSS}gcc" "${CFLAGS[@]}" -DKERNEL_PATH="\"$KERNEL\"" -DADT_PATH="\"$OUT/adt.bin\"" \
  "${LOGO_DEF[@]}" -c "$HERE/payload.S" -o "$OUT/payload.o"
"${CROSS}ld" -nostdlib --defsym LOAD_ADDR=$LOAD -T "$HERE/link.ld" \
  "$OUT/entry.o" "$OUT/main.o" "$OUT/fbcon.o" "$OUT/payload.o" -o "$OUT/loader.elf"
"${CROSS}objcopy" -O binary "$OUT/loader.elf" "$OUT/loader.bin"
echo "built $OUT/loader.bin ($(stat -c %s "$OUT/loader.bin") bytes, load address $LOAD)"
