#!/usr/bin/env bash
# Runs the PC test bench: a mitmproxy on port 8080 that fixes pages for the iPhone 5's Safari with bench/fix.py.
# Point the iPhone at it in Settings → Wi-Fi → (i) → HTTP Proxy → Manual: this PC's IP, port 8080.
# The phone must trust the bench's root certificate: open http://mitm.it in Safari through the proxy,
# install the iOS profile, then turn it on in Settings → General → About → Certificate Trust Settings.
# Then clear Settings → Safari → Clear History and Website Data, since Safari's cache keeps the unfixed scripts.
# Set HTTP Proxy back to Off when the bench stops; Safari has no internet without it.
#   PORT   the proxy port (default 8080); the PC's firewall must let the phone reach it
#   BENCH_HOME   the bench's root certificate and esbuild cache (default ~/.local/share/safarifix/bench)
set -euo pipefail
cd "$(dirname "$0")"

PORT=${PORT:-8080}
DATA=${BENCH_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/safarifix/bench}
mkdir -p "$DATA/mitmproxy" "$DATA/cache"

RUNTIME=$(command -v podman || command -v docker || true)
if [[ -z $RUNTIME ]]; then
  echo "Install podman or docker; the bench runs in a container." >&2
  exit 1
fi
"$RUNTIME" build -q -t safarifix-bench . >/dev/null

# Google and YouTube work in the stock Safari; tunnel them untouched, so the bench can't break them or the sign-in.
# The phone's own services use the WiFi proxy too, and reject the bench's certificate: trusting a developer
# fails with "needs internet" until apple.com passes through.
IGNORE='^(.+\.)?(google|youtube|googlevideo|gstatic|ytimg|ggpht|googleapis|googleusercontent|googlesyndication|doubleclick|youtube-nocookie|apple|icloud|mzstatic)\.(com|com\.tw|net)(:[0-9]+)?$'

echo "Bench on port $PORT; this PC's addresses: $(hostname -I 2>/dev/null || true). Ctrl-C to stop."
# The image's entrypoint runs mitmproxy as the owner of the mounted certificate folder.
# PYTHONUNBUFFERED shows each request as it happens when the output isn't a terminal.
# After a failed handshake, Safari 10 retries that host with an older TLS version, which this mitmproxy's
# OpenSSL can't speak; quit Safari to clear that.
exec "$RUNTIME" run --rm -i --name safarifix-bench -p "$PORT:8080" --security-opt label=disable \
  -e PYTHONUNBUFFERED=1 -v "$DATA/mitmproxy:/home/mitmproxy/.mitmproxy" -v "$DATA/cache:/cache" \
  safarifix-bench mitmdump --listen-port 8080 -s /opt/safarifix/fix.py \
  --ignore-hosts "$IGNORE" --set flow_detail=1 --set termlog_verbosity=info
