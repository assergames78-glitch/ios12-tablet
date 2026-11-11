#!/bin/bash
# Wrap loader/out/tablet/loader.bin in an Android boot.img the tablet's LK
# accepts (same header values as the stock image). For `fastboot boot` only.
#   loader/mkboot-tablet.sh <stock boot.img>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STOCK="${1:?usage: mkboot-tablet.sh <stock boot.img>}"
OUT="$HERE/out/tablet"
[ -f "$OUT/loader.bin" ] || { echo "build the tablet loader first (loader/build.sh tablet ...)"; exit 1; }

rm -rf "$OUT/stock" && unpack_bootimg --boot_img "$STOCK" --out "$OUT/stock" >/dev/null
python3 "$ROOT/shim/extract_dtb.py" "$OUT/stock/kernel" "$OUT/stock.dtb" >/dev/null
gzip -9 -n -c "$OUT/loader.bin" > "$OUT/loader.bin.gz"
cat "$OUT/loader.bin.gz" "$OUT/stock.dtb" > "$OUT/loader.gz-dtb"
mkbootimg --kernel "$OUT/loader.gz-dtb" --ramdisk "$OUT/stock/ramdisk" \
  --base 0x40000000 --kernel_offset 0x00080000 --ramdisk_offset 0x04000000 \
  --second_offset 0x00f00000 --tags_offset 0x0e000000 --pagesize 2048 \
  --os_version 8.1.0 --os_patch_level 2020-03 \
  --cmdline "bootopt=64S3,32N2,64N2 buildvariant=user" \
  -o "$OUT/ios12-boot.img"
echo "built $OUT/ios12-boot.img ($(stat -c %s "$OUT/ios12-boot.img") bytes; loader $(stat -c %s "$OUT/loader.bin") bytes uncompressed)"
