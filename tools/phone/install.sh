#!/usr/bin/env bash
# Sets up this PC for the phone tools, then checks the iPhone and the Apple ID: podman or docker and usbmuxd must be
# installed; it downloads the pinned plumesign (pins.sh) into build/ and builds the iphone-tools image (build.sh).
# Run it again to check; it downloads only what's missing. Needs curl and tar.
set -euo pipefail
cd "$(dirname "$0")/../.."
source tools/deps.sh
source tools/phone/pins.sh

RUNTIME=$(command -v podman || command -v docker || true)
if [[ -z $RUNTIME ]]; then
  echo "✗ podman or docker: install one; the tools run in containers." >&2
  exit 1
fi
echo "✓ ${RUNTIME##*/}"

# usbmuxd carries everything to the iPhone over USB; the containers reach it through its socket.
if [[ ! -S /var/run/usbmuxd ]]; then
  echo "✗ usbmuxd: install your distribution's usbmuxd package, then plug the iPhone in to start it." >&2
  exit 1
fi
echo "✓ usbmuxd"

if [[ ! -x $PLUMESIGN_BIN ]]; then
  deps_fetch "$PLUMESIGN_URL" "$PLUMESIGN_SHA256" "$PLUMESIGN_DIR"
  # The archive keeps no file modes.
  chmod +x "$PLUMESIGN_BIN"
fi
echo "✓ plumesign in $PLUMESIGN_DIR"

tools/phone/build.sh

ready=1
# Only the count, since the UDID and the account name the phone's owner.
if [[ -z $(tools/phone/iphone.sh idevice_id -l < /dev/null) ]]; then
  echo "✗ iPhone: plug it straight into the PC, unlock it, tap \"Trust This Computer\", and run this again."
  ready=0
elif ! tools/phone/iphone.sh idevicepair validate < /dev/null >/dev/null 2>&1; then
  echo "✗ iPhone not paired: unlock it, tap \"Trust This Computer\", and run this again."
  ready=0
else
  echo "✓ iPhone paired"
fi

accounts=$(tools/phone/plumesign.sh account list < /dev/null 2>&1 || true)
if [[ $accounts == *"Saved accounts:"* ]]; then
  echo "✓ Apple ID signed in"
elif [[ $accounts == *"No accounts found"* ]]; then
  echo "✗ Apple ID: in your own terminal, run tools/phone/plumesign.sh account login -u <Apple ID>," \
    "and type the password and the code it asks for."
  ready=0
else
  echo "✗ plumesign didn't run: see what tools/phone/plumesign.sh account list says."
  ready=0
fi

if (( ready )); then
  echo "Ready. Build the app with ios/build.sh, sign and install it with tools/phone/plumesign.sh (see the README)," \
    "and start the tools with tools/phone/run.sh."
fi
