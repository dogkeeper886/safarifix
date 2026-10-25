#!/usr/bin/env bash
# Shows which of run.sh's containers run, the phone's iOS, the web pages the inspector can reach, and the app's debug
# record. The phone's name and its pages' addresses name its owner: keep this output out of commits and chat.
set -euo pipefail

RUNTIME=$(command -v podman || command -v docker || true)
if [[ -z $RUNTIME ]]; then
  echo "Install podman or docker; the iPhone tools run in a container." >&2
  exit 1
fi
"$RUNTIME" ps --format '{{.Names}}: {{.Status}}' | grep -E '^(iwdp|isyslog|iproxy):' ||
  echo "No container runs: tools/phone/run.sh"
# The device list also carries the phone's name; show only the iOS version.
curl -s localhost:9221/json | grep -E '"deviceOSVersion"' ||
  echo "No iPhone: plug it straight into the PC and tap \"Trust This Computer\"."
pages=$(curl -s localhost:9222/json | grep -E '"(title|url)"' || true)
if [[ -n $pages ]]; then
  echo "$pages"
else
  echo "No web page: open one in Safari or in SafariFix's browser," \
    "with Settings → Safari → Advanced → Web Inspector on."
fi
record=$(curl -s --max-time 3 http://127.0.0.1:18118/debug/summary.txt | head -1 || true)
echo "Debug record: ${record:-none; open SafariFix on the phone.}"
