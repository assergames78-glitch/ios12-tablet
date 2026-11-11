# Progress log (plain language)

The goal: start iOS 12 on a cheap MediaTek tablet that was never meant to run it.
It needs three things:

1. **A starter program** on the tablet that runs first and gets things ready.
2. **The core of iOS** (the "kernel") built from Apple's published 2018 source.
3. **The rest of iOS** (home screen, apps) from an iPhone 5s copy of iOS 12.

---

## 11 November 2026

**Afternoon: figured out the tablet.** Read its chip, memory, screen and storage
over USB. Found that its bootloader is already unlocked and can run a program
from memory without installing anything ("fastboot boot"), which makes testing safe.

**Afternoon: first code on the tablet.** A tiny test program painted red, green
and blue stripes on the screen. It took three tries:

- **Try 1:** the tablet's safety timer (a "watchdog") rebooted it.
- **Try 2:** the stripes came out invisible because of a transparency setting.
- **Try 3:** worked. 🎉

**Afternoon to evening: building the core of iOS.** Apple's 2018 instructions
don't quite fit today's tools, so each build attempt shows what doesn't fit and
gets fixed. Attempt 6 built *every part* of the core. Only the very last step,
gluing the parts together, failed, because one support library was missing a
standard header file. Attempt 7 is running with that fixed.

**Evening: the loader.** Wrote the program that will start the core of iOS. It
copies the core into memory, writes the information Apple's core expects at
startup (how much memory there is, what hardware is present), and hands over.
Tested on a pretend Raspberry Pi running on the PC (QEMU) with a stand-in
"kernel": the hand-over works.

**Evening: attempt 7.** Got past the missing file, then hit the next one: the
logging library needs a piece from another Apple package. Attempt 8 adds that
package, plus a safety net: if the logging library *still* won't build, a
do-nothing stand-in is used so the core can finish building anyway. (The core
copes fine without it: it just skips saving some log messages. Its on-screen
startup text doesn't depend on it.)

**Evening: attempt 8.** The safety net kicked in and the core got to the very
last step, missing only 6 names from a small Apple feature called "blocks".
Apple's Raspberry Pi settings (our starting point) simply forgot to switch that
feature on, unlike the iPhone settings. Attempt 9 switches it on.

**Evening: 🎉 the core of iOS 12 built (attempt 9)!** An 11.5 MB kernel file.

**Evening: first start in the pretend Raspberry Pi.** The loader handed over,
and iOS's core started running its own code and switched on its own memory
system. Then it crashed before printing anything. Reason: today's Apple tools
built it for *new* iPhone chips, using about 3,900 instructions that older chips
(like the tablet's and the Raspberry Pi's) don't have. Attempt 10 builds it for
the iPhone 5s's chip instead, which speaks the same language as the tablet's.

### What's next

1. Attempt 7 finishes → a real iOS 12 core file.
2. Start it in the pretend Raspberry Pi on the PC and read its startup text.
3. Fix whatever it trips over, then try it on the tablet.
