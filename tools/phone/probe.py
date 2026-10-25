#!/usr/bin/env python3
"""Opens sites in a web page on the iPhone through ios_webkit_debug_proxy and reports what each page did:
the failed requests, the console errors and a snapshot of the page.
  tools/phone/iphone.sh python3 tools/phone/probe.py https://shopee.tw/        details for one site
  tools/phone/iphone.sh python3 tools/phone/probe.py --summary URL [URL ...]   a short block per site
  tools/phone/iphone.sh python3 tools/phone/probe.py --wait 3 --eval EXPR      the open page, without navigating
Start the inspector first with tools/phone/run.sh, and keep Safari, or SafariFix's browser with --ws, in front on
the phone."""
import argparse
import base64
import json
import re
import time
import urllib.parse
import urllib.request
from collections import Counter

import websocket

SNAPSHOT = """JSON.stringify({
  href: location.href, title: document.title, ready: document.readyState,
  nodes: document.getElementsByTagName('*').length,
  text: (document.body ? document.body.innerText : '').replace(/\\s+/g, ' ').slice(0, 500)
})"""
# Safari 10.1 logs these for headers and meta tags it doesn't know; they break nothing.
NOISE = re.compile(r'Content.Security.Policy|viewport|X-Frame-Options')
BLOCKED = re.compile(r'cannot load|access control|Access-Control-Allow-Origin|Cross-origin', re.I)
UNSUPPORTED = re.compile(r'not supported|no longer supported|unsupported|update your browser|不受支援|不再受支援', re.I)


class Tab:
    """One Safari tab, driven over the WebKit Inspector protocol."""

    def __init__(self, ws_url):
        self.ws = websocket.create_connection(ws_url, timeout=10)
        self.seq = 0
        self.results, self.events = {}, []
        for domain in ('Console', 'Network', 'Page', 'Runtime'):
            self.call(domain + '.enable', timeout=3)

    def pump(self, until):
        while time.time() < until:
            self.ws.settimeout(max(0.05, until - time.time()))
            try:
                msg = json.loads(self.ws.recv())
            except websocket.WebSocketTimeoutException:
                return
            if 'id' in msg:
                self.results[msg['id']] = msg
            else:
                self.events.append(msg)

    def call(self, method, timeout=10, **params):
        self.seq += 1
        n = self.seq
        self.ws.send(json.dumps({'id': n, 'method': method, 'params': params}))
        end = time.time() + timeout
        while n not in self.results and time.time() < end:
            self.pump(min(end, time.time() + 0.5))
        return self.results.pop(n, {'error': 'no answer'})

    def evaluate(self, expr):
        res = self.call('Runtime.evaluate', expression=expr, returnByValue=True).get('result', {})
        if res.get('wasThrown'):
            return 'THROWN: ' + str(res.get('result', {}).get('description'))
        return res.get('result', {}).get('value')

    def watch(self, url, seconds):
        """Opens url and returns the events of the next seconds; without url, the open page's events,
        including the console messages Safari replays on connect."""
        if url:
            # Console.enable replays earlier pages' messages; clear them so only this page's count.
            self.call('Console.clearMessages', timeout=3)
            self.pump(time.time() + 0.5)
            self.events = []
        start = time.time()
        if url:
            r = self.call('Page.navigate', url=url)
            if 'error' in r:
                print('Page.navigate failed:', r['error'])
        self.pump(start + seconds)
        events, self.events = self.events, []
        return events


def first_tab_ws():
    # The proxy lists Safari's tabs a few seconds after it starts.
    for _ in range(10):
        try:
            tabs = json.load(urllib.request.urlopen('http://localhost:9222/json', timeout=5))
        except OSError:
            raise SystemExit('No inspector on localhost:9222: run tools/phone/run.sh.')
        if tabs:
            return tabs[0]['webSocketDebuggerUrl']
        time.sleep(1)
    raise SystemExit('No Safari tab: open Safari in front, with Settings → Safari → Advanced → Web Inspector on.')


def parse(events):
    requests, status, failed, console = {}, {}, [], []
    for e in events:
        m, prm = e.get('method'), e.get('params', {})
        if m == 'Network.requestWillBeSent':
            requests[prm['requestId']] = (prm.get('type', '?'), prm['request']['url'])
        elif m == 'Network.responseReceived':
            status[prm['requestId']] = prm['response'].get('status')
        elif m == 'Network.loadingFailed':
            failed.append((prm['requestId'], prm.get('errorText', ''), prm.get('canceled', False)))
        elif m == 'Console.messageAdded':
            console.append(prm['message'])
    return requests, status, failed, console


def error_kinds(console):
    """Counts the console errors by kind: SyntaxError, ReferenceError, TypeError, blocked or other."""
    kinds = Counter()
    for m in console:
        text = m.get('text', '')
        if m.get('level') != 'error' or NOISE.search(text):
            continue
        if BLOCKED.search(text):
            kinds['blocked'] += 1
        else:
            kind = re.match(r'(SyntaxError|ReferenceError|TypeError)', text)
            kinds[kind.group(1) if kind else 'other'] += 1
    return kinds


