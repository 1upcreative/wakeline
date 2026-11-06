#!/bin/bash
# Installs Wakeline for this user only. Takes a restore point first and deletes nothing.
set -euo pipefail
cd "$(dirname "$0")"
SRC="build/Wakeline.saver"
DEST="$HOME/Library/Screen Savers"
[ -d "$SRC" ] || { echo "Run ./build.sh first"; exit 1; }
mkdir -p "$DEST"
if [ -e "$DEST/Wakeline.saver" ]; then
  ROPE="$HOME/Library/Application Support/Wakeline/restore-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$ROPE"
  mv "$DEST/Wakeline.saver" "$ROPE/"
  echo "Previous copy kept at: $ROPE"
fi
ditto "$SRC" "$DEST/Wakeline.saver"
codesign --verify --deep "$DEST/Wakeline.saver"
echo "Installed. Pick Wakeline in System Settings > Screen Saver."
