# SafariFix

An iPhone 5 stops at iOS 10.3.4, and its Safari 10.1 still searches Google and plays YouTube. Many other sites now send JavaScript newer than Safari 10.1 can parse, or call web APIs it lacks. Their pages stay blank or half-working, and the phone gets no newer Safari.

SafariFix fixes each page on its way to Safari: a proxy rewrites the new syntax into what Safari 10.1 reads, adds the missing APIs, and passes Google, YouTube and Apple through untouched. The proxy runs in the SafariFix app on the phone alone, signed with a free Apple ID as [CleanCam](https://github.com/dogkeeper886/cleancam) is. A test bench on a Linux PC and two test apps came first.

## The SafariFix app

The app runs the proxy on `127.0.0.1:8118`, and Safari reaches it through a PAC file. The proxy is `core/`, in Go 1.14, the last Go for 32-bit iPhones, built into the app as a C library; `ios/app/` wraps it in an Objective-C app that plays a silent sound to keep running behind Safari. It passes Google search, YouTube and Apple's services through untouched, adds only `AbortController` to Google's sign-in pages, and rewrites every other site's scripts with esbuild on the phone.

### Set up the app

1. **Build the IPA** on the Linux PC with `ios/build.sh`, which writes `build/SafariFix.ipa`. It needs podman or docker, curl, git, zip and python3, and downloads its pinned Go, esbuild, SDK, toolchain and polyfills into `build/` on the first run.
2. **Sign and install** it as the test apps below, with `build/SafariFix.ipa` in step 3.
3. **Open SafariFix.** The first launch makes the root certificate, which can take a minute. The screen then lists the setup steps left, and checks them every 2 seconds while the app is in front.
4. **Install the certificate:** tap "Install in Safari", then "Install the certificate" on the page, Allow and Install.
5. **Trust it** in Settings → General → About → Certificate Trust Settings: turn on the SafariFix root the page names, "SafariFix root" and six hex digits, and tap Continue on the warning. Until its switch is on, Safari can't open any site the app fixes.
6. **Point Safari at it:** tap "Copy the address", then in Settings → Wi-Fi → ⓘ → HTTP Proxy → Auto, paste it as the URL, `http://127.0.0.1:8118/proxy.pac`. The screen shows "Ready" once both steps are done.

- **Keep it running:** in the app switcher, swipe away only Safari, never SafariFix. While SafariFix isn't running, Safari reaches the internet directly through the PAC file's fallback, with pages unfixed.
- **Renew:** a free Apple ID signs the app for 7 days, and the screen shows until when. Repeat step 2 with the same IPA; the root certificate and its trust stay.
- **The app's log:** read it with `tools/inspect.sh log | grep SafariFix`, from [Measure a page on the phone](#measure-a-page-on-the-phone). A 30-second heartbeat shows the app running; after a crash, the next launch logs Go's last words as "last run's stderr". Details, on the main screen, shows what the checks found, the counts and the core's last log lines, and copies them in one tap.
- **A debug build:** `DEBUG=1 ios/build.sh` writes `build/SafariFix-debug.ipa`, which saves pictures of its main screen in each state. Read them from the PC over USB with `DETACH=iproxy tools/iphone.sh iproxy 18118:8118`, then `http://127.0.0.1:18118/debug/screen.png` or `state-ready.png`.
- **Change the core:** `core/go.sh test ./...` runs its tests, and `GOARCH=386 CGO_ENABLED=0 core/go.sh test ./certs ./fix ./proxy ./rules` runs them on 32 bits, which catches what crashes the iPhone 5. `core/go.sh run ./cmd/safarifix-pc` runs the same proxy on the PC for the phone to use over the Wi-Fi.

## The PC bench

The bench fixes each page while the iPhone loads it: the iPhone uses the bench, a mitmproxy on the PC, as its Wi-Fi proxy. The bench rewrites each script with esbuild and loads the polyfills at the top of each page, so Safari 10.1 runs the page. It passes Google, YouTube and Apple's hosts through untouched, since Google and YouTube already work in the stock Safari and the phone's own services reject the bench's certificate. `bench/fix.py` holds the fixes, and `bench/Dockerfile` pins esbuild and the polyfills.

### Run the bench

![On the Linux PC: 1, start the bench with bench/run.sh, with port 8080 open. On the iPhone 5: 2, point Wi-Fi's HTTP Proxy at the PC, Manual, port 8080; 3, install the certificate from http://mitm.it as an iOS profile; 4, trust it in About, Certificate Trust Settings; 5, clear Safari's history and website data; 6, browse, and set HTTP Proxy to Off when the bench stops. After a change to bench/, restart bench/run.sh on the PC and repeat step 5.](docs/images/bench-steps.png)

1. **Start the bench** on the PC with `bench/run.sh`. It needs podman or docker and listens on port 8080. Open that port in the PC's firewall for the phone.
2. **Point the iPhone at it** in Settings → Wi-Fi → (i) → HTTP Proxy → Manual: the PC's IP, port 8080.
3. **Install the bench's certificate:** open `http://mitm.it` in Safari and install the iOS profile.
4. **Trust it** in Settings → General → About → Certificate Trust Settings. Until then, Safari fails every site the bench decrypts.
5. **Clear Safari's cache** in Settings → Safari → Clear History and Website Data, since Safari keeps the unfixed scripts.
6. **Browse.** Set HTTP Proxy back to Off when the bench stops, since Safari reaches the internet only through it.

- **After a change to `bench/`:** restart `bench/run.sh`, which rebuilds the image, and clear Safari's cache again. The bench fixes only fresh responses, and Safari keeps the polyfills for a day.
- **A site that fails its TLS handshake:** quit Safari. After one failed handshake, Safari retries that site with an older TLS version, which the bench refuses.

### What the bench can't fix

- **Syntax esbuild leaves broken:** a script with top-level `await` reaches Safari unchanged, and named regex groups and BigInt become calls that still throw.
- **Browser checks and blocked requests:** a site refuses Safari 10.1 by its user agent, or its servers refuse this browser's cross-origin requests.
- **Google's sign-in:** Google's sign-in script calls `AbortController`, which Safari 10.1 lacks, and the bench passes Google untouched. The app adds it; with the bench, `tools/google-signin.py` keeps an `AbortController` polyfill in Safari's tab over USB while the user signs in.

## The test apps

The bench works only while the PC runs and the phone shares its Wi-Fi. A phone that browses on its own needs the proxy inside an app. But iOS keeps an app from starting another program and suspends it in the background, and Apple's current tools build iOS apps for 64-bit iPhones only. Three test apps, built on the Linux PC, try the parts on the iPhone 5:

- **esbuild-test** (`spike/esbuild-ios`) links esbuild into the app as a Go library and times it on sample scripts.
- **proxy-test** (`spike/proxy-ios`) runs a proxy on `127.0.0.1:8118` that Safari reaches through a PAC file, and keeps running in the background with a silent sound. It passes HTTPS through still encrypted, so every page reaches Safari unfixed for now.
- **Browser test** (`spike/browser-ios`) is a bare browser in a UIWebView that sends every request through the SafariFix core inside the app, on `127.0.0.1:8128`, with no Wi-Fi proxy setting or trusted certificate. Its JavaScript runs without the JIT. It keeps a debug record of each page's requests, script errors and WebKit's own messages, and of the app's memory, which its Debug button shows and the PC reads over USB.

### Build an app

`spike/proxy-ios/build.sh`, `spike/esbuild-ios/build.sh` and `spike/browser-ios/build.sh` build an unsigned IPA into `build/`, with the compiler in a container on the Linux PC. They need podman or docker, curl, git and zip, and download their pinned SDK and toolchain into `build/` on the first run. Each script's header says what it downloads and why. Browser test's build also makes a copy of Go 1.14 that reserves less of the 32-bit address space, which the web view needs.

### Install an app

![On the Linux PC: 1, build the IPA with spike/*/build.sh in a container. On the iPhone 5: 2, connect it straight to the PC and tap Trust. On the PC: 3, sign and install with CleanCam's plumesign.sh and a free Apple ID. On the iPhone: 4, trust the developer in General, Device Management; 5, open the app, which starts its work at launch; 6, point Safari at proxy-test with HTTP Proxy set to Auto and the proxy.pac URL. The app then runs for 7 days; repeat step 3 with the same IPA to renew. On the PC, read the app's lines over USB with tools/inspect.sh log | grep proxy-test:.](docs/images/app-steps.png)

1. **Build the IPA** as above.
2. **Connect the iPhone** straight to the PC, since usbmuxd lists the phone only on a direct cable. Unlock it and tap "Trust This Computer".
3. **Sign and install** from this repo's root with CleanCam's `tools/plumesign.sh`, here from a CleanCam clone beside this one:
   ```sh
   ../cleancam/tools/plumesign.sh sign --package build/proxy-test.ipa --apple-id --register-and-install \
     --udid "$(tools/iphone.sh idevice_id -l < /dev/null | head -1)"
   ```
   Log in first with `../cleancam/tools/plumesign.sh account login -u <your Apple ID>`, as CleanCam's README describes.
4. **Trust the developer** in Settings → General → Device Management.
5. **Open the app.** It starts its proxy or its timing run at launch, and shows each line on its screen.
6. **Point Safari at proxy-test** in Settings → Wi-Fi → (i) → HTTP Proxy → Auto, with the URL `http://127.0.0.1:8118/proxy.pac`. This replaces the bench's Manual setting.

- **Renew:** a free Apple ID signs the app for 7 days. Repeat step 3 with the same IPA.
- **After a change to the app:** repeat steps 1, 3 and 5, since the app starts its proxy only at launch.
- **The app's log:** each line also goes to the phone's log, prefixed with the app's name. Read it with `tools/inspect.sh log | grep proxy-test:`, from the next section.
- **"Maximum number of apps":** a free Apple ID's profiles allow only a few apps at once, and an update can fail with this. Uninstall the old copy first: `tools/iphone.sh ideviceinstaller -l` lists the bundle IDs, and `tools/iphone.sh ideviceinstaller -U <bundle ID>` removes one, with its data. Never uninstall SafariFix this way, since its root certificate goes with it.
- **An app that won't open after install:** iOS checks the developer with Apple over the internet, and shows the untrusted-developer alert while that check fails or times out. Tap Verify App in Settings → General → Device Management again.

### Read Browser test's record

1. **Forward its port** over USB with `DETACH=iproxy-bt tools/iphone.sh iproxy 18128:8128`.
2. **Read the record** at `http://127.0.0.1:18128/debug/`: `log.txt` holds the timeline of pages, requests, messages and memory; `summary.txt` the counts; `core.txt` the core's log; and `previous.txt` the last run's timeline, to read after a crash.
3. **Drive it** with the probe from the next section: once a page has loaded, `curl localhost:9222/json` lists its web view, and `tools/iphone.sh python3 tools/probe.py --ws ws://localhost:9222/devtools/page/<n> <url>` opens a URL in it.

## Measure a page on the phone

A page's failure shows only in Safari 10.1 on the phone, while the PC lacks both the phone's screen and a Safari that old. `tools/` drives the phone's Safari from the PC through its Web Inspector over USB, and reports what each page did.

1. **Connect the iPhone** straight to the PC and tap "Trust This Computer".
2. **Turn on the Web Inspector** in Settings → Safari → Advanced → Web Inspector.
3. **Keep Safari in front** on one tab, and set Settings → Display & Brightness → Auto-Lock to Never, since a locked or background Safari stops answering.
4. **Start the inspector and the log recorder** with `tools/inspect.sh start`, which lists Safari's tabs.
5. **Probe a site** with `tools/iphone.sh python3 tools/probe.py <url>`. It opens the URL in the tab, watches it, and prints the failed requests, the console errors and the page's text. `--help` lists its other options.
6. **Stop both** with `tools/inspect.sh stop`.

- **One client at a time:** a second inspector connection to the tab drops the first.
- **A stalled log:** restart the recorder with `tools/inspect.sh start` when the log's newest line lags the clock.
- **Privacy:** the phone's log, the probe's output and the phone's name all name its owner. Keep them out of commits and issues; git ignores `logs/` for them.
