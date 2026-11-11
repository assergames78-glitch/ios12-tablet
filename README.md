# iOS 12 on an MT6737T tablet

A hobby attempt to boot Apple's open-source iOS 12-era kernel (XNU, `xnu-4903`) and,
eventually, an iPhone 5s iOS 12 userland on a generic MediaTek MT6737T Android tablet
(4x Cortex-A53, 1.4 GB RAM, 800x1280). Inspired by
[dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet).

No Apple firmware or other copyrighted Apple binaries are stored in this repository.
Only Apple's open-source releases (APSL) are fetched at build time.

## Status

- [ ] Build xnu-4903 for arm64 (`BCM2837` config, Cortex-A53, 4K pages) on GitHub Actions
- [ ] Boot it in QEMU on an emulated Cortex-A53
- [x] Boot shim for the tablet: runs via `fastboot boot`, disables the watchdog, draws colour bars
- [ ] XNU console on the tablet's screen

## Tablet facts (learned the hard way)

| What | Value |
|---|---|
| Bootloader | MediaTek LK, unlocked, supports `fastboot boot` (RAM only, nothing flashed) |
| Load addresses | kernel `0x40080000`, ramdisk `0x44000000`, DTB `0x4e000000`, page size 2048 |
| Kernel format | `Image.gz` + appended DTB, arm64 Linux Image header required |
| Framebuffer | `0x9f210000` (from `/chosen/atag,videolfb`), 800x1280, stride 3200, 14.3 MB VRAM |
| Pixel format | 32-bit `0xAARRGGBB`; alpha must be `0xFF` or the overlay shows black |
| Panel | `jd9365_ivo_ips_dsi_vdo` — DSI video mode, refreshes from memory by itself |
| Watchdog | TOPRGU `mediatek,mt6735-rgu` @ `0x10212000`; write `0x22000000` to disable |

## Boot shim

```bash
bash shim/build.sh path/to/stock-boot.img   # in WSL / Linux with aarch64-linux-gnu-gcc, mkbootimg
adb reboot bootloader
fastboot boot shim/out/shim-boot.img
```

Hold power ~10 s to leave the shim (the watchdog is off, so nothing else resets it).

## Building

Run the **xnu-4903 (iOS 12 kernel)** workflow from the Actions tab. Logs for every
build stage are uploaded as an artifact, even when the build fails.
