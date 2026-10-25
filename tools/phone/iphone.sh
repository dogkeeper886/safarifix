#!/usr/bin/env bash
# Runs a command in the iphone-tools container, which reaches the iPhone through the host's usbmuxd socket:
# libimobiledevice, ideviceinstaller, ios-webkit-debug-proxy and Python with websocket-client.
#   tools/phone/iphone.sh idevice_id -l
#   tools/phone/iphone.sh python3 tools/phone/probe.py https://shopee.tw/
#   DETACH=<name> tools/phone/iphone.sh ...   runs it in the background as container <name> (see run.sh)
#   PUBLISH="<port> ..." tools/phone/iphone.sh ...   listens on those ports on 127.0.0.1 alone
# Builds the image from image/ on first use (build.sh rebuilds it). Needs podman or docker and a running usbmuxd.
# Paths under the current directory work the same inside the container.
set -euo pipefail

IMAGE=${IPHONE_TOOLS_IMAGE:-iphone-tools}
RUNTIME=$(command -v podman || command -v docker || true)
if [[ -z $RUNTIME ]]; then
  echo "Install podman or docker; the iPhone tools run in a container." >&2
  exit 1
fi
if ! "$RUNTIME" image inspect "$IMAGE" >/dev/null 2>&1; then
  "$RUNTIME" build -q -t "$IMAGE" "$(dirname "$0")/image" >/dev/null
fi

# Run as the calling user so files the tools write stay theirs.
if [[ $RUNTIME == *podman ]]; then
  USER_OPTS=(--userns=keep-id)
else
  USER_OPTS=(--user "$(id -u):$(id -g)")
fi
if [[ -n ${DETACH:-} ]]; then
  MODE=(-d --name "$DETACH")
else
  MODE=(--rm -i)
  [[ -t 0 ]] && MODE+=(-t)
fi

# Host networking lets the tools reach the PC's localhost, and puts the ports they listen on there. PUBLISH="<port> ..."
# instead publishes only those ports, on 127.0.0.1, for a server that would listen on every interface.
NETWORK=(--network host)
if [[ -n ${PUBLISH:-} ]]; then
  NETWORK=()
  for port in $PUBLISH; do NETWORK+=(-p "127.0.0.1:$port:$port"); done
fi

# label=disable lets the container reach the usbmuxd socket on SELinux hosts.
exec "$RUNTIME" run "${MODE[@]}" "${NETWORK[@]}" --security-opt label=disable "${USER_OPTS[@]}" \
  -v /var/run/usbmuxd:/var/run/usbmuxd -v "$PWD:$PWD" -w "$PWD" "$IMAGE" "$@"
