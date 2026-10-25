---
description: >-
  An agent implements a change by its own ideas. The agent reaches for today's
  tools: Xcode on a Mac, Swift, the current iOS SDK and Go. SafariFix targets
  an iPhone 5 frozen at iOS 10.3.4 and Safari 10.1 on a 32-bit chip, which
  those tools no longer build for, and its browser's web view shares the
  app's 2 GB of address space and its threads with Go. The agent's build
  never runs on the phone, or crashes there. This skill asks the agent to
  implement a change in SafariFix by the steps below.
---

Implement a change in SafariFix:
1. Install docker or podman, curl, git, zip and python3; `tools/deps.sh` then downloads the rest into `build/` at pinned checksums: the iOS 11.4 SDK, the last with 32-bit ARM; the theos project's toolchain (clang, ld64), which runs in an `ubuntu:24.04` container since it needs a newer glibc than this PC's RHEL 8 has; Go 1.14.15, the last Go for 32-bit iPhones; and esbuild v0.28.2.
2. Build the app with `ios/build.sh`, or `DEBUG=1 ios/build.sh` for the debug build, which link the core with `deps_small_go`'s copy of Go; the stock Go reserves 770 MB of the app's address space as it loads, and the web view then runs out of room.
3. Call the core from `ios/app/` only through `OnCore` in `ios/app/main.m`, whose thread never runs JavaScript, since JavaScript's collector crashes the app when it scans a thread mid-way through a Go call.
4. Test the core with `core/go.sh test ./...`, on 32 bits with `GOARCH=386 CGO_ENABLED=0 core/go.sh test ./certs ./fix ./proxy ./rules`, and with `core/go.sh vet ./...`.
5. Put the IPA on the phone and see what the change did there with the phone tools in `tools/phone/`, by the `using-phone-tools` skill.
