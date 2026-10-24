# Findings

What the stock Safari 10.1 on the iPhone 5 did on 2026-10-24, measured with `tools/probe.py` over USB and WiFi internet. Compare a new probe with it, and add a dated row when a site's result changes.

## The phone

| | |
|---|---|
| Model | iPhone5,2 (iPhone 5), armv7s |
| iOS | 10.3.4 (14G61) |
| Safari's user agent | `Mozilla/5.0 (iPhone; CPU iPhone OS 10_3_4 like Mac OS X) AppleWebKit/603.3.8 (KHTML, like Gecko) Version/10.0 Mobile/14G61 Safari/602.1` |
| Has | `fetch`, `Promise`, `customElements` |
| Lacks | `IntersectionObserver`, `ResizeObserver`, `PerformanceObserver`, `performance.getEntriesByType`, `WebAssembly`, `MediaSource` |

## TLS

TLS is not the blocker. Of about 700 requests across the sites below, none failed on TLS, and the phone's log held no certificate or TLS error. The phone's clock was right to the second.

- **Google and YouTube** chain to GlobalSign Root CA through Google's cross-signs, which expire on 2028-01-28. After that date the phone needs the GTS roots installed as a profile, then trusted in Settings → General → About → Certificate Trust Settings.
- **Let's Encrypt** sites chain to ISRG Root X1, which iOS 10 trusts.

## Sites

