# SafariFix

An iPhone 5 stops at iOS 10.3.4, and its Safari 10.1 still searches Google and plays YouTube. Many other sites now send JavaScript newer than Safari 10.1 can parse, or call web APIs it lacks. Their pages stay blank or half-working, and Safari 10.1 is the phone's last Safari.

SafariFix fixes each page on its way to the browser: a proxy rewrites the new syntax into what Safari 10.1 reads, adds the missing APIs, and passes Google, YouTube and Apple through untouched. The SafariFix app runs the proxy on the phone, with no PC, for its own browser and for Safari; a free Apple ID signs it, as it signs [CleanCam](https://github.com/dogkeeper886/cleancam). A test bench on a Linux PC and two test apps came first.

## The SafariFix app

The app runs the proxy on `127.0.0.1:8118`, and Safari reaches it through a PAC file. The proxy, `core/`, is in Go 1.14, the last Go for 32-bit iPhones, and links into the app as a C library; `ios/app/` wraps it in an Objective-C app that plays a silent sound to keep running behind Safari. It passes Google search, YouTube and Apple's services through untouched, adds only `AbortController` to Google's sign-in pages, and rewrites every other site's scripts with esbuild on the phone. The app also has a browser of its own, which uses the same proxy from the first launch. The app records what each page did, for debugging.

### Set up the app

1. **Set up the PC** with `tools/phone/install.sh`, which needs podman or docker, usbmuxd, curl and tar. It downloads the pinned signer into `build/`, builds the phone tools' container image, and names what's left. Run it again until it says "Ready".
   - **The iPhone:** plug it straight into the PC, since usbmuxd lists the phone only on a direct cable, then unlock it and tap "Trust This Computer".
   - **An Apple ID:** log in once, in your own terminal, with `tools/phone/plumesign.sh account login -u <your Apple ID>`; it asks for the password and the code.
2. **Build the IPA** on the Linux PC with `ios/build.sh`, which writes `build/SafariFix.ipa`. It needs podman or docker, curl, git, zip and python3, and downloads its pinned Go, esbuild, SDK, toolchain and polyfills into `build/` on the first run.
3. **Sign and install** it from this repo's root:
   ```sh
   tools/phone/plumesign.sh sign --package build/SafariFix.ipa --apple-id --register-and-install \
     --udid "$(tools/phone/iphone.sh idevice_id -l < /dev/null | head -1)"
   ```
4. **Trust the developer** in Settings → General → Device Management.
5. **Open SafariFix.** The first launch makes the root certificate, which can take a minute. The screen then shows "Ready".
6. **Browse** in its own browser: tap "Open the browser". It works from here, on any network.

To use Safari as well, take the two steps the screen lists under "To use Safari as well", which it checks every 2 seconds while it's in front:

7. **Install the certificate:** tap "Install in Safari", then "Install the certificate" on the page, "Allow" and "Install".
8. **Trust it** in Settings → General → About → Certificate Trust Settings: turn on the SafariFix root the page names, "SafariFix root" and six hex digits, and tap "Continue" on the warning. Safari opens the sites the app fixes only once this switch is on.
9. **Point Safari at it:** tap "Copy the address", then in Settings → Wi-Fi → ⓘ → HTTP Proxy → Auto, paste it as the URL, `http://127.0.0.1:8118/proxy.pac`. The screen hides the steps once both are done. iOS offers this setting for Wi-Fi alone, so SafariFix fixes Safari only on the Wi-Fi networks set this way.

- **The browser:** "Open the browser" on the main screen opens a bare browser, a UIWebView whose requests go through the proxy inside the app, so it skips both of Safari's steps. Its address bar takes an address, or words to search Google. Its JavaScript runs in the interpreter, slower than Safari's JIT. Two minutes after you leave the app, or at once on a memory warning, it lets go of its page, so that iOS keeps SafariFix running for Safari; it opens the page again when you come back.
- **What the browser keeps:** sign-ins and the sites' storage (cookies, localStorage, IndexedDB and WebSQL) stay in SafariFix's own data, apart from Safari's, so you sign in to each site here and in Safari separately. It keeps sign-ins, not passwords: you type yours at each sign-in. Its cache is iOS's small default, so large scripts download again on each visit. It holds one page, with a Back button and an address bar.
- **Keep it running** for Safari: in the app switcher, swipe away only Safari, and leave SafariFix. While SafariFix is closed, Safari reaches the internet directly through the PAC file's fallback, and pages arrive unfixed.
- **Renew:** a free Apple ID signs the app for 7 days, and the main screen shows the end date. Repeat step 3 with the same IPA; the root certificate, its trust and the browser's sign-ins stay.
- **"Maximum number of apps":** a free Apple ID's profiles allow 3 apps at once, and an install past that fails with this message. Uninstall another app first: `tools/phone/iphone.sh ideviceinstaller -l` lists the bundle IDs, and `tools/phone/iphone.sh ideviceinstaller -U <bundle ID>` removes one, with its data. Keep SafariFix installed: uninstalling it deletes its root certificate and the browser's sign-ins.
- **An app that won't open after install:** iOS checks the developer with Apple over the internet, and shows the untrusted-developer alert while that check fails or times out. Tap "Verify App" in Settings → General → Device Management again.

To work on the app:

- **The app's log:** start the [phone tools](#the-phone-tools) with `tools/phone/run.sh`, then read it with `tools/phone/log.sh | grep SafariFix`. A 30-second heartbeat shows the app running; after a crash, the app logs Go's last words at its next launch, as "last run's stderr". Details, on the main screen, shows what the checks found and the debug record below; its "Copy" button copies both.
- **A debug build:** `DEBUG=1 ios/build.sh` writes `build/SafariFix-debug.ipa`, which also saves pictures of its main screen in each state into the debug record's folder, as `screen.png` and `state-ready.png` and so on.
- **Change the core:** `core/go.sh test ./...` runs its tests, and `GOARCH=386 CGO_ENABLED=0 core/go.sh test ./certs ./fix ./proxy ./rules` runs them on 32 bits, which catches what crashes the iPhone 5. `core/go.sh run ./cmd/safarifix-pc` runs the same proxy on the PC for the phone to use over the Wi-Fi.

### Read the app's debug record

The record lists in time order the app's events, each page the browser opened with its requests, script errors and WebKit's own messages, and the app's memory. Details on the main screen and Debug in the browser show its last lines, and the proxy serves the whole record to the PC.

1. **Start the phone tools** with `tools/phone/run.sh`, which also forwards the proxy's port over USB to `127.0.0.1:18118`.
2. **Read the record** at `http://127.0.0.1:18118/debug/`: `log.txt` holds the timeline; `summary.txt` the counts; `core.txt` the core's log; and `previous.txt` the last run's timeline, to read after a crash. The proxy serves it only under `127.0.0.1` or `localhost`, which keeps a website from reading it under its own name.
3. **Drive the browser** with the probe from [Measure a page on the phone](#measure-a-page-on-the-phone): once a page has loaded, `curl localhost:9222/json` lists its web view, and `tools/phone/iphone.sh python3 tools/phone/probe.py --ws ws://localhost:9222/devtools/page/<n> <url>` opens a URL in it.

## The phone tools

`tools/phone/` sets up the PC, signs apps onto the iPhone and studies it over USB. Its tools run in containers that reach the phone through the PC's usbmuxd: `iphone-tools` for libimobiledevice and the inspector, and Ubuntu 24.04 for the signer, which runs on the PC itself when the PC's glibc is new enough.

| Script | What it does |
|---|---|
| `install.sh` | Sets up the PC once, then checks the iPhone and the Apple ID |
| `build.sh` | Rebuilds the container image after a change to `image/` |
| `run.sh` | Starts the inspector, the log recorder and the USB forward to the app's debug record |
| `status.sh` | Shows what runs, the phone's iOS, its web pages and the debug record |
| `log.sh` | Prints the phone's log since `run.sh` |
| `stop.sh` | Stops what `run.sh` started |
| `plumesign.sh` | Signs and installs an IPA with the signer that `pins.sh` pins |
| `iphone.sh` | Runs one command in the container, such as `idevice_id -l` |
| `probe.py` | Opens a page through the inspector and reports what it did |

### Measure a page on the phone

A page's failure shows only on the phone's screen, in a Safari older than any the PC runs. The phone tools drive the phone's Safari from the PC through its Web Inspector over USB, and report what each page did.

1. **Connect the iPhone** straight to the PC and tap "Trust This Computer".
2. **Turn on the Web Inspector** in Settings → Safari → Advanced → Web Inspector.
3. **Keep Safari in front** on one tab, and set Settings → Display & Brightness → Auto-Lock to Never, since a locked or background Safari stops answering.
4. **Start the tools** with `tools/phone/run.sh`, which lists the pages it can reach.
5. **Probe a site** with `tools/phone/iphone.sh python3 tools/phone/probe.py <url>`. It opens the URL in the tab, watches it, and prints the failed requests, the console errors and the page's text. `--help` lists its other options.
6. **Stop them** with `tools/phone/stop.sh`.

- **One client at a time:** a second inspector connection to the tab drops the first.
- **A stalled log:** restart the tools with `tools/phone/run.sh` when the log's newest line lags the clock.
- **Privacy:** the phone's log, the probe's output, the pages `status.sh` lists and the phone's name all name its owner. Keep them out of commits and issues; git ignores `logs/` for them.

## The PC bench

The bench fixes each page while the iPhone loads it: the iPhone uses the bench, a mitmproxy on the PC, as its Wi-Fi proxy. The bench rewrites each script with esbuild and loads the polyfills at the top of each page, so Safari 10.1 runs the page. It passes Google, YouTube and Apple's hosts through untouched, since Google and YouTube already work in the stock Safari and the phone's own services reject the bench's certificate. `bench/fix.py` holds the fixes, and `bench/Dockerfile` pins esbuild and the polyfills.

### Run the bench

![On the Linux PC: 1, start the bench with bench/run.sh, with port 8080 open. On the iPhone 5: 2, point Wi-Fi's HTTP Proxy at the PC, Manual, port 8080; 3, install the certificate from http://mitm.it as an iOS profile; 4, trust it in About, Certificate Trust Settings; 5, clear Safari's history and website data; 6, browse, and set HTTP Proxy to Off when the bench stops. After a change to bench/, restart bench/run.sh on the PC and repeat step 5.](docs/images/bench-steps.png)

1. **Start the bench** on the PC with `bench/run.sh`. It needs podman or docker and listens on port 8080. Open that port in the PC's firewall for the phone.
2. **Point the iPhone at it** in Settings → Wi-Fi → ⓘ → HTTP Proxy → Manual: the PC's IP, port 8080.
3. **Install the bench's certificate:** open `http://mitm.it` in Safari and install the iOS profile.
4. **Trust it** in Settings → General → About → Certificate Trust Settings. Safari opens the sites the bench decrypts only after this step.
5. **Clear Safari's cache** in Settings → Safari → Clear History and Website Data, since Safari keeps the unfixed scripts.
6. **Browse.** Set HTTP Proxy back to Off when the bench stops, since Safari reaches the internet only through it.

- **After a change to `bench/`:** restart `bench/run.sh`, which rebuilds the image, and clear Safari's cache again. The bench fixes only fresh responses, and Safari keeps the polyfills for a day.
- **A site that fails its TLS handshake:** quit Safari. After one failed handshake, Safari retries that site with an older TLS version, which the bench refuses.

### What the bench can't fix

- **Syntax esbuild leaves broken:** a script with top-level `await` reaches Safari unchanged, and named regex groups and BigInt become calls that still throw.
- **Browser checks and blocked requests:** a site refuses Safari 10.1 by its user agent, or its servers refuse this browser's cross-origin requests.
- **Google's sign-in:** Google's sign-in script calls `AbortController`, which Safari 10.1 lacks, and the bench passes Google untouched. The app adds it; with the bench, `tools/google-signin.py` keeps an `AbortController` polyfill in Safari's tab over USB while the user signs in.

## The test apps

The bench works only while the PC runs and the phone shares its Wi-Fi. A phone that browses on its own needs the proxy inside an app. But iOS keeps an app from starting another program and suspends it in the background, and Apple's current tools build iOS apps for 64-bit iPhones only. Two test apps, built on the Linux PC, try the parts on the iPhone 5:

- **esbuild-test** (`spike/esbuild-ios`) links esbuild into the app as a Go library and times it on sample scripts.
- **proxy-test** (`spike/proxy-ios`) runs a proxy on `127.0.0.1:8118` that Safari reaches through a PAC file, and keeps running in the background with a silent sound. It passes HTTPS through still encrypted, so every page reaches Safari unfixed.

### Build an app

`spike/proxy-ios/build.sh` and `spike/esbuild-ios/build.sh` build an unsigned IPA into `build/`, with the compiler in a container on the Linux PC. They need podman or docker, curl, git and zip, and download their pinned SDK and toolchain into `build/` on the first run. Each script's header says what it downloads and why.

### Install an app

![On the Linux PC: 1, build the IPA with spike/*/build.sh in a container. On the iPhone 5: 2, connect it straight to the PC and tap Trust. On the PC: 3, sign and install with tools/phone/plumesign.sh and a free Apple ID. On the iPhone: 4, trust the developer in General, Device Management; 5, open the app, which starts its work at launch; 6, point Safari at proxy-test with HTTP Proxy set to Auto and the proxy.pac URL. The app then runs for 7 days; repeat step 3 with the same IPA to renew. On the PC, read the app's lines over USB with tools/phone/log.sh | grep proxy-test:.](docs/images/app-steps.png)

1. **Build the IPA** as above.
2. **Connect the iPhone** straight to the PC, since usbmuxd lists the phone only on a direct cable. Unlock it and tap "Trust This Computer".
3. **Sign and install** it from this repo's root, once `tools/phone/install.sh` says "Ready":
   ```sh
   tools/phone/plumesign.sh sign --package build/proxy-test.ipa --apple-id --register-and-install \
     --udid "$(tools/phone/iphone.sh idevice_id -l < /dev/null | head -1)"
   ```
4. **Trust the developer** in Settings → General → Device Management.
5. **Open the app.** It starts its proxy or its timing run at launch, and shows each line on its screen.
6. **Point Safari at proxy-test** in Settings → Wi-Fi → ⓘ → HTTP Proxy → Auto, with the URL `http://127.0.0.1:8118/proxy.pac`. This replaces the bench's Manual setting.

- **Renew:** a free Apple ID signs the app for 7 days. Repeat step 3 with the same IPA.
- **After a change to the app:** repeat steps 1, 3 and 5, since the app starts its proxy only at launch.
- **The app's log:** each line also goes to the phone's log, prefixed with the app's name. Read it with `tools/phone/log.sh | grep proxy-test:`, from [The phone tools](#the-phone-tools).
- **"Maximum number of apps", or an app that won't open after install:** see SafariFix's notes in [Set up the app](#set-up-the-app).
