---
description: >-
  An agent works on SafariFix from a Linux PC with the iPhone 5 on a USB
  cable. Signing, installing and studying an iOS 10 phone takes a signer,
  libimobiledevice and an inspector proxy at versions this PC lacks, and an
  Apple ID only the user can log in to. The agent installs tools on the host
  by its own ideas, can't put the app on the phone or see what a page did,
  and can leave the phone's inspector open to the network or its owner's
  data in chat. This skill asks the agent to use the phone tools in
  tools/phone/ by the steps below.
---

Use the phone tools in tools/phone/:
1. Run `tools/phone/install.sh` until it says "Ready": it downloads the pinned signer into `build/`, builds the `iphone-tools` image, and names what's missing.
2. Ask the user to plug the iPhone straight into the PC, unlock it and tap "Trust This Computer" when `install.sh` finds no paired iPhone.
3. Ask the user to run `tools/phone/plumesign.sh account login -u <Apple ID>` in their own terminal when `install.sh` finds no Apple ID, since it asks for the password and the code.
4. Sign and install an IPA over the installed app with `tools/phone/plumesign.sh sign --package <IPA> --apple-id --register-and-install --udid "$(tools/phone/iphone.sh idevice_id -l < /dev/null | head -1)" < /dev/null`, never uninstalling SafariFix first, since its data holds the root key Safari trusts and the browser's sign-ins.
5. Ask the user to tap Verify App in Settings → General → Device Management when the app won't open after an install.
6. Start the inspector, the log recorder and the USB forward to the app's debug record with `tools/phone/run.sh`, again after each replug of the phone.
7. Check what runs, the phone's iOS, its web pages and the debug record with `tools/phone/status.sh`.
8. Drive a page with `tools/phone/iphone.sh python3 tools/phone/probe.py`, adding `--ws ws://localhost:9222/devtools/page/<n>` from `status.sh` for SafariFix's browser once it has loaded a page.
9. Read the app's debug record from `http://127.0.0.1:18118/debug/`: `log.txt`, `summary.txt`, `core.txt` and `previous.txt`.
10. Read the phone's log with `tools/phone/log.sh | grep SafariFix`.
11. Keep the phone's log, its name, its UDID, its pages' addresses and the Apple ID out of commits and chat, and never read a form field's value.
12. Rebuild the image with `tools/phone/build.sh` after a change to `tools/phone/image/`.
13. Stop the tools with `tools/phone/stop.sh` when the work is done.
