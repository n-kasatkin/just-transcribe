#!/bin/bash
# Fetches the official ostt release for Apple Silicon at the pinned version, checks it against
# the pinned SHA-256 and unpacks it into vendor/ostt/ (binary, LICENSE, README, CHANGELOG).
# OSTT_ARCHIVE=/path/to/archive.tar.gz verifies and unpacks a local file instead of downloading.
# A rerun skips the download only when vendor/ostt/ostt still matches the pinned binary hash.
# Bumping ostt: change all three pins in one commit and rerun the smoke tests.
set -euo pipefail

OSTT_VERSION=0.0.34
OSTT_SHA256=eb2da619ef1a45d7271599000f3a96ebeedd770e897527913f0c0b803158607c
# The binary inside that archive, so a swapped vendor/ostt/ostt is never reused or embedded.
OSTT_BINARY_SHA256=59f6ebdf57243c2f78101a7012a198c680f1ef68103e5a9dfff5944e5813d89f
ASSET=ostt-aarch64-apple-darwin
URL="https://github.com/kristoferlund/ostt/releases/download/v${OSTT_VERSION}/${ASSET}.tar.gz"

cd "$(dirname "$0")/.."
DEST=vendor/ostt

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

if [[ -z "${OSTT_ARCHIVE:-}" && -x "$DEST/ostt" && "$(sha256 "$DEST/ostt")" == "$OSTT_BINARY_SHA256" ]]; then
  echo "ostt ${OSTT_VERSION} is already in ${DEST}"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ -n "${OSTT_ARCHIVE:-}" ]]; then
  cp "$OSTT_ARCHIVE" "$TMP/ostt.tar.gz"
else
  echo "Downloading ${URL}"
  curl -fsSL --retry 2 --connect-timeout 20 --max-time 600 -o "$TMP/ostt.tar.gz" "$URL"
fi

actual="$(sha256 "$TMP/ostt.tar.gz")"
if [[ "$actual" != "$OSTT_SHA256" ]]; then
  echo "error: SHA-256 mismatch for the ostt ${OSTT_VERSION} archive" >&2
  echo "  expected ${OSTT_SHA256}" >&2
  echo "  actual   ${actual}" >&2
  echo "Nothing was written to ${DEST}." >&2
  exit 1
fi

tar -xzf "$TMP/ostt.tar.gz" -C "$TMP"
for f in ostt LICENSE; do
  [[ -f "$TMP/$ASSET/$f" ]] || { echo "error: $f is missing from the archive" >&2; exit 1; }
done
if [[ "$(sha256 "$TMP/$ASSET/ostt")" != "$OSTT_BINARY_SHA256" ]]; then
  echo "error: the ostt binary in the archive does not match the pinned hash" >&2
  exit 1
fi

mkdir -p vendor
rm -rf "$DEST"
mv "$TMP/$ASSET" "$DEST"
echo "ostt ${OSTT_VERSION} unpacked into ${DEST}"
