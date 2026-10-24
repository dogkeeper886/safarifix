---
description: >-
  An agent implements a change by its own ideas. The agent reaches for today's
  tools: Xcode on a Mac, Swift, the current iOS SDK and Go. SafariFix targets
  an iPhone 5 frozen at iOS 10.3.4 and Safari 10.1 on a 32-bit chip, which
  those tools no longer build for. The agent's build never runs on the phone.
  This skill asks the agent to implement a change in SafariFix by the steps
  below.
---

Implement a change in SafariFix:
1. The iPhone 5 is frozen at iOS 10.3.4 and Safari 10.1 on a 32-bit armv7s chip, so install the iOS 11.4 SDK, the last SDK with 32-bit ARM, and the theos project's iOS toolchain (clang 19, ld64-956.6). `spike/proxy-ios/build.sh` pins both by URL and sha256 and downloads them into `build/legacy-tools/` on its first run.
2. Install docker or podman, curl, git and zip to build the phone app's IPA with `spike/*/build.sh`. The script runs the toolchain from step 1 in an `ubuntu:24.04` container, since its Linux binaries need a newer glibc than this PC's RHEL 8 has (2.28). It fetches the downloads with curl, clones esbuild with git, and packs `Payload/<App>.app` into the IPA with zip.
3. Install Go 1.14.15 to build esbuild v0.28.2 into the phone app as a C library, since 1.14 is the last Go for 32-bit iPhones. `spike/esbuild-ios/build.sh` pins both, and `go.mod` swaps in an older `golang.org/x/sys` that still supports 32-bit iPhones.
