# SafariFix

Safari 10.1 on an iPhone 5 (iOS 10.3.4) still searches Google and plays YouTube, but many other sites now send JavaScript it can't parse, or call web APIs it lacks, and their pages stay blank or half-working.

SafariFix is to be an app on the phone that runs a fixing proxy for Safari. It rewrites new JavaScript syntax, adds the missing APIs, and leaves Google and YouTube untouched. It needs no jailbreak and no PC while browsing, and a free Apple ID signs it, as with CleanCam.

**Status:** the proxy's core works; the app around it is next. `core/` is the core in Go 1.14, which `core/go.sh run ./cmd/safarifix-pc` runs on a PC for the iPhone to use over the WiFi. `tools/` drives Safari on the phone from a Linux PC, `bench/` was the first fix test on the PC, `spike/` holds build tests for the phone, and `.claude/skills/studying-iphone5-safari/` holds the study flow.
