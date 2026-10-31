#!/bin/bash
# Fetches the official ostt release for Apple Silicon at the pinned version, checks it against
# the pinned SHA-256 and unpacks it into vendor/ostt/ (binary, LICENSE, README, CHANGELOG).
# OSTT_ARCHIVE=/path/to/archive.tar.gz verifies and unpacks a local file instead of downloading.
# vendor/ostt/VERSION records the version, the archive hash and the unpacked binary's hash; a
# rerun skips only when the binary on disk still has that hash.
# Bumping ostt: change both pins in one commit and rerun the smoke tests.
set -euo pipefail

OSTT_VERSION=0.0.34
OSTT_SHA256=eb2da619ef1a45d7271599000f3a96ebeedd770e897527913f0c0b803158607c
ASSET=ostt-aarch64-apple-darwin
URL="https://github.com/kristoferlund/ostt/releases/download/v${OSTT_VERSION}/${ASSET}.tar.gz"

cd "$(dirname "$0")/.."
DEST=vendor/ostt
STAMP="${OSTT_VERSION} ${OSTT_SHA256}"

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

if [[ -z "${OSTT_ARCHIVE:-}" && -x "$DEST/ostt" && -f "$DEST/VERSION" \
  && "$(cat "$DEST/VERSION")" == "${STAMP} $(sha256 "$DEST/ostt")" ]]; then
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
echo "${STAMP} $(sha256 "$TMP/$ASSET/ostt")" > "$TMP/$ASSET/VERSION"

mkdir -p vendor
rm -rf "$DEST"
mv "$TMP/$ASSET" "$DEST"
echo "ostt ${OSTT_VERSION} unpacked into ${DEST}"
