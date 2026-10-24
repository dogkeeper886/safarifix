#!/usr/bin/env bash
# Builds SafariFix for the iPhone 5 on iOS 10 into build/SafariFix.ipa, unsigned; sign and install it with CleanCam's
# tools/plumesign.sh. The core builds with Go 1.14, the last Go for 32-bit iPhones, as a C library that links into
# the Objective-C app in ios/app/.
# Runs on Linux: Go, and clang and Apple's ld64 from the theos project's iOS toolchain, run in a container against
# the iOS 11.4 SDK. Everything downloads once into build/ (see tools/deps.sh).
# Needs podman or docker, curl, git and zip.
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/deps.sh
deps_go
deps_esbuild
deps_ios
# Generates the polyfills and the root bundle the core embeds.
core/go.sh version >/dev/null

OUT=build/safarifix-ios
APP=$OUT/Payload/SafariFix.app
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

rm -rf "$OUT" build/SafariFix.ipa
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
    $PWD/$GO build -buildmode=c-archive -o $PWD/$OUT/libsafarifix.a ./ios
    cd ..
    # The Go runtime and the core's net and crypto packages need CoreFoundation, Security and libresolv.
    ios/cc.sh -fobjc-arc -O2 -Wall -I $OUT ios/app/*.m $OUT/libsafarifix.a \
      -framework Foundation -framework UIKit -framework AVFoundation -framework QuartzCore -framework CoreGraphics \
      -framework CoreFoundation -framework Security -lresolv -o $APP/SafariFix
  "

cp ios/app/Info.plist "$APP/"
(cd "$OUT" && zip -qr ../SafariFix.ipa Payload)
echo "Built build/SafariFix.ipa; the core: $(du -h "$OUT/libsafarifix.a" | cut -f1), the app: $(du -h "$APP/SafariFix" | cut -f1)"
