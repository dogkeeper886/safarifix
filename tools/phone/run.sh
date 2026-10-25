#!/usr/bin/env bash
# Starts the three background containers for studying the iPhone from the PC, dropping any log recorded so far:
#   iwdp     ios_webkit_debug_proxy: the phone on localhost:9221, its web pages on localhost:9222
#   isyslog  idevicesyslog: the phone's log since start, which log.sh prints
#   iproxy   the app's proxy forwarded over USB to 127.0.0.1:18118, for its debug record under /debug/
# status.sh shows what runs, and stop.sh stops all three.
set -euo pipefail

DIR=$(dirname "$0")
RUNTIME=$(command -v podman || command -v docker || true)
if [[ -z $RUNTIME ]]; then
  echo "Install podman or docker; the iPhone tools run in a container." >&2
  exit 1
fi

"$RUNTIME" rm -f iwdp isyslog iproxy >/dev/null 2>&1 || true
# The inspector would listen on every interface, where any machine on the network could drive the phone's pages.
DETACH=iwdp PUBLISH="9221 9222" "$DIR/iphone.sh" ios_webkit_debug_proxy --no-frontend >/dev/null
DETACH=isyslog "$DIR/iphone.sh" idevicesyslog >/dev/null
DETACH=iproxy "$DIR/iphone.sh" iproxy 18118:8118 >/dev/null
# The inspector lists the pages a few seconds after it finds the phone.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -s localhost:9222/json 2>/dev/null | grep -q webSocketDebuggerUrl && break
  sleep 1
done
exec "$DIR/status.sh"
