# SafariFix

An iPhone 5 stops at iOS 10.3.4, and its Safari 10.1 still searches Google and plays YouTube. Many other sites now send JavaScript newer than Safari 10.1 can parse, or call web APIs it lacks. Their pages stay blank or half-working, and the phone gets no newer Safari.

SafariFix fixes each page on its way to Safari: a proxy rewrites the new syntax into what Safari 10.1 reads, adds the missing APIs, and passes Google, YouTube and Apple through untouched. Today the proxy runs on a Linux PC as a test bench. SafariFix aims to move it into an app that runs on the phone alone, signed with a free Apple ID as [CleanCam](https://github.com/dogkeeper886/cleancam) is, and two test apps now try its parts there.

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
- **Google's sign-in:** Google's sign-in script calls `AbortController`, which Safari 10.1 lacks, and the bench passes Google untouched. Until the app adds it, `tools/google-signin.py` keeps an `AbortController` polyfill in Safari's tab over USB while the user signs in.

## The app on the phone

The bench works only while the PC runs and the phone shares its Wi-Fi. A phone that browses on its own needs the proxy inside an app. But iOS keeps an app from starting another program and suspends it in the background, and Apple's current tools build iOS apps for 64-bit iPhones only. Two test apps, built on the Linux PC, try the parts on the iPhone 5:

- **esbuild-test** (`spike/esbuild-ios`) links esbuild into the app as a Go library and times it on sample scripts.
- **proxy-test** (`spike/proxy-ios`) runs a proxy on `127.0.0.1:8118` that Safari reaches through a PAC file, and keeps running in the background with a silent sound. It passes HTTPS through still encrypted, so every page reaches Safari unfixed for now.

### Build an app

`spike/proxy-ios/build.sh` and `spike/esbuild-ios/build.sh` build an unsigned IPA into `build/`, with the compiler in a container on the Linux PC. They need podman or docker, curl, git and zip, and download their pinned SDK and toolchain into `build/` on the first run. Each script's header says what it downloads and why.

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
