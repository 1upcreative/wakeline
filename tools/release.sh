#!/bin/bash
# Signs, notarizes and staples Wakeline.saver for download.
# You need a Developer ID Application certificate and a notarytool keychain profile.
#   WAKELINE_SIGN_ID="Developer ID Application: Your Name (TEAMID)"
#   WAKELINE_NOTARY_PROFILE="your-profile-name"
set -euo pipefail
cd "$(dirname "$0")/.."
: "${WAKELINE_SIGN_ID:?Set WAKELINE_SIGN_ID}"
: "${WAKELINE_NOTARY_PROFILE:?Set WAKELINE_NOTARY_PROFILE}"
export WAKELINE_SIGN_ID
./build.sh
SAVER="build/Wakeline.saver"
ZIP="build/Wakeline.zip"
codesign --verify --strict --verbose=2 "$SAVER"
ditto -c -k --keepParent "$SAVER" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$WAKELINE_NOTARY_PROFILE" --wait
xcrun stapler staple "$SAVER"
xcrun stapler validate "$SAVER"
ditto -c -k --keepParent "$SAVER" "$ZIP"
spctl --assess --type install --verbose=2 "$SAVER"
echo "Ready to share: $ZIP"
