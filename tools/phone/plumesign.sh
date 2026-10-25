#!/usr/bin/env bash
# Runs plumesign (Impactor's command-line signer) against the iPhone on USB, natively when the host can run it,
# otherwise in a container, since its Linux builds need a newer glibc than RHEL 8's.
#   tools/phone/plumesign.sh account login -u <Apple ID>   once, in your own terminal: it asks for the password and code
#   tools/phone/plumesign.sh sign --package build/SafariFix.ipa --apple-id --register-and-install --udid <UDID>
#   PLUMESIGN        plumesign binary (default: the one install.sh downloads, see pins.sh)
#   PLUMESIGN_HOME   Apple ID session for container runs (default: ~/.local/share/safarifix/plumesign);
#                    native runs keep it in ~/.config/PlumeImpactor
#   PLUMESIGN_IMAGE  container image with a newer glibc (default: docker.io/library/ubuntu:24.04)
# Paths under the current directory, such as build/SafariFix.ipa, work the same in both modes.
# Copied from CleanCam's tools/plumesign.sh.
set -euo pipefail

source "$(dirname "$0")/pins.sh"
BIN=${PLUMESIGN:-$(dirname "$0")/../../$PLUMESIGN_BIN}
if [[ ! -x $BIN ]]; then
  echo "plumesign not found: run tools/phone/install.sh, or set PLUMESIGN=/path/to/plumesign." >&2
  exit 1
fi
BIN=$(readlink -f "$BIN")

if "$BIN" --version >/dev/null 2>&1; then
  exec "$BIN" "$@"
fi

RUNTIME=$(command -v podman || command -v docker || true)
if [[ -z $RUNTIME ]]; then
  echo "This host cannot run plumesign directly (it needs a newer glibc);" \
    "install podman or docker to run it in a container." >&2
  exit 1
fi

DATA=${PLUMESIGN_HOME:-$PLUMESIGN_DATA}
mkdir -p "$DATA"

CA=
for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
  [[ -f $f ]] && { CA=$f; break; }
done
if [[ -z $CA ]]; then
  echo "No CA certificate bundle found; plumesign needs one to reach Apple." >&2
  exit 1
fi

# Run as the calling user so the session files stay theirs.
if [[ $RUNTIME == *podman ]]; then
  USER_OPTS=(--userns=keep-id)
else
  USER_OPTS=(--user "$(id -u):$(id -g)")
fi
TTY=()
[[ -t 0 ]] && TTY=(-t)

# label=disable lets the container reach the usbmuxd socket on SELinux hosts.
exec "$RUNTIME" run --rm -i "${TTY[@]}" --security-opt label=disable "${USER_OPTS[@]}" \
  -e HOME=/data -v "$DATA:/data" \
  -v /run/usbmuxd:/run/usbmuxd \
  -v "$BIN:/usr/local/bin/plumesign:ro" \
  -v "$CA:/etc/ssl/certs/ca-certificates.crt:ro" \
  -v "$PWD:$PWD:ro" -w "$PWD" \
  "${PLUMESIGN_IMAGE:-docker.io/library/ubuntu:24.04}" plumesign "$@"
