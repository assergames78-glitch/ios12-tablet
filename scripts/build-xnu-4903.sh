#!/usr/bin/env bash
# Exploratory build of Apple's iOS 12-era XNU (xnu-4903) for arm64.
# Target: BCM2837 machine config (Raspberry Pi 3, 4x Cortex-A53, 4K pages),
# the closest Apple-provided config to our MT6737T tablet.
#
# Runs on a macOS host (GitHub Actions macos runner). Every stage logs to
# logs/<stage>.log so a failed run still tells us what broke.
set -uo pipefail

XNU_TAG="${XNU_TAG:-xnu-4903.270.47}"
LIBDISPATCH_TAG="${LIBDISPATCH_TAG:-libdispatch-1008.270.1}"   # macOS 10.14.6 era
KERNEL_CONFIG="${KERNEL_CONFIG:-DEVELOPMENT}"
ARCH_CONFIG="${ARCH_CONFIG:-ARM64}"
MACHINE_CONFIG="${MACHINE_CONFIG:-BCM2837}"
SDK="${SDK:-iphoneos}"

ROOT="$(pwd)"
WORK="$ROOT/work"
FAKEROOT="$WORK/fakeroot"
LOGS="$ROOT/logs"
mkdir -p "$WORK" "$FAKEROOT" "$LOGS"

stage() { echo; echo "=================== $1 ==================="; }
run() { # run <logname> <cmd...>; never aborts the script
  local name="$1"; shift
  echo "+ $*" | tee -a "$LOGS/$name.log"
  "$@" >>"$LOGS/$name.log" 2>&1
  local rc=$?
  echo "  -> exit $rc (log: logs/$name.log)"
  tail -n 40 "$LOGS/$name.log"
  return $rc
}
clone() { # clone <repo> <tag-or-empty> <dir>
  local repo="$1" tag="$2" dir="$3"
  [ -d "$dir" ] && return 0
  if [ -n "$tag" ]; then
    git clone --depth 1 --branch "$tag" "https://github.com/apple-oss-distributions/$repo.git" "$dir"
  else
    git clone --depth 1 "https://github.com/apple-oss-distributions/$repo.git" "$dir"
  fi
}

stage "host info"
sw_vers; xcodebuild -version; xcrun --sdk "$SDK" --show-sdk-path; xcrun --sdk "$SDK" --show-sdk-version
for t in mig clang ld ctfconvert ctfmerge; do printf '%-12s %s\n' "$t" "$(xcrun --sdk "$SDK" -find $t 2>/dev/null || echo MISSING)"; done

stage "sources"
# Pristine source stays untouched; patches are applied to a staged copy and
# only *changed* files are synced into work/xnu, so a cached build directory
# recompiles just what changed (incremental builds).
clone xnu "$XNU_TAG" "$WORK/xnu-pristine"
clone dtrace "" "$WORK/dtrace"
clone AvailabilityVersions "" "$WORK/AvailabilityVersions"
clone libdispatch "$LIBDISPATCH_TAG" "$WORK/libdispatch" || clone libdispatch "" "$WORK/libdispatch"
clone libpthread "${LIBPTHREAD_TAG:-libpthread-330.250.2}" "$WORK/libpthread"
( cd "$WORK/xnu-pristine" && git log -1 --oneline )

stage "dtrace ctf tools"
[ -n "$(find "$FAKEROOT" -name ctfmerge -type f 2>/dev/null | head -1)" ] && echo "cached" || \
( cd "$WORK/dtrace" && run dtrace xcodebuild install -sdk macosx \
    -target ctfconvert -target ctfdump -target ctfmerge \
    ARCHS="$(uname -m)" CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
    SRCROOT="$WORK/dtrace" OBJROOT="$WORK/build/dtrace.obj" SYMROOT="$WORK/build/dtrace.sym" \
    DSTROOT="$FAKEROOT" )
CTF_BIN="$(dirname "$(find "$FAKEROOT" -name ctfmerge -type f | head -1)")"
echo "ctf tools in: ${CTF_BIN:-NOT BUILT}"

