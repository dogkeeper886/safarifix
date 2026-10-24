"""mitmproxy addon: fixes pages for Safari 10.1 on the iPhone 5.
- Rewrites JavaScript, in script files and inline scripts, to the syntax iOS 10.3 reads, with esbuild.
- Adds the polyfills at the top of each page, served from /__safarifix/polyfills.js on the page's own host.
- Drops Content-Security-Policy and script integrity hashes, which the rewritten scripts and the polyfills would fail.
Hosts in IGNORE pass through untouched (see bench/run.sh), so Google and YouTube never reach this addon."""
import asyncio
import hashlib
import logging
import pathlib
import re
import time

from mitmproxy import http

TARGET = 'ios10.3'
# esbuild can't lower let and const, and refuses iOS 10 for them because of Safari 10's let bugs; nor can it lower
# destructuring inside them. Safari 10.1 runs both, so keep them as they are and lower everything else.
ESBUILD = ['esbuild', '--loader=js', f'--target={TARGET}', '--supported:const-and-let=true',
           '--supported:destructuring=true', '--minify-whitespace', '--charset=utf8', '--log-level=error']
POLYFILL_PATH = '/__safarifix/polyfills.js'
POLYFILLS = b'\n;\n'.join(p.read_bytes() for p in sorted(pathlib.Path('/opt/safarifix/polyfills').glob('*.js')))
CACHE = pathlib.Path('/cache')
# esbuild runs this many at once; more starve the proxy on a page with dozens of scripts.
LIMIT = asyncio.Semaphore(4)

JS_TYPES = re.compile(r'javascript|ecmascript', re.I)
INLINE_SCRIPT = re.compile(rb'(<script\b)([^>]*)(>)(.*?)(</script>)', re.I | re.S)
SCRIPT_TYPE = re.compile(rb'\btype\s*=\s*["\']?([^"\'\s>]+)', re.I)
INTEGRITY = re.compile(rb'\s(integrity|nonce)\s*=\s*("[^"]*"|\'[^\']*\'|[^\s>]+)', re.I)
META_CSP = re.compile(rb'<meta[^>]+http-equiv\s*=\s*["\']?content-security-policy[^>]*>', re.I)
HEAD = re.compile(rb'<head\b[^>]*>', re.I)
CSP_HEADERS = ('content-security-policy', 'content-security-policy-report-only', 'x-content-security-policy')

log = logging.getLogger('safarifix')


async def transpile(code: bytes, what: str) -> bytes:
    """Returns code in iOS 10.3 syntax, or the code unchanged when esbuild can't lower it."""
    key = hashlib.sha256(code).hexdigest()
    cached = CACHE / (key + '.js')
    if cached.exists():
        return cached.read_bytes()
    async with LIMIT:
        start = time.monotonic()
        proc = await asyncio.create_subprocess_exec(
            *ESBUILD, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        out, err = await proc.communicate(code)
    ms = (time.monotonic() - start) * 1000
    if proc.returncode != 0:
        first = err.decode(errors='replace').strip().splitlines()[:2]
        log.warning(f'esbuild FAILED {what} ({len(code)} B, {ms:.0f} ms): {" | ".join(first)}')
        return code
    log.info(f'esbuild {what}: {len(code)} -> {len(out)} B in {ms:.0f} ms')
    cached.write_bytes(out)
    return out


def is_js_script(attrs: bytes) -> bool:
    if re.search(rb'\bsrc\s*=', attrs, re.I):
        return False
    t = SCRIPT_TYPE.search(attrs)
    return t is None or t.group(1).lower() in (b'module', b'text/javascript', b'application/javascript')


async def fix_html(html: bytes, url: str) -> bytes:
    html = META_CSP.sub(b'', html)
    parts = INLINE_SCRIPT.split(html)
    # split() yields: text, then 5 groups per script, then text.
    jobs = []
    for i in range(1, len(parts) - 1, 6):
        attrs, body = parts[i + 1], parts[i + 3]
        if body.strip() and is_js_script(attrs):
            jobs.append((i + 3, transpile(body, f'inline script on {url}')))
    for index, result in zip([j[0] for j in jobs], await asyncio.gather(*(j[1] for j in jobs))):
        parts[index] = result
    html = b''.join(parts)
    # A rewritten script no longer matches its integrity hash.
    html = re.sub(rb'(<(?:script|link)\b[^>]*)', lambda m: INTEGRITY.sub(b'', m.group(1)), html, flags=re.I)

    tag = b'<script src="' + POLYFILL_PATH.encode() + b'"></script>'
    head = HEAD.search(html)
    if head:
        return html[:head.end()] + tag + html[head.end():]
    return tag + html


class SafariFix:
    def request(self, flow: http.HTTPFlow) -> None:
        if flow.request.path.split('?')[0] == POLYFILL_PATH:
            flow.response = http.Response.make(200, POLYFILLS, {
                'content-type': 'application/javascript; charset=utf-8',
                'cache-control': 'public, max-age=86400',
            })

    async def response(self, flow: http.HTTPFlow) -> None:
        resp = flow.response
        if resp is None or resp.status_code != 200 or flow.request.path.startswith(POLYFILL_PATH):
            return
        for name in CSP_HEADERS:
            resp.headers.pop(name, None)
        ctype = resp.headers.get('content-type', '')
        path = flow.request.path.split('?')[0]
        url = flow.request.pretty_host + path[:60]
        if 'text/html' in ctype:
            resp.content = await fix_html(resp.content, url)
        elif JS_TYPES.search(ctype) or (path.endswith(('.js', '.mjs')) and 'json' not in ctype):
            resp.content = await transpile(resp.content, url)


addons = [SafariFix()]
