#!/usr/bin/env bash
# Runs the two background containers for studying Safari on the iPhone:
#   iwdp     ios_webkit_debug_proxy: the device on localhost:9221, Safari's tabs on localhost:9222
#   isyslog  idevicesyslog: the phone's log since start
#   tools/inspect.sh start    starts both, dropping any log recorded so far
#   tools/inspect.sh status   shows what runs, the phone's iOS and Safari's tabs
#   tools/inspect.sh log      prints the recorded log; it names the phone's owner, so keep it out of commits and chat
#   tools/inspect.sh stop     stops both
set -euo pipefail

TOOLS=$(dirname "$0")
RUNTIME=$(command -v podman || command -v docker || true)
if [[ -z $RUNTIME ]]; then
  echo "Install podman or docker; the iPhone tools run in a container." >&2
  exit 1
fi

case ${1:-} in
  start)
    "$RUNTIME" rm -f iwdp isyslog >/dev/null 2>&1 || true
    DETACH=iwdp "$TOOLS/iphone.sh" ios_webkit_debug_proxy --no-frontend >/dev/null
    DETACH=isyslog "$TOOLS/iphone.sh" idevicesyslog >/dev/null
    # The proxy lists Safari's tabs a few seconds after it finds the phone.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      curl -s localhost:9222/json 2>/dev/null | grep -q webSocketDebuggerUrl && break
      sleep 1
    done
    "$0" status
    ;;
  status)
    "$RUNTIME" ps --format '{{.Names}}: {{.Status}}' | grep -E '^(iwdp|isyslog):' || echo "Neither container runs: tools/inspect.sh start"
    # The device list also carries the phone's name, which names its owner; show only the iOS version.
    curl -s localhost:9221/json | grep -E '"deviceOSVersion"' || echo "No iPhone: plug it straight into the PC and tap Trust."
    tabs=$(curl -s localhost:9222/json | grep -E '"(title|url)"' || true)
    echo "${tabs:-No Safari tab: open Safari in front, with Settings → Safari → Advanced → Web Inspector on.}"
    ;;
  log)
    "$RUNTIME" logs isyslog 2>&1
    ;;
  stop)
    "$RUNTIME" rm -f iwdp isyslog >/dev/null 2>&1 || true
    echo "Stopped."
    ;;
  *)
    echo "Usage: tools/inspect.sh start|status|log|stop" >&2
    exit 2
    ;;
esac