stage "AvailabilityVersions"
[ -n "$(find "$FAKEROOT" -name availability.pl 2>/dev/null | head -1)" ] && echo "cached" || \
( cd "$WORK/AvailabilityVersions" && run availability make install \
    OBJROOT="$WORK/build/av.obj/" SYMROOT="$WORK/build/av.sym/" DSTROOT="$FAKEROOT" )
AVAIL_PL="$(find "$FAKEROOT" -name availability.pl | head -1)"
echo "availability.pl: ${AVAIL_PL:-NOT FOUND}"

stage "patch xnu for a modern macOS host"
rm -rf "$WORK/xnu-staged"
cp -Rp "$WORK/xnu-pristine" "$WORK/xnu-staged"
rm -rf "$WORK/xnu-staged/.git"
cd "$WORK/xnu-staged"
# 1. Apple's style checker (tools/uncrustify.sh) is not in the public source.
sed -i '' -E 's/^(install:.*)[[:space:]]+checkstyle[[:space:]]*$/\1/' makedefs/MakeInc.top
grep -n '^install:' makedefs/MakeInc.top
# 2. macOS no longer ships /usr/bin/python (Python 2). Rewrite the one
#    generator the kernel build needs, and point any other scripts at python3.
cat > bsd/kern/makekdebugevents.py <<'PY'
#!/usr/bin/env python3
# Python 3 port of xnu's makekdebugevents.py: trace.codes -> kd_events[] table.
import re, sys
if len(sys.argv) < 2:
    sys.exit(1)
pat = re.compile(r'0x([0-9a-fA-F]+)\s+([^\s]*)')
table = []
with open(sys.argv[1], 'rt', errors='replace') as codes:
    for line in codes:
        m = pat.match(line)
        if m:
            table.append((int(m.group(1), 16), m.group(2)))
print("typedef struct {")
print("        uint32_t   id;")
print("        const char *name;")
print("} kd_event_t;")
print("kd_event_t kd_events[] = {")
for code, name in sorted(table, key=lambda x: x[0]):
    print('        {0x%x, "%s"},' % (code, name))
print("};")
PY
chmod +x bsd/kern/makekdebugevents.py
grep -rl --include='*.py' '^#!/usr/bin/python' . | while read -r f; do
  echo "python shebang -> python3: $f"; sed -i '' '1s|^#!/usr/bin/python.*|#!/usr/bin/env python3|' "$f"
