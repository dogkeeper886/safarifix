#!/usr/bin/env bash
# The C compiler for the iPhone 5 on iOS 10, which Go's cgo calls for darwin/arm and ios/build.sh calls for the app:
# the theos toolchain's clang, against the iOS 11.4 SDK. ios/build.sh sets CLANG and SDK.
exec "$CLANG" -target armv7-apple-ios10.0 -isysroot "$SDK" "$@"