def short(url, n=110):
    return url if len(url) <= n else url[:n] + '…'


def snapshot(tab):
    value = tab.evaluate(SNAPSHOT)
    try:
        return json.loads(value)
    except (TypeError, ValueError):
        return {'error': value}


def save_shot(tab, path):
    """Saves the visible part of the page as a PNG, rendered by Safari; Safari's own buttons aren't in it."""
    size = tab.evaluate('JSON.stringify([innerWidth, innerHeight])')
    try:
        width, height = json.loads(size)
    except (TypeError, ValueError):
        return f'no picture: {size}'
    r = tab.call('Page.snapshotRect', x=0, y=0, width=width, height=height, coordinateSystem='Viewport')
    url = r.get('result', {}).get('dataURL', '')
    if not url.startswith('data:image/png;base64,'):
        return f'no picture: {r.get("error", r)}'
    with open(path, 'wb') as f:
        f.write(base64.b64decode(url.split(',', 1)[1]))
    return f'{width}x{height} saved to {path}'


def print_details(requests, status, failed, console, page, list_all):
    print(f'== requests: {len(requests)}, statuses: {dict(Counter(status.values()))}, failed loads: {len(failed)}')
    for rid, err, canceled in failed[:25]:
        kind, url = requests.get(rid, ('?', '?'))
        print(f'  FAILED {kind:<10} {"(canceled) " if canceled else ""}{err}  {short(url)}')
    for rid, code in status.items():
        if code and code >= 400:
            kind, url = requests.get(rid, ('?', '?'))
            print(f'  HTTP {code} {kind:<10} {short(url)}')
    if list_all:
        for rid, (kind, url) in requests.items():
            print(f'  {status.get(rid, "-")!s:>4} {kind:<10} {short(url)}')
    print(f'== console: {dict(Counter(m.get("level") for m in console))}, errors by kind: {dict(error_kinds(console))}')
    seen = Counter()
    for m in console:
        if m.get('level') in ('error', 'warning') and not NOISE.search(m.get('text', '')):
            seen[(m['level'].upper(), m.get('text', '')[:200], short(m.get('url') or '', 80), m.get('line'))] += 1
    for (level, text, url, line), n in seen.most_common(25):
        print(f'  {n}x {level}: {text}  @ {url}:{line}')
    print('== page:', json.dumps(page, ensure_ascii=False))


def print_summary(url, requests, status, failed, console, page):
    errors = sum(1 for code in status.values() if code and code >= 400)
    kinds = ', '.join(f'{k} {n}' for k, n in error_kinds(console).most_common()) or 'none'
    text = page.get('text', '')
    flag = ' | SAYS UNSUPPORTED' if UNSUPPORTED.search(text) else ''
    print(url)
    print(f'  {len(requests)} requests, {len(failed)} failed, {errors} HTTP errors | JS errors: {kinds}'
          f' | {page.get("nodes", "?")} nodes{flag}')
    print(f'  {page.get("title", page.get("error", ""))!r}: {text[:120]}')


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('urls', nargs='*', help='sites to open in the tab, one after another')
    p.add_argument('--wait', type=float, default=20, help='seconds to watch each page (default 20)')
    p.add_argument('--summary', action='store_true', help='print a short block per site')
    p.add_argument('--eval', action='append', default=[], help='expression to evaluate on each page at the end')
    p.add_argument('--all', action='store_true', help='list every request, not only the failed ones')
    p.add_argument('--shot', help='save a picture of the page at the end to this PNG file (of the last page, given several URLs)')
    p.add_argument('--then', help='expression to run once the page has loaded, such as filling and submitting a form')
    p.add_argument('--then-wait', type=float, default=15, help='seconds to keep watching after --then (default 15)')
    p.add_argument('--match', help='print the full, decoded URL of each request matching this regular expression')
    p.add_argument('--ws', help='the tab\'s WebSocket URL (default: the first tab on localhost:9222)')
    a = p.parse_args()

    tab = Tab(a.ws or first_tab_ws())
    for url in a.urls or [None]:
        events = tab.watch(url, a.wait)
        if a.then:
            print('== then:', tab.evaluate(a.then))
            events += tab.watch(None, a.then_wait)
        parsed = parse(events)
        page = snapshot(tab)
        if a.match:
            for _, request_url in parsed[0].values():
                if re.search(a.match, request_url):
                    print('== match:', urllib.parse.unquote(request_url))
        if a.summary:
            print_summary(url or page.get('href', '?'), *parsed, page)
        else:
            print_details(*parsed, page, a.all)
        for expr in a.eval:
            print(f'  {short(expr, 50)} => {tab.evaluate(expr)}')
    if a.shot:
        print('== picture:', save_shot(tab, a.shot))


if __name__ == '__main__':
    main()
