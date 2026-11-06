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
RESULT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$WAKELINE_NOTARY_PROFILE" --wait --output-format json)
STATUS=$(printf '%s' "$RESULT" | plutil -extract status raw -o - -)
if [ "$STATUS" != "Accepted" ]; then
  SUBMISSION=$(printf '%s' "$RESULT" | plutil -extract id raw -o - -)
  echo "Apple returned: $STATUS"
  xcrun notarytool log "$SUBMISSION" --keychain-profile "$WAKELINE_NOTARY_PROFILE"
  exit 1
fi
xcrun stapler staple "$SAVER"
xcrun stapler validate "$SAVER"
ditto -c -k --keepParent "$SAVER" "$ZIP"
syspolicy_check distribution "$SAVER"
echo "Ready to share: $ZIP"
