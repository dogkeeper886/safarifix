#!/usr/bin/env bash
# The esbuild build test: compiles esbuild v0.28.2 with Go 1.14, the last Go release for 32-bit iPhones,
# into a test app for the iPhone 5 that times esbuild on sample scripts. Writes build/esbuild-test.ipa,
# unsigned; sign and install it with tools/phone/plumesign.sh.
#   spike/esbuild-ios/build.sh [SAMPLE.js ...]   the scripts to time (default: three.js 0.170.0's module build)
# Runs on Linux: Go, and clang and Apple's ld64 from the theos project's iOS toolchain, run in a container,
# against the iOS 11.4 SDK, the last with 32-bit ARM. All of them download once into build/.
# Needs podman or docker, curl, git and zip.
set -euo pipefail
cd "$(dirname "$0")/../.."

TOOLS=build/legacy-tools
SDK=$TOOLS/iPhoneOS11.4.sdk
CLANG=$TOOLS/linux/iphone/bin/clang
GOROOT_DIR=build/go1.14.15
ESBUILD_SRC=build/src/esbuild
OUT=build/esbuild-test
APP=$OUT/Payload/EsbuildTest.app

# fetch URL SHA256 DIR: downloads a tarball, checks it and unpacks it into DIR.
fetch() {
  local file=build/${1##*/}
  mkdir -p "$3"
  curl -fL --retry 3 -o "$file" "$1"
  echo "$2  $file" | sha256sum -c --quiet -
  tar -xf "$file" -C "$3"
  rm "$file"
}
# The SDK and toolchain are CleanCamLegacy's, at the same pinned checksums.
[[ -d $SDK ]] || fetch https://github.com/theos/sdks/releases/download/master-146e41f/iPhoneOS11.4.sdk.tar.xz \
  fb77df55f2478d5d8e069e2686123f2540642128d4c1ad749db3f0b474fae5fb "$TOOLS"
[[ -x $CLANG ]] || fetch https://github.com/L1ghtmann/llvm-project/releases/download/main-update_3-eabca92/iOSToolchain-x86_64.tar.xz \
  cc9fbc7f8a3f9336f926cd4fb7cc2233a17b2ba40504cc8c0ff3211bd9df27e3 "$TOOLS"
# The toolchain's ar runs ranlib under the toolchain's build name, which the toolchain doesn't ship.
ln -sf ranlib "$TOOLS/linux/iphone/bin/aarch64-apple-darwin14-ranlib"
[[ -x $GOROOT_DIR/go/bin/go ]] || fetch https://go.dev/dl/go1.14.15.linux-amd64.tar.gz \
  c64a57b374a81f7cf1408d2c410a28c6f142414f1ffa9d1062de1d653b0ae0d6 "$GOROOT_DIR"
if [[ ! -d $ESBUILD_SRC ]]; then
  git clone -q --depth 1 --branch v0.28.2 https://github.com/evanw/esbuild "$ESBUILD_SRC"
fi
[[ $(git -C "$ESBUILD_SRC" rev-parse HEAD) == 609683d892977362a0f99026cb74b96263d728a9 ]] || {
  echo "$ESBUILD_SRC is not esbuild v0.28.2 (609683d); delete it and run again." >&2
  exit 1
}

SAMPLES=("$@")
if [[ ${#SAMPLES[@]} -eq 0 ]]; then
  mkdir -p build/samples
  [[ -f build/samples/three.module.js ]] ||
    curl -fL --retry 3 -o build/samples/three.module.js https://cdn.jsdelivr.net/npm/three@0.170.0/build/three.module.js
  SAMPLES=(build/samples/three.module.js)
fi

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
CA=
for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
  [[ -f $f ]] && { CA=$f; break; }
done

rm -rf "$OUT" build/esbuild-test.ipa
mkdir -p "$APP/samples"
# Go fetches esbuild's one dependency, golang.org/x/sys, through its module proxy, hence the CA bundle.
# The toolchain's bin comes first on PATH so Go packs the library with its Mach-O ar.
"$RUNTIME" run --rm --security-opt label=disable "${USER_OPTS[@]}" -v "$PWD:$PWD" -w "$PWD" \
  ${CA:+-v "$CA:/etc/ssl/certs/ca-certificates.crt:ro"} \
  -e HOME=/tmp -e GOPATH="$PWD/build/gopath" -e GOCACHE="$PWD/build/gocache" \
  -e GOOS=darwin -e GOARCH=arm -e GOARM=7 -e CGO_ENABLED=1 \
  -e CC="$PWD/spike/esbuild-ios/cc.sh" -e CLANG="$PWD/$CLANG" -e SDK="$PWD/$SDK" \
  -e PATH="$PWD/$TOOLS/linux/iphone/bin:/usr/bin:/bin" \
  docker.io/library/ubuntu:24.04 bash -c "
    set -e
    cd spike/esbuild-ios
    $PWD/$GOROOT_DIR/go/bin/go build -buildmode=c-archive -o $PWD/$OUT/libesbuild.a .
    cd $PWD
    # The Go runtime and esbuild's net package need CoreFoundation, Security and libresolv.
    $PWD/spike/esbuild-ios/cc.sh -fobjc-arc -O2 -Wall -I $OUT spike/esbuild-ios/app/main.m $OUT/libesbuild.a \
      -framework Foundation -framework UIKit -framework QuartzCore -framework CoreFoundation -framework Security \
      -lresolv -o $APP/EsbuildTest
  "

cp spike/esbuild-ios/app/Info.plist "$APP/"
cp "${SAMPLES[@]}" "$APP/samples/"
(cd "$OUT" && zip -qr ../esbuild-test.ipa Payload)
echo "Built build/esbuild-test.ipa with $(ls "$APP/samples" | wc -l) sample(s); esbuild part: $(du -h "$OUT/libesbuild.a" | cut -f1)"
