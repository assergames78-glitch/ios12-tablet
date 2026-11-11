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
( cd "$WORK/dtrace" && run dtrace xcodebuild install -sdk macosx \
    -target ctfconvert -target ctfdump -target ctfmerge \
    ARCHS="$(uname -m)" CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
    SRCROOT="$WORK/dtrace" OBJROOT="$WORK/build/dtrace.obj" SYMROOT="$WORK/build/dtrace.sym" \
    DSTROOT="$FAKEROOT" )
CTF_BIN="$(dirname "$(find "$FAKEROOT" -name ctfmerge -type f | head -1)")"
echo "ctf tools in: ${CTF_BIN:-NOT BUILT}"

stage "AvailabilityVersions"
( cd "$WORK/AvailabilityVersions" && run availability make install \
    OBJROOT="$WORK/build/av.obj/" SYMROOT="$WORK/build/av.sym/" DSTROOT="$FAKEROOT" )
AVAIL_PL="$(find "$FAKEROOT" -name availability.pl | head -1)"
echo "availability.pl: ${AVAIL_PL:-NOT FOUND}"

stage "xnu kernel headers into fakeroot"
( cd "$WORK/xnu" && run xnu-headers make installhdrs SDKROOT="$SDK" ARCH_CONFIGS="$ARCH_CONFIG" \
    SRCROOT="$WORK/xnu" OBJROOT="$WORK/build/hdrs.obj" SYMROOT="$WORK/build/hdrs.sym" DSTROOT="$FAKEROOT" \
    USE_WERROR=0 )

stage "libfirehose_kernel ($LIBDISPATCH_TAG)"
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

stage "patch xnu makefiles to use the fakeroot"
cd "$WORK/xnu"
[ -n "${AVAIL_PL:-}" ] && sed -i '' "s|^AVAILABILITY_PL=.*|AVAILABILITY_PL=\"$AVAIL_PL\"|" bsd/sys/make_symbol_aliasing.sh
sed -i '' \
  -e "s|^LDFLAGS_KERNEL_SDK *=.*|LDFLAGS_KERNEL_SDK = -L$FAKEROOT/usr/local/lib/kernel|" \
  -e "s|^INCFLAGS_SDK *=.*|INCFLAGS_SDK = -I$FAKEROOT/usr/local/include/kernel -I\$(SDKROOT)/usr/local/include/kernel|" \
  makedefs/MakeInc.def
grep -n -E '^(LDFLAGS_KERNEL_SDK|INCFLAGS_SDK|SUPPORTED_ARM64_MACHINE_CONFIGS|USE_WERROR)' makedefs/MakeInc.def
git diff --stat

stage "xnu kernel: $KERNEL_CONFIG $ARCH_CONFIG $MACHINE_CONFIG"
CTF_ARGS=()
if [ -n "${CTF_BIN:-}" ] && [ "$CTF_BIN" != "." ]; then
  CTF_ARGS=(CTFCONVERT="$CTF_BIN/ctfconvert" CTFMERGE="$CTF_BIN/ctfmerge" CTFINSERT="$CTF_BIN/ctfinsert")
fi
run xnu make -j"$(sysctl -n hw.ncpu)" install VERBOSE=YES \
  SDKROOT="$SDK" \
  KERNEL_CONFIGS="$KERNEL_CONFIG" ARCH_CONFIGS="$ARCH_CONFIG" MACHINE_CONFIGS="$MACHINE_CONFIG" \
  ARCH_STRING_FOR_CURRENT_MACHINE_CONFIG=arm64 \
  USE_WERROR=0 \
  "${CTF_ARGS[@]}" \
  SRCROOT="$WORK/xnu" OBJROOT="$WORK/build/xnu.obj" SYMROOT="$WORK/build/xnu.sym" DSTROOT="$WORK/build/xnu.dst"
XNU_RC=$?

stage "result"
echo "make exit code: $XNU_RC"
echo "first errors:"; grep -n -m 40 -E 'error:|Error [0-9]|No rule to make|not found' "$LOGS/xnu.log" || true
mkdir -p "$ROOT/out"
find "$WORK/build/xnu.obj" -maxdepth 2 -name 'kernel*' -type f -exec cp {} "$ROOT/out/" \; 2>/dev/null
ls -la "$ROOT/out"
exit $XNU_RC
