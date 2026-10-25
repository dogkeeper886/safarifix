#!/usr/bin/env bash
# Builds the iphone-tools container image from image/: Ubuntu 24.04 with libimobiledevice, ideviceinstaller and
# iproxy from its packages, and ios-webkit-debug-proxy built from a pinned release. iphone.sh builds it on first use;
# run this after a change to image/.
set -euo pipefail

IMAGE=${IPHONE_TOOLS_IMAGE:-iphone-tools}
RUNTIME=$(command -v podman || command -v docker || true)
if [[ -z $RUNTIME ]]; then
  echo "Install podman or docker; the iPhone tools run in a container." >&2
  exit 1
fi
"$RUNTIME" build -q -t "$IMAGE" "$(dirname "$0")/image" >/dev/null
echo "Built $IMAGE."
