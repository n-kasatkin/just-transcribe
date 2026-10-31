#!/bin/bash
# Builds, checks, notarizes and staples dist/just-transcribe.dmg for a release, on the owner's Mac
# so the Developer ID key never leaves the Keychain.
# Usage: scripts/release.sh [--publish] VERSION
#   Without --publish it stops after printing the `gh release create` command; with it, it runs it.
# Needs: a "Developer ID Application" identity of team 3V43DGM2S6 in the Keychain, the notarytool
# keychain profile just-transcribe-notary, and gh logged in as n-kasatkin.
# Sourcing the script only defines its functions (scripts/measure.sh reuses make_dmg).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The project's team; set TEAM_ID in the environment to use your own.
TEAM_ID="${TEAM_ID:-3V43DGM2S6}"
NOTARY_PROFILE=just-transcribe-notary
GH_OWNER=n-kasatkin
GH_REPO=n-kasatkin/just-transcribe
APP_NAME="just transcribe"
DMG_NAME=just-transcribe.dmg
DIST="$ROOT/dist"

die() { echo "release.sh: $*" >&2; exit 1; }
stage() { printf '\n==> %s\n' "$*"; }

ostt_version() { sed -n 's/^OSTT_VERSION=//p' "$ROOT/scripts/fetch-ostt.sh"; }
marketing_version() { sed -nE 's/^ *MARKETING_VERSION: *"?([^" ]*)"?.*/\1/p' "$ROOT/project.yml"; }

# --- preflight -------------------------------------------------------------------------------
preflight() { # version
  local version="$1" current
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must look like 1.2.3, got '$version'"
  [[ -z "$(git -C "$ROOT" status --porcelain)" ]] \
    || die "the git tree is not clean; commit or stash first (git status --short)"
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
    die "tag v$version already exists locally"
  fi
  if git -C "$ROOT" remote get-url origin >/dev/null 2>&1 \
    && [[ -n "$(git -C "$ROOT" ls-remote --tags origin "refs/tags/v$version")" ]]; then
    die "tag v$version already exists on origin"
  fi
  current="$(marketing_version)"
  [[ "$current" == "$version" ]] \
    || die "VERSION $version does not match MARKETING_VERSION \"$current\" in project.yml. To bump, set MARKETING_VERSION: \"$version\" (and raise CURRENT_PROJECT_VERSION) in project.yml, commit, then rerun."
  [[ -n "$(developer_id)" ]] \
    || die "no valid 'Developer ID Application: … ($TEAM_ID)' signing identity in the Keychain. Create it in Xcode > Settings > Accounts > Manage Certificates (Account Holder), then rerun."
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "notarytool keychain profile '$NOTARY_PROFILE' is missing or rejected. Create it with: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple ID> --team-id $TEAM_ID"
  gh_token >/dev/null 2>&1 \
    || die "gh has no login for $GH_OWNER. Run: gh auth login --hostname github.com (as $GH_OWNER)"
  [[ "$(GH_TOKEN="$(gh_token)" gh api user --jq .login 2>/dev/null)" == "$GH_OWNER" ]] \
    || die "the stored gh token for $GH_OWNER does not authenticate as $GH_OWNER. Run: gh auth refresh --hostname github.com --user $GH_OWNER"
}

# SHA-1 of the team's Developer ID Application identity, so another team's never signs.
developer_id() {
  security find-identity -v -p codesigning \
    | awk -v team="($TEAM_ID)\"" '/"Developer ID Application: / && index($0, team) {print $2; exit}'
}

# gh may hold several accounts; the release always uses n-kasatkin's token, whichever is active.
gh_token() { gh auth token --hostname github.com --user "$GH_OWNER"; }

# --- build -----------------------------------------------------------------------------------
check_notices() { # work dir
  "$ROOT/scripts/notices.sh" "$1/THIRD_PARTY_NOTICES.md" >/dev/null
  cmp -s "$1/THIRD_PARTY_NOTICES.md" "$ROOT/THIRD_PARTY_NOTICES.md" \
    || die "THIRD_PARTY_NOTICES.md is stale. Run scripts/notices.sh, commit the result, then rerun."
}

