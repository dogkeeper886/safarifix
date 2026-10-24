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
| 2026-10-24 | accounts.google.com | The email page loads; the steps after the email are untested | |
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