done
# 3. Use our fakeroot for availability.pl, firehose and kernel headers.
if [ -n "${AVAIL_PL:-}" ]; then
  grep -rl 'libexec/availability.pl' bsd/sys/*.sh | while read -r f; do
    AVAIL_PL="$AVAIL_PL" perl -pi -e 's/\$\{SDKROOT\}\/usr\/local\/libexec\/availability\.pl/$ENV{AVAIL_PL}/g' "$f"
    echo "availability.pl path patched: $f"; grep -n 'availability.pl' "$f"
  done
fi
# 4. BCM2837 bring-up config gaps:
#    - task.c always touches kpc state, so kpc must stay on; the board config
#      just never says how many PMU counters there are. (A53 has 6 + cycle.)
perl -pi -e 's/^(#define ARM_BOARD_CLASS_BCM2837)\s*$/$1\n#define CORE_NCTRS 8 \/* ios12-tablet *\/\n/' \
  pexpert/pexpert/arm64/board_config.h
grep -n -A2 'ARM_BOARD_CLASS_BCM2837' pexpert/pexpert/arm64/board_config.h
#    - "bcm2837-io" hard-codes a 1 MHz timebase. Read the real generic-timer
#      rate (set by firmware: QEMU 19.2 MHz, MT6737 LK/ATF 13 MHz) instead.
perl -pi -e 's/^(\s*)tclk = 1000000;/$1tclk = (uint32_t)__builtin_arm_rsr64("CNTFRQ_EL0"); \/* ios12-tablet *\/\n$1if (tclk == 0) { tclk = 1000000; }/' \
  pexpert/arm/pe_identify_machine.c
grep -n -A1 'ios12-tablet' pexpert/arm/pe_identify_machine.c
#    - Our own source files (xnu-additions/) are copied into the tree.
#      Ios12TabletPlatform: IOKit platform driver for "Pi3,1" / "MT6737T,1",
#      so IOKit doesn't fall back to IOPanicPlatform.
cp -R "$ROOT/xnu-additions/." .
grep -q 'Ios12TabletPlatform.cpp' iokit/conf/files ||
  printf '\niokit/Kernel/Ios12TabletPlatform.cpp\t\t\toptional iokitcpp\n' >> iokit/conf/files
grep -q 'ios12_prng.c' osfmk/conf/files ||
  printf '\nosfmk/prng/ios12_prng.c\t\tstandard\n' >> osfmk/conf/files
grep -q 'ios12_debug.c' osfmk/conf/files ||
  printf 'osfmk/kern/ios12_debug.c\t\tstandard\n' >> osfmk/conf/files
#    - pthread.kext (libpthread's kern/) built into the kernel: bsd_init
#      panics "pthread kernel extension not loaded" without it, and we can't
#      load kexts. Compiled in osfmk (it was built with MACH_KERNEL_PRIVATE)
#      using the kext's own extra defines; registered by Ios12TabletPlatform.
mkdir -p libpthread_kext
cp -R "$WORK/libpthread/kern" "$WORK/libpthread/pthread" "$WORK/libpthread/private" libpthread_kext/
for f in kern_init kern_support kern_synch; do
  mv "libpthread_kext/kern/$f.c" "libpthread_kext/kern/pthread_$f.c"
  grep -q "pthread_$f.c" osfmk/conf/files ||
    printf 'libpthread_kext/kern/pthread_%s.c\t\tstandard\n' "$f" >> osfmk/conf/files
done
if ! grep -q 'PTHREAD_KEXT_FLAGS' osfmk/conf/Makefile.template; then
  perl -0pi -e 's/\n%OBJS\n/\n# ios12-tablet: pthread.kext built in\nPTHREAD_KEXT_FLAGS = -DXNU_KERNEL_PRIVATE -DABSOLUTETIME_SCALAR_TYPE -DNEEDS_SCHED_CALL_T -D__PTHREAD_EXPOSE_INTERNALS__ -Wno-error\nPTHREAD_KEXT_INC = -I\$(SRCROOT)\/libpthread_kext -I\$(SRCROOT)\/libpthread_kext\/private -I\$(SRCROOT)\/bsd\npthread_kern_init.o_CFLAGS_ADD += \$(PTHREAD_KEXT_FLAGS)\npthread_kern_support.o_CFLAGS_ADD += \$(PTHREAD_KEXT_FLAGS)\npthread_kern_synch.o_CFLAGS_ADD += \$(PTHREAD_KEXT_FLAGS)\npthread_kern_init.o_INCFLAGS += \$(PTHREAD_KEXT_INC)\npthread_kern_support.o_INCFLAGS += \$(PTHREAD_KEXT_INC)\npthread_kern_synch.o_INCFLAGS += \$(PTHREAD_KEXT_INC)\n\n%OBJS\n/' \
    osfmk/conf/Makefile.template
fi
grep -n -A9 'pthread.kext built in' osfmk/conf/Makefile.template
tail -4 osfmk/conf/files
perl -0pi -e 's/(\x27IOProbeScore\x27    = 0:32;"\n\s*"   \}")/$1\n    "   ,{"\n    "     \x27IOClass\x27         = Ios12TabletPlatform;"\n    "     \x27IOProviderClass\x27 = IOPlatformExpertDevice;"\n    "     \x27IONameMatch\x27     = (\x27Pi3,1\x27, \x27MT6737T,1\x27);"\n    "     \x27IOProbeScore\x27    = 10000:32;"\n    "   }"/' \
  iokit/KernelConfigTables.cpp
grep -n -A14 'gIOKernelConfigTables =' iokit/KernelConfigTables.cpp
#    - Verbose-boot text: 32-bit console colours have alpha 0x00, which the
#      MT6737's display overlay treats as fully transparent (text invisible).
#      Make every 32-bit console colour opaque.
grep -q 'ios12-tablet: opaque' osfmk/console/video_console.c ||
  perl -0pi -e 's/(\n\tvinfo\.v_rows = vinfo\.v_height \/ ISO_CHAR_HEIGHT;)/\n\t\/* ios12-tablet: opaque 32-bit colours (alpha 0 is transparent on MTK) *\/\n\tfor (int ios12_i = 0; ios12_i < 8; ios12_i++) {\n\t\tvc_colors[ios12_i][2] |= 0xFF000000;\n\t}$1/' \
  osfmk/console/video_console.c
grep -n -B1 -A4 'ios12-tablet: opaque' osfmk/console/video_console.c
#    - IOKit and workqueues use blocks, but the BCM2837 config (unlike
#      MASTER.arm64) never enables the kernel's blocks runtime.
perl -pi -e 's/^(#  LIBKERN_BASE =\s+\[ libkerncpp) (?!config_blocks)/$1 config_blocks /' config/MASTER.arm64.bcm2837
grep -n 'LIBKERN_BASE =' config/MASTER.arm64.bcm2837
#    - assym.s: replace the sed that modern clang output breaks (see script).
cp "$ROOT/scripts/genassym_to_assym.py" tools/genassym_to_assym.py
perl -0pi -e 's/(assym\.s: genassym\.o\n)\t\$\(_v\)sed [^\n]*\n/$1\t\$(_v)python3 \$(SRCROOT)\/tools\/genassym_to_assym.py genassym.o > \$@\n/' \
  osfmk/conf/Makefile.template
grep -n -A1 '^assym.s:' osfmk/conf/Makefile.template
#    - machine/monotonic.h uses MT_CORE_NFIXED even when MONOTONIC is off.
cat >> osfmk/arm64/monotonic.h <<'H'

/* ios12-tablet: fallbacks for configs built without MONOTONIC (e.g. BCM2837). */
#ifndef MT_CORE_NFIXED
#define MT_CORE_CYCLES 0
#define MT_CORE_INSTRS 1
#define MT_CORE_NFIXED 2
#define MT_CORE_MAXVAL ((UINT64_C(1) << 48) - 1)
#endif
H
sed -i '' -E \
  -e "s|^LDFLAGS_KERNEL_SDK[[:space:]]*=.*|LDFLAGS_KERNEL_SDK = -L$FAKEROOT/usr/local/lib/kernel|" \
  -e "s|^INCFLAGS_SDK[[:space:]]*=.*|INCFLAGS_SDK = -I$FAKEROOT/usr/local/include/kernel -I\$(SDKROOT)/usr/local/include/kernel|" \
  makedefs/MakeInc.def
