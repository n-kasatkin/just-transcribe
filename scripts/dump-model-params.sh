#!/bin/bash
# Writes the params every ostt model accepts (`ostt model params MODEL --format json`) to the test
# fixture Packages/JustTranscribeKit/Tests/Fixtures/model-params.json, one object per model; a model
# with no params gets an empty list. Runs vendor/ostt/ostt (scripts/fetch-ostt.sh) in a throwaway
# home, so the owner's config and keys are never read. Listing the local models fetches ostt's registry.
# Rerun after bumping ostt.
set -euo pipefail

cd "$(dirname "$0")/.."
OSTT="$PWD/vendor/ostt/ostt"
OUT=Packages/JustTranscribeKit/Tests/Fixtures/model-params.json

HOME_DIR="$(mktemp -d)"
trap 'rm -rf "$HOME_DIR"' EXIT
ostt() {
  env -i HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/config" XDG_DATA_HOME="$HOME_DIR/data" \
    XDG_STATE_HOME="$HOME_DIR/state" XDG_RUNTIME_DIR="$HOME_DIR/run" PATH=/usr/bin:/bin "$OSTT" "$@"
}

ostt model list --format json | jq -r '.[] | "\(.provider)/\(.model)"' | while read -r id; do
  # ostt exits 1 with "No params are supported" for models that take none; any other failure stops the run.
  if params="$(ostt model params "$id" --format json 2>"$HOME_DIR/stderr")"; then
    echo "$params"
  elif grep -q "No params are supported" "$HOME_DIR/stderr"; then
    jq -n --arg id "$id" '{provider: ($id | sub("/.*"; "")), model: ($id | sub("^[^/]*/"; "")), params: []}'
  else
    echo "$id: $(cat "$HOME_DIR/stderr")" >&2
    exit 1
  fi
done | jq -s 'map({provider, model, params})' > "$OUT"
echo "Wrote $(jq length "$OUT") models to $OUT"
