#!/bin/bash
# Build the shim and wrap it in a boot.img the tablet's LK will accept.
#   shim/build.sh <path-to-stock-boot.img>
# Output: shim/out/shim-boot.img (for `fastboot boot`, never flashed).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STOCK="${1:?usage: build.sh <stock boot.img>}"
OUT="$HERE/out"
CROSS="${CROSS:-aarch64-linux-gnu-}"
mkdir -p "$OUT"

# 1. Assemble + link at the address LK loads kernels to.
"${CROSS}gcc" -nostdlib -nostartfiles -ffreestanding -mgeneral-regs-only \
  -Wl,-Ttext=0x40080000 -Wl,--build-id=none -Wl,-e,_head \
  -o "$OUT/shim.elf" "$HERE/start.S"
"${CROSS}objcopy" -O binary -j .text "$OUT/shim.elf" "$OUT/shim.bin"
echo "shim.bin: $(stat -c %s "$OUT/shim.bin") bytes"

# 2. Pull the stock kernel's appended DTB and the ramdisk out of the stock image.
rm -rf "$OUT/stock" && unpack_bootimg --boot_img "$STOCK" --out "$OUT/stock" >/dev/null
python3 "$HERE/extract_dtb.py" "$OUT/stock/kernel" "$OUT/stock.dtb"

# 3. Image.gz-dtb, the format MediaTek LK expects.
gzip -9 -n -c "$OUT/shim.bin" > "$OUT/shim.bin.gz"
cat "$OUT/shim.bin.gz" "$OUT/stock.dtb" > "$OUT/shim.gz-dtb"

# 4. Same header values as the stock boot.img.
mkbootimg \
  --kernel "$OUT/shim.gz-dtb" \
  --ramdisk "$OUT/stock/ramdisk" \
  --base 0x40000000 \
  --kernel_offset 0x00080000 \
  --ramdisk_offset 0x04000000 \
  --second_offset 0x00f00000 \
  --tags_offset 0x0e000000 \
  --pagesize 2048 \
  --os_version 8.1.0 --os_patch_level 2020-03 \
  --cmdline "bootopt=64S3,32N2,64N2 buildvariant=user" \
  -o "$OUT/shim-boot.img"
echo "built: $OUT/shim-boot.img ($(stat -c %s "$OUT/shim-boot.img") bytes)"