archive_and_export() { # work dir -> exported app at <work>/export/<APP_NAME>.app
  local work="$1"
  xcodebuild archive -quiet -project "$ROOT/JustTranscribe.xcodeproj" -scheme JustTranscribe \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$ROOT/.derivedData" -archivePath "$work/JustTranscribe.xcarchive" \
    DEVELOPMENT_TEAM="$TEAM_ID" # package targets such as KeyboardShortcuts' resource bundle need it to sign
  cat >"$work/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
</dict>
</plist>
EOF
  xcodebuild -exportArchive -quiet -archivePath "$work/JustTranscribe.xcarchive" \
    -exportPath "$work/export" -exportOptionsPlist "$work/ExportOptions.plist"
  [[ -d "$work/export/$APP_NAME.app" ]] || die "export produced no '$APP_NAME.app' in $work/export"
}

# --- checks ----------------------------------------------------------------------------------
check_signature() { # file, expected authority prefix, [runtime: 1 to require the flag]
  local info
  info="$(codesign -dvv "$1" 2>&1)" || die "codesign cannot read the signature of $1"
  grep -q "^Authority=$2" <<<"$info" || die "$1: no 'Authority=$2' line"
  grep -q '^Timestamp=' <<<"$info" || die "$1: no secure timestamp (Timestamp= line)"
  if [[ "${3:-0}" == 1 ]] && ! grep -qE '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<<"$info"; then
    die "$1: hardened runtime flag is missing"
  fi
  grep -E '^(Authority|Timestamp|CodeDirectory|TeamIdentifier|Identifier)=?' <<<"$info" \
    | grep -vE '^Authority=(Apple|Developer ID) (Root|Certification)' | sed 's/^/    /'
}

check_entitlements() { # file, required entitlement or ""
  local ents
  ents="$(codesign -d --entitlements - --xml "$1" 2>/dev/null)" || true
  if [[ -n "$2" ]]; then
    grep -q "<key>$2</key><true/>" <<<"$ents" || die "$1: entitlement $2 is missing"
  fi
  if grep -q 'com.apple.security.get-task-allow' <<<"$ents"; then
    die "$1: carries get-task-allow, which notarization rejects"
  fi
  echo "    entitlements: ${2:-none required}; no get-task-allow"
}

check_app() { # app, expected authority prefix
  local app="$1" helper="$1/Contents/Helpers/ostt" xdg out expected
  [[ -x "$helper" ]] || die "$helper is missing"
  echo "  app:"
  check_signature "$app" "$2" 1
  check_entitlements "$app" com.apple.security.device.audio-input
  # The helper transcribes recorded files; only the app opens the microphone.
  echo "  Helpers/ostt:"
  check_signature "$helper" "$2" 1
  check_entitlements "$helper" ""
  codesign --verify --deep --strict --verbose=2 "$app" 2>&1 | sed 's/^/    /'
  # Never touch the owner's ostt config or data.
  xdg="$(mktemp -d)"
  out="$(XDG_CONFIG_HOME="$xdg/config" XDG_DATA_HOME="$xdg/data" \
    perl -e 'alarm 20; exec @ARGV' -- "$helper" --version 2>&1)" || { rm -rf "$xdg"; die "$helper --version failed: $out"; }
  rm -rf "$xdg"
  expected="ostt $(ostt_version)"
  [[ "$out" == "$expected" ]] || die "bundled helper reports '$out', expected '$expected'"
  echo "    helper --version: $out"
}

# --- DMG -------------------------------------------------------------------------------------
make_dmg() { # app, output dmg, [signing identity]
  local app="$1" dmg="$2" staging
  staging="$(mktemp -d)"
  ditto "$app" "$staging/$APP_NAME.app"
  ln -s /Applications "$staging/Applications"
  mkdir -p "$(dirname "$dmg")"
  rm -f "$dmg"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$staging" -fs HFS+ -format UDZO "$dmg"
  rm -rf "$staging"
  if [[ -n "${3:-}" ]]; then
    codesign --sign "$3" --timestamp "$dmg"
  fi
}

notarize() { # dmg
  local result status id
  result="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist)" \
    || die "notarytool submit failed"
  status="$(plutil -extract status raw - <<<"$result")"
  id="$(plutil -extract id raw - <<<"$result")"
  echo "  submission $id: $status"
  if [[ "$status" != Accepted ]]; then
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
    die "notarization ended with status $status"
  fi
}