| Date | Site | Result | Cause |
|---|---|---|---|
| 2026-10-24 | google.com search | Works: results and the AI overview | |
| 2026-10-24 | m.youtube.com search | Works | |
| 2026-10-24 | m.youtube.com watch | Plays at 360p (640x360, format 18), muted until tapped | |
| 2026-10-24 | accounts.google.com | The email page loads; sign-in fails after the email is entered (the user's report; Google's message wasn't captured) | |
| 2026-10-24 | zh.wikipedia.org | Works | |
| 2026-10-24 | github.com | Works | |
| 2026-10-24 | facebook.com | The login page shows | |
| 2026-10-24 | x.com | The login page shows; scripts fail | Syntax: `?`, `catch {` |
| 2026-10-24 | bbc.com/news | The text shows; scripts fail | Syntax: `{...}`, `?.`, class fields |
| 2026-10-24 | tw.news.yahoo.com | The text shows; scripts fail | Syntax: `{...}`, `?`; the `let` bug |
| 2026-10-24 | amazon.com | The text shows; scripts fail | Syntax: `{...}`; lacks `IntersectionObserver`, `performance.getEntriesByType` |
| 2026-10-24 | shopee.tw | Blank | Lacks `IntersectionObserver`, `PerformanceObserver`; syntax: `catch {` |
| 2026-10-24 | instagram.com | Says the browser is no longer supported | Browser check; syntax; blocked cross-origin requests |
| 2026-10-24 | netflix.com | Says the browser is not supported | Browser check; its video also needs MSE and EME, which Safari 10.1 lacks |

## Through the bench

What the same Safari did on 2026-10-24 through the PC test bench, `bench/run.sh`: mitmproxy rewriting scripts with esbuild 0.28.2, and adding core-js 3.50.0, the IntersectionObserver and ResizeObserver polyfills and `bench/polyfills/4-performance.js`. Google and YouTube hosts passed through untouched.

| Date | Site | Result through the bench | Left |
|---|---|---|---|
| 2026-10-24 | bbc.com/news | No SyntaxError | A script the page builds from a `blob:` URL; core-js logs "Unhandled promise rejection" |
| 2026-10-24 | tw.news.yahoo.com | No SyntaxError, and no `let` error | |
| 2026-10-24 | amazon.com | No SyntaxError | |
| 2026-10-24 | google.com search | Works, passed through | |
| 2026-10-24 | m.youtube.com watch | Plays, passed through | |
| 2026-10-24 | shopee.tw | Still blank | Its own requests to shopee.tw fail with "access control checks" |
| 2026-10-24 | x.com | One SyntaxError | Top-level `await`, which esbuild can't lower |
| 2026-10-24 | instagram.com | Still says the browser is unsupported | Browser check |

## Lessons for the phone app

- **TLS fallback:** after one failed handshake, Safari retries that host with an older TLS version until Safari quits; the bench logged "Client and mitmproxy cannot agree on a TLS version". The proxy on the phone must accept TLS 1.0 to 1.2 from Safari, which SecureTransport on iOS 10 can.
- **Cache:** Safari keeps the unfixed scripts in its cache. Clear Safari's website data once the proxy starts fixing a site.
- **esbuild:** 0.28.2 refuses `ios10.3` for `let`, `const` and destructuring inside them. `--supported:const-and-let=true --supported:destructuring=true` keeps them as they are, and Safari 10.1 runs them.
- **esbuild's limits:** it can't lower top-level `await`, and it turns regex syntax Safari 10.1 lacks, such as named groups, into `new RegExp(...)` calls that still throw when they run.
- **Trust:** Safari trusts a profile's root certificate only after its switch is on in Settings → General → About → Certificate Trust Settings; until then loads fail with `-9813` and `-1202`.
- **Sign-in:** Google rejects Safari 10.1 after the email, so the proxy may have to handle accounts.google.com instead of passing it through.
- **The phone's own services:** iOS sends its system traffic through the WiFi proxy too. Trusting a developer failed with "needs internet" while the bench decrypted ppq.apple.com; apple.com, icloud.com and mzstatic.com must pass through untouched.

## esbuild on the phone

The build test, `spike/esbuild-ios/build.sh`, built esbuild v0.28.2 with Go 1.14.15 into a test app, and timed it on the iPhone 5 on 2026-10-24. Its output matched the bench's byte for byte, so it runs in Safari 10.1 as the bench's did.

| Sample | Size in → out | Three runs |
|---|---|---|
| BBC News's main script, with 159 `?.` and 98 object spreads | 301 KB → 356 KB | 380, 371, 305 ms |
| three.js 0.170.0, module build | 1.3 MB → 964 KB | 678, 684, 654 ms |

- **Go:** 1.14 is the last release with darwin/arm, the 32-bit iPhone target; esbuild keeps Go 1.13 support on purpose.
- **x/sys:** esbuild's pinned golang.org/x/sys lacks darwin/arm. The build replaces it with `v0.0.0-20210216163648-f7da38b97c65`, the last version whose darwin/arm code compiles.
- **Library, not a program:** an iOS app can't start another process, so esbuild links into the app as a Go c-archive, 20 MB, with an 11.6 MB app binary.

## Error map

| Safari 10.1 says | Layer | Cause |
|---|---|---|
| `Unexpected token '...'. Expected a property name.` | Syntax | Object spread or rest, `{...x}` (ES2018) |
| `Unexpected token '?'`, `Unexpected token '.'` | Syntax | Optional chaining `?.` or nullish coalescing `??` (ES2020) |
| `Unexpected token '{'. Expected '(' to start a 'catch' target.` | Syntax | Optional catch binding, `catch {` (ES2019) |
| `Expected an opening '(' before a method's parameter list.` | Syntax | Class fields (ES2022) |
| `Cannot declare a let variable twice` | Syntax | Valid code that Safari 10's `let` scoping bug rejects |
| `Can't find variable: X`, `undefined is not a constructor (evaluating 'new …X')`, `X is not a function` | Missing API | Safari 10.1 lacks X |
| `Origin … is not allowed by Access-Control-Allow-Origin`, `… cannot load …` | Blocked request | A cross-origin request the site's servers refuse to this browser |
| Page text such as "not supported" or "不再受支援" | Browser check | The site rejects the user agent |
| A failed load, with `kCFStreamErrorDomainSSL` or `-98xx` in the phone's log | TLS | A missing or expired root, the clock, or a protocol the phone lacks |
| `Content Security Policy`, `viewport-fit`, `X-Frame-Options` messages | None | Headers and meta tags Safari 10.1 doesn't know; harmless |
