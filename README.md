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
- [ ] Boot shim for the tablet (MediaTek LK bootloader)
- [ ] XNU console on the tablet's screen

## Building

Run the **xnu-4903 (iOS 12 kernel)** workflow from the Actions tab. Logs for every
build stage are uploaded as an artifact, even when the build fails.
