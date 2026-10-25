# The pinned signer, which install.sh downloads and plumesign.sh runs: plumesign, Impactor's command-line signer, from
# bitxeno's fork, which signs in to Apple where upstream fails. Its paths are from the repo root.
PLUMESIGN_URL=https://github.com/bitxeno/PlumeImpactor/releases/download/v2.7.1-patch.4/plumesign-linux-x86_64.tar.gz
PLUMESIGN_SHA256=05a98a366cdabe476760bfc5dbb53b7eb7064752a817731fc62f46cedea16cf4
PLUMESIGN_DIR=build/plumesign-v2.7.1-patch.4
PLUMESIGN_BIN=$PLUMESIGN_DIR/plumesign-linux-x86_64
# The Apple ID session, for container runs.
PLUMESIGN_DATA=${XDG_DATA_HOME:-$HOME/.local/share}/safarifix/plumesign
