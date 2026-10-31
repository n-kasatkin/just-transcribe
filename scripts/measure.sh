#!/bin/bash
# Measures the numbers the README quotes and writes them to docs/measurements.md: DMG size,
# installed size, the ostt helper's share, and the idle memory, CPU and threads of the app.
# Usage: scripts/measure.sh
# Builds Release signed with Apple Development under the .dev bundle id, without the injected
# get-task-allow so it passes release.sh's app checks, so measuring never needs the Developer ID cert and never creates preferences or privacy grants for the release
# id. The DMG is built the way scripts/release.sh builds it, unsigned (signing adds a few KB).
# The idle run launches the app once in the background with onboarding marked done and empty
# temp XDG dirs, so it opens no window and never reads the owner's ostt config. It presses no
# keys and grants nothing; afterwards the onboarding key is put back as it was.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=release.sh
source "$(dirname "${BASH_SOURCE[0]}")/release.sh"

MEASURE_ID=dev.actionhook.justtranscribe.dev
ONBOARDING_KEY=onboardingCompleted
OUT_DOC="$ROOT/docs/measurements.md"
WORK="$(mktemp -d)"
APP="$ROOT/.derivedData/Build/Products/Release/$APP_NAME.app"

PID=""
ONBOARDING_BEFORE=""
cleanup() {
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then kill -TERM "$PID"; fi
  restore_onboarding
  rm -rf "$WORK"
}
trap cleanup EXIT

build() {
  local mac_id
  stage "Bootstrap and Release build (Apple Development, $MEASURE_ID)"
  "$ROOT/scripts/bootstrap.sh"
  # This Mac by id, the destination its build tooling accepts for a local build.
  mac_id="$(system_profiler SPHardwareDataType 2>/dev/null | awk '/Provisioning UDID/ {print $3}')"
  [[ -n "$mac_id" ]] || die "cannot read this Mac's Provisioning UDID from system_profiler"
  xcodebuild build -quiet -project "$ROOT/JustTranscribe.xcodeproj" -scheme JustTranscribe \
    -configuration Release -destination "platform=macOS,id=$mac_id" -derivedDataPath "$ROOT/.derivedData" \
    CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$TEAM_ID" \
    PRODUCT_BUNDLE_IDENTIFIER="$MEASURE_ID" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
  [[ "$(defaults read "$APP/Contents/Info.plist" CFBundleIdentifier)" == "$MEASURE_ID" ]] \
    || die "the build at $APP is not $MEASURE_ID"
  check_app "$APP" "Apple Development"
}

sizes() {
  stage "Sizes"
  make_dmg "$APP" "$WORK/$DMG_NAME"
  DMG_BYTES="$(stat -f %z "$WORK/$DMG_NAME")"
  APP_DU_H="$(du -sh "$APP" | awk '{print $1}')"
  APP_KB="$(du -sk "$APP" | awk '{print $1}')"
  HELPER_KB="$(du -sk "$APP/Contents/Helpers/ostt" | awk '{print $1}')"
  APP_BIN_KB="$(du -sk "$APP/Contents/MacOS" | awk '{print $1}')"
  echo "  DMG $DMG_BYTES bytes; app $APP_KB KB ($APP_DU_H), helper $HELPER_KB KB, app binary $APP_BIN_KB KB"
}

restore_onboarding() {
  [[ -n "$ONBOARDING_BEFORE" ]] || return 0
  if [[ "$ONBOARDING_BEFORE" == absent ]]; then
    defaults delete "$MEASURE_ID" "$ONBOARDING_KEY" 2>/dev/null || true
  else
    defaults write "$MEASURE_ID" "$ONBOARDING_KEY" -bool "$ONBOARDING_BEFORE"
  fi
  ONBOARDING_BEFORE=""
}

idle() {
  local xdg="$WORK/xdg" v i rss top_line ps_line exe="$APP/Contents/MacOS/just-transcribe"
  stage "Idle footprint"
  pgrep -f "^$exe" >/dev/null && die "a copy of $APP is already running; quit it first"
  if v="$(defaults read "$MEASURE_ID" "$ONBOARDING_KEY" 2>/dev/null)"; then
    ONBOARDING_BEFORE="$([[ "$v" == 1 ]] && echo YES || echo NO)"
  else
    ONBOARDING_BEFORE=absent
  fi
  defaults write "$MEASURE_ID" "$ONBOARDING_KEY" -bool YES
  mkdir -p "$xdg/config" "$xdg/data"
  open -g -n --env "XDG_CONFIG_HOME=$xdg/config" --env "XDG_DATA_HOME=$xdg/data" "$APP"
  for _ in {1..20}; do
    PID="$(pgrep -n -f "^$exe" || true)"
    [[ -n "$PID" ]] && break
    sleep 0.5
  done
  [[ -n "$PID" ]] || die "the app did not start"
  echo "  pid $PID; settling 20 s"
  sleep 20
  RSS_KB=()
  for i in 1 2 3; do
    rss="$(ps -o rss= -p "$PID" | tr -d ' ')"
    RSS_KB+=("$rss")
    echo "  RSS sample $i: $rss KB"
    if ((i < 3)); then sleep 5; fi
  done
  FOOTPRINT="$(footprint -p "$PID" 2>/dev/null | sed -nE 's/.*Footprint: ([0-9.]+ [KMG]B).*/\1/p' | head -1)"
  top_line="$(top -l 3 -pid "$PID" -stats pid,cpu,mem | awk -v p="$PID" '$1 == p' | tail -1)"
  CPU="$(awk '{print $2}' <<<"$top_line")"
  TOP_MEM="$(awk '{print $3}' <<<"$top_line")"
  THREADS="$(($(ps -M -p "$PID" | wc -l) - 1))"
  ps_line="$(ps -o pid=,ppid=,comm= -ax | awk -v p="$PID" '$2 == p')"
  CHILDREN="${ps_line:-none}"
  echo "  footprint $FOOTPRINT; top CPU $CPU% MEM $TOP_MEM; threads $THREADS; children: $CHILDREN"
  [[ -z "$ps_line" ]] || die "the idle app has child processes: $ps_line"

  kill -TERM "$PID"
  for _ in {1..20}; do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
  kill -0 "$PID" 2>/dev/null && die "the app did not quit on SIGTERM"
  PID=""
  restore_onboarding
}

