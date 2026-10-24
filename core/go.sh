#!/usr/bin/env bash
# Runs Go 1.14 in core/, after generating what Go 1.14 can't embed: fix/polyfills_gen.go from the npm polyfills
# and proxy/roots_gen.go from curl's Mozilla roots. Downloads both and Go itself on first use.
#   core/go.sh test ./...
#   core/go.sh run ./cmd/safarifix-pc        the core on the PC, for the iPhone to use over the WiFi
#   GOARCH=386 CGO_ENABLED=0 core/go.sh test ./certs ./fix ./proxy ./rules
#                                            the tests on 32 bits, which catch what crashes the iPhone 5
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/deps.sh
deps_go
deps_esbuild
GO=$PWD/$GO
M=$PWD/build/npm/node_modules
ROOTS=$PWD/$ROOTS
if [[ ! -f core/fix/polyfills_gen.go ]]; then
  deps_npm
  (cd core && "$GO" run ./internal/gen -pkg fix -name vendorPolyfills -sep '\n;\n' -out fix/polyfills_gen.go \
    "$M/core-js-bundle/minified.js" "$M/intersection-observer/intersection-observer.js" \
    "$M/resize-observer-polyfill/dist/ResizeObserver.global.js")
fi
if [[ ! -f core/proxy/roots_gen.go ]]; then
  deps_roots
  (cd core && "$GO" run ./internal/gen -pkg proxy -name mozillaRoots -out proxy/roots_gen.go "$ROOTS")
fi
cd core
exec "$GO" "$@"