grep -n -E '^(LDFLAGS_KERNEL_SDK|INCFLAGS_SDK|SUPPORTED_ARM64_MACHINE_CONFIGS|USE_WERROR)' makedefs/MakeInc.def
cd "$WORK"
if [ ! -d "$WORK/xnu" ]; then
  mv xnu-staged xnu
  echo "fresh source tree (full build)"
else
  # Copy only files whose content changed, so make rebuilds just those.
  n=0
  while IFS= read -r f; do
    if ! cmp -s "xnu-staged/$f" "xnu/$f"; then
      mkdir -p "xnu/$(dirname "$f")"; cp "xnu-staged/$f" "xnu/$f"
      echo "changed: $f"; n=$((n + 1))
    fi
  done < <(cd xnu-staged && find . -type f)
  echo "$n source file(s) changed since the cached build"
  rm -rf xnu-staged
fi
cd "$ROOT"

# No EmbeddedDeviceMap outside Apple: a stub that answers "arm64", plus the
# arch string passed directly.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\necho arm64\n' > "$WORK/bin/embedded_device_map"
chmod +x "$WORK/bin/embedded_device_map"
COMMON_MAKE_ARGS=(SDKROOT="$SDK" ARCH_STRING_FOR_CURRENT_MACHINE_CONFIG=arm64 USE_WERROR=0
  EMBEDDED_DEVICE_MAP="$WORK/bin/embedded_device_map" EDM_DBPATH=/dev/null
  # Target the A7 / iOS 12 instruction set (ARMv8.0). Left alone, today's
  # Xcode targets the SDK's iOS version and emits ARMv8.1 atomics (casal,
  # ldadd...) that Cortex-A53 doesn't have -> undefined instruction at boot.
  DEPLOYMENT_TARGET_FLAGS="-miphoneos-version-min=12.0"
  ARCH_FLAGS_ARM64="-arch arm64 -mcpu=apple-a7")

