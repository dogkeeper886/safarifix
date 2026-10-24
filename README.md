# SafariFix

Safari 10.1 on an iPhone 5 (iOS 10.3.4) still searches Google and plays YouTube, but many other sites now send JavaScript it can't parse, or call web APIs it lacks, and their pages stay blank or half-working.

SafariFix is an app on the phone that runs a fixing proxy for Safari. It rewrites new JavaScript syntax, adds the missing APIs, and leaves Google and YouTube untouched. It needs no jailbreak and no PC while browsing, and a free Apple ID signs it, as with CleanCam.

**Status:** SafariFix runs on the iPhone 5 and fixes Safari's pages there, with no PC while browsing. On the phone, BBC, Yahoo News, Amazon and Wikipedia load with their scripts rewritten, while Google search and YouTube pass through, and Google's sign-in gets the `AbortController` it needs.

## Build and install

1. Build the app on a Linux PC with podman or docker: `ios/build.sh` writes `build/SafariFix.ipa`, downloading the pinned Go 1.14, iOS SDK and toolchain once.
2. Sign and install it with a free Apple ID through [CleanCam](https://github.com/dogkeeper886/cleancam)'s `tools/plumesign.sh`: `tools/plumesign.sh sign --package build/SafariFix.ipa --apple-id --register-and-install --udid <the iPhone's UDID>`. The signature lasts 7 days.
3. On the iPhone, open SafariFix and follow its screen. Point Wi-Fi's HTTP Proxy at `http://127.0.0.1:8118/proxy.pac`, install the root certificate from the setup page, and turn its switch on in Settings → General → About → Certificate Trust Settings.

## The repo

- `core/`: the proxy in Go 1.14, with its tests; `core/go.sh run ./cmd/safarifix-pc` runs it on a PC for the iPhone to use over the WiFi.
- `ios/`: the app around the core, and its build script.
- `tools/`: drives Safari on the phone from a Linux PC, and downloads the pinned build tools.
- `bench/` and `spike/`: the first tests of the fixes on a PC and of each part on the phone.
- `.claude/skills/studying-iphone5-safari/`: the flow for studying why a site fails.
