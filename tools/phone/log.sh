#!/usr/bin/env bash
# Prints the phone's log that run.sh records, such as tools/phone/log.sh | grep SafariFix. The log names the phone's
# owner: keep it out of commits and chat.
set -euo pipefail

RUNTIME=$(command -v podman || command -v docker || true)
if [[ -z $RUNTIME ]]; then
  echo "Install podman or docker; the iPhone tools run in a container." >&2
  exit 1
fi
"$RUNTIME" logs isyslog 2>&1