# xnu's os_log code includes firehose headers that ship with libdispatch.
# Install them the way libdispatch's Xcode project does: through unifdef with
# the kernel switches, or the KERNEL-only definitions stay switched off.
for d in "$FAKEROOT/usr/local/include/kernel/os" "$FAKEROOT/usr/local/include/os"; do
  mkdir -p "$d"
  for h in "$WORK"/libdispatch/os/*.h; do
    xcrun unifdef -DKERNEL=1 -DOS_FIREHOSE_SPI=1 -DOS_VOUCHER_ACTIVITY_SPI_TYPES=1 \
      -UOS_VOUCHER_ACTIVITY_SPI "$h" > "$d/.tmp.h"
    cmp -s "$d/.tmp.h" "$d/$(basename "$h")" || mv "$d/.tmp.h" "$d/$(basename "$h")"
    rm -f "$d/.tmp.h"
  done
done
ls "$FAKEROOT/usr/local/include/kernel/os" | head

if [ "${REAL_FIREHOSE:-0}" != 1 ] && [ ! -f "$FAKEROOT/usr/local/lib/kernel/libfirehose_kernel.a" ]; then
  # Default: skip the ~6 minute installhdrs + libdispatch build and use the
  # do-nothing firehose library (os_log persistence only; console unaffected).
  # Set REAL_FIREHOSE=1 to attempt the real one.
  stage "libfirehose_kernel: stub (REAL_FIREHOSE=1 to build the real one)"
  printf '%s\n' '#include <stddef.h>' \
    'void *__firehose_buffer_create(size_t *size) { (void)size; return NULL; }' \
    'void *__firehose_buffer_tracepoint_reserve(void) { return NULL; }' \
    'void __firehose_buffer_tracepoint_flush(void) { }' \
    'void __firehose_merge_updates(void) { }' \
    '_Bool __firehose_kernel_configuration_valid(void) { return 1; }' > "$WORK/firehose_stub.c"
  mkdir -p "$FAKEROOT/usr/local/lib/kernel"
  xcrun --sdk "$SDK" clang -arch arm64 -mkernel -mcpu=apple-a7 -O2 -c "$WORK/firehose_stub.c" -o "$WORK/firehose_stub.o" &&
    xcrun libtool -static -o "$FAKEROOT/usr/local/lib/kernel/libfirehose_kernel.a" "$WORK/firehose_stub.o"
fi
if [ -f "$FAKEROOT/usr/local/lib/kernel/libfirehose_kernel.a" ]; then
  stage "headers + libfirehose_kernel: ready"
else
stage "xnu kernel headers into fakeroot"
( cd "$WORK/xnu" && run xnu-headers make -k installhdrs "${COMMON_MAKE_ARGS[@]}" \
    ARCH_CONFIGS="$ARCH_CONFIG" MACHINE_CONFIGS="$MACHINE_CONFIG" KERNEL_CONFIGS="$KERNEL_CONFIG" \
    SRCROOT="$WORK/xnu" OBJROOT="$WORK/build/hdrs.obj" SYMROOT="$WORK/build/hdrs.sym" DSTROOT="$FAKEROOT" )

stage "libfirehose_kernel ($LIBDISPATCH_TAG)"
# firehose_buffer.c includes <internal/atomic.h> (os/internal/atomic.h), a
# libplatform private header. Install libplatform's headers into the fakeroot.
clone libplatform "${LIBPLATFORM_TAG:-libplatform-177.270.1}" "$WORK/libplatform" || clone libplatform "" "$WORK/libplatform"
for d in include private; do
  [ -d "$WORK/libplatform/$d" ] && (cd "$WORK/libplatform/$d" && find . -name '*.h' | cpio -pdm "$FAKEROOT/usr/local/include" 2>/dev/null)
done
ls "$FAKEROOT/usr/local/include/os/internal" 2>/dev/null | head
# xnu's installed kernel headers include <Availability.h> and friends, which a
# real SDK's Kernel.framework provides but installhdrs does not. Borrow them
# from the iOS SDK.
SDK_PATH="$(xcrun --sdk "$SDK" --show-sdk-path)"
for d in Headers PrivateHeaders; do
  KF="$FAKEROOT/System/Library/Frameworks/Kernel.framework/$d"
  [ -d "$KF" ] || continue
  for h in Availability.h AvailabilityInternal.h AvailabilityInternalLegacy.h \
           AvailabilityMacros.h AvailabilityVersions.h TargetConditionals.h; do
    [ -f "$SDK_PATH/usr/include/$h" ] && [ ! -f "$KF/$h" ] && cp "$SDK_PATH/usr/include/$h" "$KF/$h"
  done
  echo "Availability headers in $KF: $(ls "$KF" | grep -c -E '^(Availability|TargetConditionals)')"
done
# Drop includes of Apple-internal xcconfigs that only exist inside Apple.
for f in "$WORK"/libdispatch/xcodeconfig/*.xcconfig; do
  sed -i '' -E '/#include.*(BSD\.xcconfig|AppleInternal)/d' "$f"
done
FH_CFG="$WORK/libdispatch/xcodeconfig/libfirehose_kernel.xcconfig"
if [ -f "$FH_CFG" ]; then
  sed -i '' \
    -e "s|\$(SDKROOT)/System/Library/Frameworks/Kernel.framework/PrivateHeaders|$FAKEROOT/System/Library/Frameworks/Kernel.framework/PrivateHeaders|g" \
    -e "s|\$(SDKROOT)/usr/local/include|$FAKEROOT/usr/local/include|g" "$FH_CFG"
fi
( cd "$WORK/libdispatch" && run firehose xcodebuild install -target libfirehose_kernel -sdk "$SDK" \
    ARCHS=arm64 VALID_ARCHS=arm64 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
    SRCROOT="$WORK/libdispatch" OBJROOT="$WORK/build/fh.obj" SYMROOT="$WORK/build/fh.sym" DSTROOT="$FAKEROOT" )
FH_LIB="$(find "$FAKEROOT" -name 'lib*firehose_kernel.a' | head -1)"
if [ -n "$FH_LIB" ]; then
  mkdir -p "$FAKEROOT/usr/local/lib/kernel"
  cp "$FH_LIB" "$FAKEROOT/usr/local/lib/kernel/libfirehose_kernel.a"
fi
echo "firehose lib: ${FH_LIB:-NOT BUILT}"
if [ -z "$FH_LIB" ]; then
  # Fallback: a do-nothing libfirehose_kernel so the kernel still links.
  # xnu copes: a NULL tracepoint just drops that os_log message; printf and
  # the serial/screen console don't go through firehose at all.
  echo "!!! using STUB libfirehose_kernel (os_log messages will be dropped)"
  cat > "$WORK/firehose_stub.c" <<'C'
#include <stddef.h>
void *__firehose_buffer_create(size_t *size) { (void)size; return NULL; }
void *__firehose_buffer_tracepoint_reserve(void) { return NULL; }
void __firehose_buffer_tracepoint_flush(void) { }
void __firehose_merge_updates(void) { }
_Bool __firehose_kernel_configuration_valid(void) { return 1; }
C
  mkdir -p "$FAKEROOT/usr/local/lib/kernel"
  xcrun --sdk "$SDK" clang -arch arm64 -mkernel -O2 -c "$WORK/firehose_stub.c" -o "$WORK/firehose_stub.o" &&
    xcrun libtool -static -o "$FAKEROOT/usr/local/lib/kernel/libfirehose_kernel.a" "$WORK/firehose_stub.o" &&
    echo "stub library: $FAKEROOT/usr/local/lib/kernel/libfirehose_kernel.a"
fi
fi   # headers + firehose not cached

stage "xnu kernel: $KERNEL_CONFIG $ARCH_CONFIG $MACHINE_CONFIG"
cd "$WORK/xnu"
CTF_ARGS=()
if [ -n "${CTF_BIN:-}" ] && [ "$CTF_BIN" != "." ]; then
  CTF_ARGS=(CTFCONVERT="$CTF_BIN/ctfconvert" CTFMERGE="$CTF_BIN/ctfmerge" CTFINSERT="$CTF_BIN/ctfinsert")
fi
# -k: keep going past failures so one run reports every broken file at once.
# BUILD_LTO=0: link-time optimisation re-compiles the whole kernel at link
# time on every try; without it, an incremental try recompiles only changed files.
run xnu make -k -j"$(sysctl -n hw.ncpu)" install VERBOSE=YES BUILD_LTO=0 \
  "${COMMON_MAKE_ARGS[@]}" \
  KERNEL_CONFIGS="$KERNEL_CONFIG" ARCH_CONFIGS="$ARCH_CONFIG" MACHINE_CONFIGS="$MACHINE_CONFIG" \
  "${CTF_ARGS[@]}" \
  SRCROOT="$WORK/xnu" OBJROOT="$WORK/build/xnu.obj" SYMROOT="$WORK/build/xnu.sym" DSTROOT="$WORK/build/xnu.dst"
XNU_RC=$?

stage "result"
echo "make exit code: $XNU_RC"
grep -h -E '^[^ ]+:[0-9]+:[0-9]+: (fatal )?error:' "$LOGS"/*.log | sort -u > "$LOGS/all-errors.txt" || true
echo "distinct compiler errors: $(wc -l < "$LOGS/all-errors.txt")"
echo "files with errors:"; cut -d: -f1 "$LOGS/all-errors.txt" | sort | uniq -c | sort -rn | head -40
echo "error kinds:"; sed -E 's/.*error: //' "$LOGS/all-errors.txt" | sed -E "s/'[^']*'/'X'/g" | sort | uniq -c | sort -rn | head -25
echo "other failures:"; grep -h -E 'No rule to make|bad interpreter|command not found|\*\*\* \[' "$LOGS"/*.log | grep -v 'Waiting for' | sort -u | head -40 || true
mkdir -p "$ROOT/out"
find -L "$WORK/build/xnu.obj" "$WORK/build/xnu.dst" -maxdepth 4 -type f \
  \( -name 'kernel.*' -o -name 'mach.*.unstripped' \) ! -name '*.dSYM' \
  -exec cp {} "$ROOT/out/" \; 2>/dev/null
[ -d "$WORK/build/xnu.sym" ] && find "$WORK/build/xnu.sym" -maxdepth 1 -name 'kernel*' -type f -exec cp {} "$ROOT/out/" \; 2>/dev/null
ls -la "$ROOT/out"
# The unstripped kernel is what we boot. The later strip/dSYM step needs an
# Apple tool we don't have (make error 127), so don't fail the try for it.
if ls "$ROOT/out"/mach.*.unstripped >/dev/null 2>&1 && [ ! -s "$LOGS/all-errors.txt" ]; then
  echo "KERNEL BUILT OK (ignoring make exit $XNU_RC from the optional strip step)"
  exit 0
fi
exit $XNU_RC
