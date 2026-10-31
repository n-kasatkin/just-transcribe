#!/bin/bash
# Xcode build phase: copies the fetched ostt into Contents/Helpers, signs it with the app's
# identity and hardened runtime, and bundles ostt's LICENSE as Resources/OSTT_LICENSE.
set -euo pipefail

SRC="${SRCROOT}/vendor/ostt"
if [[ ! -x "$SRC/ostt" || ! -f "$SRC/LICENSE" ]]; then
  echo "error: vendor/ostt/ostt is missing. Run scripts/fetch-ostt.sh first." >&2
  exit 1
fi

# The script sandbox lets codesign write only declared outputs, not its .cstemp file next to the
# target, so the helper is signed in a temp dir and then copied into the bundle.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$SRC/ostt" "$TMP/ostt"

# Notarization needs a secure timestamp; local builds skip the network round trip.
timestamp=--timestamp=none
[[ "$CONFIGURATION" == Release ]] && timestamp=--timestamp
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime "$timestamp" "$TMP/ostt"

HELPERS="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
mkdir -p "$HELPERS" "${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
cp -f "$TMP/ostt" "$HELPERS/ostt"
cp -f "$SRC/LICENSE" "${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/OSTT_LICENSE"
