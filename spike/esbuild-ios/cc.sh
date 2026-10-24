#!/usr/bin/env bash
# The C compiler Go's cgo calls for darwin/arm: the theos toolchain's clang for the iPhone 5 on iOS 10,
# against the iOS 11.4 SDK. build.sh sets CLANG and SDK.
exec "$CLANG" -target armv7-apple-ios10.0 -isysroot "$SDK" "$@"