mb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1000000 }'; }
mib_kb() { awk -v k="$1" 'BEGIN { printf "%.1f", k / 1024 }'; }

write_doc() {
  local commit macos rss_list
  commit="$(git -C "$ROOT" rev-parse --short HEAD)"
  macos="$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  rss_list="$(printf '%s KB, ' "${RSS_KB[@]}")"
  cat >"$OUT_DOC" <<EOF
# Measurements

The numbers behind "light" in the README, measured by \`scripts/measure.sh\`.

- Date: $(date +%Y-%m-%d)
- Machine: Apple Silicon Mac ($(uname -m)), macOS $macos
- Build: commit \`$commit\`, Release configuration, arm64, ostt $(ostt_version) helper, $(xcodebuild -version | head -1). Signed with Apple Development under the bundle id \`$MEASURE_ID\` instead of Developer ID; code and resources are the same as a release build.
- DMG: built like \`scripts/release.sh\` (UDZO, HFS+, the app and an Applications link), unsigned.

## Size

| What | Raw | Rounded |
|---|---|---|
| DMG (\`ls -l\`) | $DMG_BYTES bytes | $(mb "$DMG_BYTES") MB |
| Installed app (\`du -sk\`) | $APP_KB KB | $(mib_kb "$APP_KB") MiB (\`du -sh\`: $APP_DU_H) |
| ostt helper, \`Contents/Helpers/ostt\` (\`du -sk\`) | $HELPER_KB KB | $(mib_kb "$HELPER_KB") MiB, $(awk -v h="$HELPER_KB" -v a="$APP_KB" 'BEGIN { printf "%.0f", 100 * h / a }')% of the app |
| App executable, \`Contents/MacOS\` (\`du -sk\`) | $APP_BIN_KB KB | $(mib_kb "$APP_BIN_KB") MiB |

## Idle

Launched once in the background (\`open -g -n\`), onboarding marked done, empty temp \`XDG_CONFIG_HOME\` and \`XDG_DATA_HOME\` (no engine set up), no window open, measured after 20 s.

| What | Value |
|---|---|
| RSS (\`ps -o rss=\`, 3 samples 5 s apart) | ${rss_list%, } |
| Physical footprint (\`footprint -p\`) | ${FOOTPRINT:-n/a} |
| CPU (\`top -l 3 -stats pid,cpu,mem\`, last sample) | $CPU% |
| Memory (\`top\`, same sample) | $TOP_MEM |
| Threads (\`ps -M\`) | $THREADS |
| Child processes, ostt included (\`ps -o pid,ppid,comm -ax\`, by parent PID) | $CHILDREN |

## Commands

\`\`\`sh
scripts/bootstrap.sh
xcodebuild build -project JustTranscribe.xcodeproj -scheme JustTranscribe -configuration Release \\
  -destination "platform=macOS,id=<this Mac's Provisioning UDID>" -derivedDataPath .derivedData \\
  CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=$TEAM_ID \\
  PRODUCT_BUNDLE_IDENTIFIER=$MEASURE_ID CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
hdiutil create -volname "just transcribe" -srcfolder <app + Applications link> -fs HFS+ -format UDZO just-transcribe.dmg
ls -l just-transcribe.dmg
du -sh "just transcribe.app"; du -sk "just transcribe.app" "just transcribe.app/Contents/Helpers/ostt"
defaults write $MEASURE_ID $ONBOARDING_KEY -bool YES
open -g -n --env XDG_CONFIG_HOME=<tmp> --env XDG_DATA_HOME=<tmp> "just transcribe.app"
ps -o rss= -p <pid>            # 3 times, 5 s apart, after 20 s
footprint -p <pid>
top -l 3 -pid <pid> -stats pid,cpu,mem
ps -M -p <pid>
ps -o pid=,ppid=,comm= -ax     # children of <pid>
kill -TERM <pid>
defaults delete $MEASURE_ID $ONBOARDING_KEY
\`\`\`
EOF
  echo "Wrote $OUT_DOC"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  build
  sizes
  idle
  write_doc
fi
