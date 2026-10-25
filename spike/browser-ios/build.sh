#!/usr/bin/env bash
# The browser test: builds a test app for the iPhone 5 with a bare browser in a UIWebView, whose every request goes
# through the SafariFix core inside the app, with no Wi-Fi proxy setting or trusted certificate. Writes
# build/browser-test.ipa, unsigned; sign and install it with CleanCam's tools/plumesign.sh.
# Builds the core as ios/build.sh does: Go 1.14 as a C library, and the theos toolchain against the iOS 11.4 SDK, in
# a container. Needs podman or docker, curl, git, zip and python3.
set -euo pipefail
cd "$(dirname "$0")/../.."
source tools/deps.sh
deps_go
deps_esbuild
deps_ios
# Generates the polyfills and the root bundle the core embeds.
core/go.sh version >/dev/null

# Go 1.14 reserves 770 MB of a 32-bit app's 2 GB as it loads: 258 MB for heap bookkeeping and 512 MB of heap, far more
# than the core uses, and the web view then runs out of room. The test builds with a copy of Go that reserves 4 MB and
# 64 MB; past those, Go's heap and bookkeeping grow where the system finds room, as they already do once full.
SMALL_GO=build/go1.14.15-small/go
if [[ ! -x $SMALL_GO/bin/go ]]; then
  rm -rf build/go1.14.15-small
  mkdir -p build/go1.14.15-small
  # Links, not copies; sed writes the one changed file anew.
  cp -al "$(dirname "$(dirname "$GO")")" build/go1.14.15-small/
  sed -i -e 's/const arenaMetaSize = (1 << arenaBits) \* unsafe.Sizeof(heapArena{})/const arenaMetaSize = 16 * unsafe.Sizeof(heapArena{})/' \
    -e 's/^\t\t\t512 << 20,$/\t\t\t64 << 20,/' -e 's/^\t\t\t256 << 20,$/\t\t\t32 << 20,/' \
    -e 's/^\t\t\t128 << 20,$/\t\t\t16 << 20,/' "$SMALL_GO/src/runtime/malloc.go"
  if [[ $(grep -cP 'arenaMetaSize = 16 \*|^\t\t\t(64|32|16) << 20,$' "$SMALL_GO/src/runtime/malloc.go") != 4 ]]; then
    rm -rf build/go1.14.15-small
    echo "Couldn't patch Go's reservations in malloc.go." >&2
    exit 1
  fi
fi

OUT=build/browser-test
APP=$OUT/Payload/BrowserTest.app
RUNTIME=$(command -v podman || command -v docker || true)
if [[ -z $RUNTIME ]]; then
  echo "Install podman or docker; the toolchain runs in a container." >&2
  exit 1
fi
# Run as the calling user so the build output stays theirs.
if [[ $RUNTIME == *podman ]]; then
  USER_OPTS=(--userns=keep-id)
else
  USER_OPTS=(--user "$(id -u):$(id -g)")
fi

rm -rf "$OUT" build/browser-test.ipa
mkdir -p "$APP"
# The toolchain's bin comes first on PATH so Go packs the library with its Mach-O ar.
"$RUNTIME" run --rm --security-opt label=disable "${USER_OPTS[@]}" -v "$PWD:$PWD" -w "$PWD" \
  -e HOME=/tmp -e GOPATH -e GOCACHE -e GOFLAGS \
  -e GOOS=darwin -e GOARCH=arm -e GOARM=7 -e CGO_ENABLED=1 \
  -e CC="$PWD/ios/cc.sh" -e CLANG="$PWD/$CLANG" -e SDK="$PWD/$SDK" \
  -e PATH="$PWD/build/legacy-tools/linux/iphone/bin:/usr/bin:/bin" \
  docker.io/library/ubuntu:24.04 bash -c "
    set -e
    cd core
    $PWD/$SMALL_GO/bin/go build -buildmode=c-archive -o $PWD/$OUT/libsafarifix.a ./ios
    cd ..
    ios/cc.sh -fobjc-arc -O2 -Wall -I $OUT -I ios/app spike/browser-ios/app/*.m ios/app/SFDetailsViewController.m $OUT/libsafarifix.a \
      -framework Foundation -framework UIKit -framework JavaScriptCore -framework CoreFoundation -framework CFNetwork -framework Security \
      -lresolv -o $APP/BrowserTest
  "

cp spike/browser-ios/app/Info.plist "$APP/"
python3 tools/launch-image.py "$APP" f7f7f7
(cd "$OUT" && zip -qr ../browser-test.ipa Payload)
echo "Built build/browser-test.ipa"
