# Downloads the pinned tools and sources SafariFix builds from, once, into build/, checking each against a pinned
# checksum or commit. Source it from the repo root, then call what the build needs:
#   deps_go        Go 1.14.15, the last Go for 32-bit iPhones            sets GO
#   deps_small_go  Go 1.14.15 reserving less address space, for the app  sets SMALL_GO
#   deps_esbuild   esbuild v0.28.2                                        into build/src/esbuild
#   deps_ios       the iOS 11.4 SDK and the theos project's toolchain      sets SDK and CLANG
#   deps_npm       core-js and the IntersectionObserver, ResizeObserver polyfills, through npm in a container
#                                                                         into build/npm/node_modules
#   deps_roots     curl's copy of the Mozilla root certificates           sets ROOTS
# Needs curl, git, and podman or docker for deps_npm.

GO=build/go1.14.15/go/bin/go
SMALL_GO=build/go1.14.15-small/go/bin/go
SDK=build/legacy-tools/iPhoneOS11.4.sdk
CLANG=build/legacy-tools/linux/iphone/bin/clang
ROOTS=build/cacert-2026-09-25.pem
# Go keeps its module and build caches inside build/, not in the user's home.
export GOPATH=$PWD/build/gopath GOCACHE=$PWD/build/gocache GOFLAGS=-mod=mod

# deps_fetch URL SHA256 DIR: downloads a tarball, checks it and unpacks it into DIR.
deps_fetch() {
  local file=build/${1##*/}
  mkdir -p "$3"
  curl -fL --retry 3 -o "$file" "$1"
  echo "$2  $file" | sha256sum -c --quiet -
  tar -xf "$file" -C "$3"
  rm "$file"
}

deps_go() {
  [[ -x $GO ]] || deps_fetch https://go.dev/dl/go1.14.15.linux-amd64.tar.gz \
    c64a57b374a81f7cf1408d2c410a28c6f142414f1ffa9d1062de1d653b0ae0d6 build/go1.14.15
}

# Go 1.14 reserves 770 MB of a 32-bit app's 2 GB as it loads: 258 MB for heap bookkeeping and 512 MB of heap, far
# more than the core uses, and the app's web view then runs out of room. The copy reserves 4 MB and 64 MB; past
# those, Go's heap and bookkeeping grow where the system finds room, as they already do once full.
deps_small_go() {
  deps_go
  [[ -x $SMALL_GO ]] && return
  local runtime=build/go1.14.15-small/go/src/runtime/malloc.go
  rm -rf build/go1.14.15-small
  mkdir -p build/go1.14.15-small
  # Links, not copies; sed writes the one changed file anew.
  cp -al build/go1.14.15/go build/go1.14.15-small/
  sed -i -e 's/const arenaMetaSize = (1 << arenaBits) \* unsafe.Sizeof(heapArena{})/const arenaMetaSize = 16 * unsafe.Sizeof(heapArena{})/' \
    -e 's/^\t\t\t512 << 20,$/\t\t\t64 << 20,/' -e 's/^\t\t\t256 << 20,$/\t\t\t32 << 20,/' \
    -e 's/^\t\t\t128 << 20,$/\t\t\t16 << 20,/' "$runtime"
  if [[ $(grep -cP 'arenaMetaSize = 16 \*|^\t\t\t(64|32|16) << 20,$' "$runtime") != 4 ]]; then
    rm -rf build/go1.14.15-small
    echo "Couldn't patch Go's reservations in $runtime." >&2
    return 1
  fi
}

deps_esbuild() {
  local src=build/src/esbuild
  [[ -d $src ]] || git clone -q --depth 1 --branch v0.28.2 https://github.com/evanw/esbuild "$src"
  if [[ $(git -C "$src" rev-parse HEAD) != 609683d892977362a0f99026cb74b96263d728a9 ]]; then
    echo "$src is not esbuild v0.28.2 (609683d); delete it and run again." >&2
    return 1
  fi
}

# The SDK and toolchain are CleanCamLegacy's, at the same pinned checksums.
deps_ios() {
  [[ -d $SDK ]] || deps_fetch https://github.com/theos/sdks/releases/download/master-146e41f/iPhoneOS11.4.sdk.tar.xz \
    fb77df55f2478d5d8e069e2686123f2540642128d4c1ad749db3f0b474fae5fb build/legacy-tools
  [[ -x $CLANG ]] || deps_fetch https://github.com/L1ghtmann/llvm-project/releases/download/main-update_3-eabca92/iOSToolchain-x86_64.tar.xz \
    cc9fbc7f8a3f9336f926cd4fb7cc2233a17b2ba40504cc8c0ff3211bd9df27e3 build/legacy-tools
  # The toolchain's ar runs ranlib under the toolchain's build name, which the toolchain doesn't ship.
  ln -sf ranlib build/legacy-tools/linux/iphone/bin/aarch64-apple-darwin14-ranlib
}

deps_npm() {
  [[ -f build/npm/node_modules/resize-observer-polyfill/dist/ResizeObserver.global.js ]] && return
  local runtime user
  runtime=$(command -v podman || command -v docker || true)
  if [[ -z $runtime ]]; then
    echo "Install podman or docker; npm runs in a container." >&2
    return 1
  fi
  if [[ $runtime == *podman ]]; then user=(--userns=keep-id); else user=(--user "$(id -u):$(id -g)"); fi
  mkdir -p build/npm
  # npm checks each package against the registry's integrity hash.
  "$runtime" run --rm --security-opt label=disable "${user[@]}" -e HOME=/tmp -v "$PWD/build/npm:/npm" -w /npm \
    docker.io/library/node:22-bookworm-slim npm install --no-audit --no-fund \
    core-js-bundle@3.50.0 intersection-observer@0.12.2 resize-observer-polyfill@1.5.1 >/dev/null
}

deps_roots() {
  [[ -f $ROOTS ]] && return
  curl -fL --retry 3 -o "$ROOTS" https://curl.se/ca/cacert-2026-09-25.pem
  echo "a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505  $ROOTS" | sha256sum -c --quiet -
}
