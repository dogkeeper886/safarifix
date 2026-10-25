#!/usr/bin/env python3
"""Lets Google's sign-in run in the iPhone 5's Safari, until the SafariFix app does it: Google's sign-in script
calls AbortController, which Safari 10.1 lacks, and fails with "Something went wrong" after the email.
This keeps a small AbortController polyfill in Safari's open tab for 10 minutes, while the user signs in.
  tools/phone/iphone.sh python3 tools/google-signin.py [URL]   URL to open first (default: Google's sign-in for YouTube)
Start the inspector first with tools/phone/run.sh, and run no other inspector client meanwhile.
Prints the page's path each time it changes; it never reads form fields."""
import json
import re
import sys
import time
import urllib.request

import websocket

POLY = r"""(function(){
  var added = false;
  if (!window.AbortController) {
    var AbortSignal = function () { this.aborted = false; this.reason = undefined; this.onabort = null; this._listeners = []; };
    AbortSignal.prototype.addEventListener = function (type, f) { if (type === 'abort') this._listeners.push(f); };
    AbortSignal.prototype.removeEventListener = function (type, f) { this._listeners = this._listeners.filter(function (g) { return g !== f; }); };
    AbortSignal.prototype.throwIfAborted = function () { if (this.aborted) throw this.reason; };
    var AbortController = function () { this.signal = new AbortSignal(); };
    AbortController.prototype.abort = function (reason) {
      var s = this.signal; if (s.aborted) return;
      s.aborted = true; s.reason = reason;
      var e = { type: 'abort', target: s };
      if (s.onabort) s.onabort(e);
      s._listeners.slice().forEach(function (f) { f.call(s, e); });
    };
    window.AbortController = AbortController; window.AbortSignal = AbortSignal;
    added = true;
  }
  return location.host + location.pathname + (added ? ' (added)' : '');
})()"""

ws = None
seq = 0
def connect():
    global ws
    tabs = json.load(urllib.request.urlopen('http://localhost:9222/json'))
    ws = websocket.create_connection(tabs[0]['webSocketDebuggerUrl'], timeout=5)

def call(method, **params):
    # Another inspector client can drop this connection; connect again and carry on.
    global seq, ws
    seq += 1
    try:
        if ws is None:
            connect()
        ws.send(json.dumps({'id': seq, 'method': method, 'params': params}))
        end = time.time() + 5
        while time.time() < end:
            try:
                msg = json.loads(ws.recv())
            except websocket.WebSocketTimeoutException:
                break
            except ValueError:
                continue
            if msg.get('id') == seq:
                return msg
    except Exception as e:
        print(time.strftime('%H:%M:%S'), 'reconnecting:', type(e).__name__, flush=True)
        ws = None
        time.sleep(1)
    return {}

SIGNIN = 'https://accounts.google.com/ServiceLogin?service=youtube&continue=https://m.youtube.com/'
call('Page.navigate', url=sys.argv[1] if len(sys.argv) > 1 else SIGNIN)
last, until = None, time.time() + 600
while time.time() < until:
    value = call('Runtime.evaluate', expression=POLY, returnByValue=True).get('result', {}).get('result', {}).get('value')
    value = re.sub(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+', '***@***', str(value))
    if value != last and value != 'None':
        print(time.strftime('%H:%M:%S'), value, flush=True)
        last = value
    time.sleep(0.5)
print('stopped after 10 minutes', flush=True)
