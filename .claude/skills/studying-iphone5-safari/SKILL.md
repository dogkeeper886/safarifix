---
description: >-
  An agent studies why a site fails in the iPhone 5's Safari by its own ideas.
  The phone runs Safari 10.1 on iOS 10.3.4, while the agent works from a Linux
  PC with no Mac, no view of the phone's screen and no Safari of that age. A
  guess made from the PC blames TLS, a root certificate or the user agent
  while the page fails on new syntax or a missing API, and the fix lands in
  the wrong layer. This skill asks the agent to measure the failure on the
  phone itself by the steps below.
---

Study a site's failure in the iPhone 5's Safari:
1. Run every phone tool through `tools/iphone.sh`, which builds the `iphone-tools` image on first use: libimobiledevice 1.3.0, ideviceinstaller and ios-webkit-debug-proxy v1.9.2 on Ubuntu 24.04, reaching the phone through the host's usbmuxd socket.
2. Ask the user to plug the iPhone straight into the PC, since behind a USB hub usbmuxd claims the phone but lists no device.
3. Confirm the link with `tools/iphone.sh idevice_id -l`.
4. Ask the user to unlock the phone and tap "Trust This Computer" when `tools/iphone.sh idevicepair validate` fails.
5. Compare the phone's clock, `tools/iphone.sh ideviceinfo -k TimeIntervalSince1970`, with `date -u +%s`, since a wrong date fails every HTTPS site at once.
6. Ask the user to turn on Settings → Safari → Advanced → Web Inspector, at the bottom of Safari's settings.
7. Ask the user to open Safari on one tab, keep it in front, and set Settings → Display & Brightness → Auto-Lock to Never, since a locked or background Safari stops answering.
8. Start the inspector and the log recorder with `tools/inspect.sh start`, which ends by listing Safari's tabs.
9. Run one inspector client at a time, since a second connection to the tab drops the first.
10. Probe one site with `tools/iphone.sh python3 tools/probe.py <url>`, which opens it in the tab, watches it for 20 seconds and prints the failed requests, the console errors and the page text.
11. Probe several sites with `tools/iphone.sh python3 tools/probe.py --summary <url> ...`, a short block per site.
12. Test a web API on the page with `--eval 'typeof IntersectionObserver'`.
13. Read the errors a page catches itself from its own error reports with `--match 'jserror'`, since such errors never reach the console.
14. Drive a form with `--then` and made-up details, such as `test@example.com`, to reproduce a failure without the user's account.
15. Look for TLS failures with `tools/inspect.sh log | grep -E 'kCFStreamErrorDomainSSL|SecTrust|-98[0-9]{2}'`.
16. Restart the recorder with `tools/inspect.sh start` when the log's newest line, `tools/inspect.sh log | tail -1`, lags the clock, since the phone's log stream can stall without an error.
17. Sort each failure into its layer: TLS, syntax, missing API, browser check or blocked request.
18. Ask the user to type passwords and sign-in details on the phone themselves, and read only the page that follows, never a field's value.
19. Keep the phone's log and its device name out of commits and the chat, since both name the phone's owner.
20. Stop the background containers with `tools/inspect.sh stop` when the study ends.
