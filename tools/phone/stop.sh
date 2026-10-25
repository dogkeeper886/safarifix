#!/usr/bin/env bash
# Stops the containers run.sh started, with the log recorded so far.
set -euo pipefail

RUNTIME=$(command -v podman || command -v docker || true)
if [[ -z $RUNTIME ]]; then
  echo "Install podman or docker; the iPhone tools run in a container." >&2
  exit 1
fi
"$RUNTIME" rm -f iwdp isyslog iproxy >/dev/null 2>&1 || true
echo "Stopped."