check_gatekeeper() { # stapled dmg
  local out mnt
  out="$(spctl -a -vvv -t install "$1" 2>&1)" || die "spctl rejects the DMG: $out"
  grep -q 'source=Notarized Developer ID' <<<"$out" || die "DMG is not 'Notarized Developer ID': $out"
  echo "    DMG: $(grep '^source=' <<<"$out")"
  mnt="$(mktemp -d)"
  hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mnt" "$1"
  out="$(spctl -a -vvv "$mnt/$APP_NAME.app" 2>&1)" || { hdiutil detach -quiet "$mnt"; die "spctl rejects the app in the DMG: $out"; }
  hdiutil detach -quiet "$mnt"
  rmdir "$mnt"
  grep -q 'source=Notarized Developer ID' <<<"$out" || die "app is not 'Notarized Developer ID': $out"
  echo "    app: $(grep '^source=' <<<"$out")"
}

# --- notes and publish -----------------------------------------------------------------------
write_notes() { # version, sha256, output
  local notes changes previous
  previous="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
  if [[ -n "$previous" ]]; then
    changes="$(git -C "$ROOT" log --no-merges --format='- %s' "$previous..HEAD")"
  else
    changes="- First release."
  fi
  notes="$(<"$ROOT/docs/release-notes-template.md")"
  notes="${notes//\{\{VERSION\}\}/$1}"
  notes="${notes//\{\{OSTT_VERSION\}\}/$(ostt_version)}"
  notes="${notes//\{\{SHA256\}\}/$2}"
  notes="${notes//\{\{CHANGES\}\}/$changes}"
  printf '%s\n' "$notes" >"$3"
}

main() {
  local publish=0 version="" work app dmg sha commit
  while (($#)); do
    case "$1" in
      --publish) publish=1 ;;
      -h | --help) sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
      -*) die "unknown option $1" ;;
      *) [[ -z "$version" ]] || die "only one VERSION"; version="$1" ;;
    esac
    shift
  done
  [[ -n "$version" ]] || die "usage: scripts/release.sh [--publish] VERSION"

  stage "Preflight"
  preflight "$version"
  commit="$(git -C "$ROOT" rev-parse HEAD)"

  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT

  stage "Bootstrap: ostt helper, Xcode project, package pins"
  "$ROOT/scripts/bootstrap.sh"

  stage "THIRD_PARTY_NOTICES.md is current"
  check_notices "$work"

  stage "Archive and export (Developer ID)"
  archive_and_export "$work"
  app="$work/export/$APP_NAME.app"
  [[ "$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString)" == "$version" ]] \
    || die "the exported app's CFBundleShortVersionString is not $version"

  stage "Check signatures"
  check_app "$app" "Developer ID Application"
  if command -v syspolicy_check >/dev/null; then
    syspolicy_check notary-submission "$app"
  else
    echo "  syspolicy_check is not on this macOS; the notary service checks the app instead"
  fi

  stage "DMG"
  rm -rf "$DIST"
  dmg="$DIST/$DMG_NAME"
  make_dmg "$app" "$dmg" "$(developer_id)"
  check_signature "$dmg" "Developer ID Application"

  stage "Notarize and staple"
  notarize "$dmg"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  check_gatekeeper "$dmg"

  stage "Checksum and notes"
  sha="$(shasum -a 256 "$dmg" | awk '{print $1}')"
  (cd "$DIST" && shasum -a 256 "$DMG_NAME" >"$DMG_NAME.sha256")
  write_notes "$version" "$sha" "$DIST/release-notes.md"
  echo "  $DIST/$DMG_NAME.sha256: $sha"
  echo "  $DIST/release-notes.md"

  local cmd=(gh release create "v$version" "dist/$DMG_NAME" "dist/$DMG_NAME.sha256"
    --repo "$GH_REPO" --target "$commit" --title "$APP_NAME $version" --notes-file dist/release-notes.md)
  stage "Publish"
  # Printed literally, so the token is fetched when the command runs, never shown here.
  # shellcheck disable=SC2016
  printf 'GH_TOKEN="$(gh auth token --hostname github.com --user %s)" %s\n' "$GH_OWNER" "$(printf '%q ' "${cmd[@]}")"
  if ((publish)); then
    (cd "$ROOT" && GH_TOKEN="$(gh_token)" "${cmd[@]}")
  else
    echo "Not published. Rerun with --publish, or run the command above from the repo root."
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
