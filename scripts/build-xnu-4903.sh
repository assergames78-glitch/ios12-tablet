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
clone xnu "$XNU_TAG" "$WORK/xnu"
clone dtrace "" "$WORK/dtrace"
clone AvailabilityVersions "" "$WORK/AvailabilityVersions"
clone libdispatch "$LIBDISPATCH_TAG" "$WORK/libdispatch" || clone libdispatch "" "$WORK/libdispatch"
( cd "$WORK/xnu" && git log -1 --oneline )

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
cd "$WORK/xnu"
# 1. Apple's style checker (tools/uncrustify.sh) is not in the public source.
sed -i '' 's/^\(install:.*\) checkstyle$/\1/' makedefs/MakeInc.top
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
[ -n "${AVAIL_PL:-}" ] && sed -i '' "s|^AVAILABILITY_PL=.*|AVAILABILITY_PL=\"$AVAIL_PL\"|" bsd/sys/make_symbol_aliasing.sh
sed -i '' \
  -e "s|^LDFLAGS_KERNEL_SDK *=.*|LDFLAGS_KERNEL_SDK = -L$FAKEROOT/usr/local/lib/kernel|" \
  -e "s|^INCFLAGS_SDK *=.*|INCFLAGS_SDK = -I$FAKEROOT/usr/local/include/kernel -I\$(SDKROOT)/usr/local/include/kernel|" \
  makedefs/MakeInc.def
grep -n -E '^(LDFLAGS_KERNEL_SDK|INCFLAGS_SDK|SUPPORTED_ARM64_MACHINE_CONFIGS|USE_WERROR)' makedefs/MakeInc.def
git status --short
cd "$ROOT"

# No EmbeddedDeviceMap outside Apple: tell make the arch string directly.
COMMON_MAKE_ARGS=(SDKROOT="$SDK" ARCH_STRING_FOR_CURRENT_MACHINE_CONFIG=arm64 USE_WERROR=0)

stage "xnu kernel headers into fakeroot"
( cd "$WORK/xnu" && run xnu-headers make installhdrs "${COMMON_MAKE_ARGS[@]}" \
    ARCH_CONFIGS="$ARCH_CONFIG" MACHINE_CONFIGS="$MACHINE_CONFIG" KERNEL_CONFIGS="$KERNEL_CONFIG" \
    SRCROOT="$WORK/xnu" OBJROOT="$WORK/build/hdrs.obj" SYMROOT="$WORK/build/hdrs.sym" DSTROOT="$FAKEROOT" )

stage "libfirehose_kernel ($LIBDISPATCH_TAG)"
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

stage "xnu kernel: $KERNEL_CONFIG $ARCH_CONFIG $MACHINE_CONFIG"
cd "$WORK/xnu"
CTF_ARGS=()
if [ -n "${CTF_BIN:-}" ] && [ "$CTF_BIN" != "." ]; then
  CTF_ARGS=(CTFCONVERT="$CTF_BIN/ctfconvert" CTFMERGE="$CTF_BIN/ctfmerge" CTFINSERT="$CTF_BIN/ctfinsert")
fi
# -k: keep going past failures so one run reports every broken file at once.
run xnu make -k -j"$(sysctl -n hw.ncpu)" install VERBOSE=YES \
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
find "$WORK/build/xnu.obj" -maxdepth 2 -name 'kernel*' -type f -exec cp {} "$ROOT/out/" \; 2>/dev/null
ls -la "$ROOT/out"
exit $XNU_RC
