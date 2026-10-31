#!/bin/bash
# Writes THIRD_PARTY_NOTICES.md: ostt, every Rust crate the aarch64-apple-darwin build of ostt
# uses (with full licence texts), transcribe-cpp-sys's vendored C/C++ components, the Swift
# packages pinned in Package.resolved, and the speech model credits.
# Usage: scripts/notices.sh [OUTPUT]   (default: THIRD_PARTY_NOTICES.md at the repo root)
# OSTT_SRC=/path/to/ostt uses an existing checkout of the pinned tag instead of cloning.
# Bumping ostt: change both pins together with scripts/fetch-ostt.sh.
# Backticks in printf formats are Markdown code spans, not command substitutions.
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C

OSTT_VERSION=0.0.34
OSTT_COMMIT=b1d8fb3860b83341e36289d0c1ff398022421682
OSTT_REPO=https://github.com/kristoferlund/ostt
TARGET=aarch64-apple-darwin
# Pinned so fallback licence texts stay identical between runs.
SPDX_TEXT=https://raw.githubusercontent.com/spdx/license-list-data/v3.29.0/text

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/THIRD_PARTY_NOTICES.md}"
RESOLVED="$ROOT/Package.resolved"

die() { echo "notices.sh: $*" >&2; exit 1; }

[[ -f "$RESOLVED" ]] || die "Package.resolved is missing at the repo root; it holds the Swift package pins the notices list."
for tool in git cargo jq curl; do
  command -v "$tool" >/dev/null || die "$tool is required"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/spdx" "$TMP/swift"

fetch() { curl -fsSL --retry 2 --connect-timeout 20 --max-time 120 "$@"; }

# --- ostt source at the pinned tag ---------------------------------------------------------
if [[ -n "${OSTT_SRC:-}" ]]; then
  SRC="$OSTT_SRC"
else
  SRC="$TMP/ostt"
  git -c advice.detachedHead=false -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
    clone -q --depth 1 --branch "v$OSTT_VERSION" "$OSTT_REPO" "$SRC"
fi
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$OSTT_COMMIT" ]] || die "$SRC is not at commit $OSTT_COMMIT"
[[ "$(git -C "$SRC" rev-parse "v$OSTT_VERSION^{commit}" 2>/dev/null)" == "$OSTT_COMMIT" ]] \
  || die "$SRC has no tag v$OSTT_VERSION at commit $OSTT_COMMIT"

# Neither command writes into the checkout; fetch fills the default cargo cache.
cargo fetch --locked --quiet --manifest-path "$SRC/Cargo.toml"
cargo metadata --format-version 1 --locked --filter-platform "$TARGET" \
  --manifest-path "$SRC/Cargo.toml" >"$TMP/meta.json"

# Every package reachable from ostt over normal and build edges (dev-only edges never ship),
# one TSV row each: name, version, licence, repository, source dir, authors.
jq -r '
  (.resolve.nodes | map({key: .id, value: [.deps[] | select(any(.dep_kinds[]; .kind != "dev")) | .pkg]})
    | from_entries) as $graph
  | .resolve.root as $root
  | ({seen: {}, todo: [$root]}
     | until(.todo | length == 0;
         .todo[0] as $id
         | if .seen[$id] then .todo |= .[1:]
           else .seen[$id] = true | .todo = .todo[1:] + $graph[$id] end)
     | .seen) as $reachable
  | [.packages[] | select($reachable[.id] and .id != $root)]
  | sort_by(.name, .version)[]
  | [.name, .version, (.license // ""), (.repository // .homepage // "https://crates.io/crates/\(.name)"),
     (.manifest_path | sub("/Cargo.toml$"; "")),
     (.authors | map(sub("\\s*<[^>]*>"; "")) | join(", "))]
  | @tsv' "$TMP/meta.json" >"$TMP/crates.tsv"
OSTT_LICENCE="$(jq -r '.resolve.root as $r | .packages[] | select(.id == $r) | .license' "$TMP/meta.json")"

# --- helpers ---------------------------------------------------------------------------------
# Licence ids in an SPDX expression; the exception after WITH is not a licence.
licence_ids() {
  local tok after_with=0 toks
  read -ra toks <<<"$(tr '()/' '   ' <<<"$1")"
  for tok in "${toks[@]}"; do
    case "$tok" in
      OR | AND | or | and) ;;
      WITH | with) after_with=1 ;;
      *) if ((after_with)); then after_with=0; else echo "$tok"; fi ;;
    esac
  done
}

# Licence and notice files at the top of a source dir.
licence_files() {
  find "$1" -maxdepth 1 \( -type f -o -type l \) | sed 's|.*/||' \
    | grep -iE '^(licen[cs]e|copying|notice|copyright|unlicense)' | sort || true
}

# Real copyright lines (templates such as "Copyright [yyyy]" are skipped), deduplicated.
copyright_lines() {
  cat -- "$@" | tr -d '\r' \
    | grep -iE '^[[:space:]]*(copyright|©|\(c\)[[:space:]]*[0-9]{4})' \
    | grep -E '[0-9]{4}|\([cC]\)|©' \
    | grep -viE '\[yyyy\]|<year>|\[year\]|\{yyyy\}|\[name of' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^(©|\([cC]\))/Copyright \1/' \
    | awk '!seen[$0]++' || true
}

text_block() { # title, file
  # The fence must be longer than any backtick run that opens a line of the text.
  local fence
  fence="$(tr -d '\r' <"$2" | sed -nE 's/^ {0,3}(`+).*/\1/p' \
    | awk '{ if (length($0) > m) m = length($0) } END { n = (m < 3 ? 3 : m + 1); s = ""; for (i = 0; i < n; i++) s = s "`"; print s }')"
  printf '**%s**\n\n%stext\n' "$1" "$fence"
  tr -d '\r' <"$2" | sed -E 's/[[:space:]]+$//'
  printf '%s\n\n' "$fence"
}

# Copyright bullet lines from files, or "Copyright (c) <fallback>" when they carry none.
copyright_bullets() { # fallback, files...
  local fallback="$1" lines
  shift
  lines="$(copyright_lines "$@")"
  [[ -n "$lines" ]] || lines="Copyright (c) $fallback"
  printf -- "- %s\n" "${lines//$'\n'/$'\n- '}"
}

spdx_text() { # id -> cached path
  local f="$TMP/spdx/$1.txt"
  [[ -f "$f" ]] || fetch -o "$f" "$SPDX_TEXT/$1.txt" || die "no SPDX text for $1"
  echo "$f"
}

summary() { printf '| [%s](#%s) | %s | `%s` |\n' "$1" "$2" "$3" "$4" >>"$TMP/summary.md"; }
note_expr() { printf '%s\n' "$1" >>"$TMP/exprs.txt"; }

: >"$TMP/summary.md"
: >"$TMP/exprs.txt"

# --- ostt ----------------------------------------------------------------------------------
grep -q 'Kristofer Lund' "$SRC/LICENSE" || die "ostt LICENSE lacks the Kristofer Lund copyright"
summary ostt ostt "$OSTT_VERSION" "$OSTT_LICENCE"
note_expr "$OSTT_LICENCE"
{
  printf '<a id="ostt"></a>\n## ostt %s\n\n' "$OSTT_VERSION"
  printf 'just transcribe bundles the official, unmodified ostt %s release for %s as `Contents/Helpers/ostt`.\n\n' "$OSTT_VERSION" "$TARGET"
  printf -- '- Licence: `%s`\n- Repository: <%s>\n- Release: <%s/releases/tag/v%s> (commit `%s`)\n' \
    "$OSTT_LICENCE" "$OSTT_REPO" "$OSTT_REPO" "$OSTT_VERSION" "$OSTT_COMMIT"
  copyright_bullets "Kristofer Lund" "$SRC/LICENSE"
  echo
  text_block LICENSE "$SRC/LICENSE"
} >"$TMP/ostt.md"

# --- Rust crates -----------------------------------------------------------------------------
crate_count=0
: >"$TMP/crates.md"
while IFS=$'\t' read -r name version licence repo dir authors; do
  [[ -n "$licence" ]] || die "$name $version declares no SPDX licence"
  anchor="crate-$name-$version"
  summary "$name" "$anchor" "$version" "$licence"
  note_expr "$licence"
  files=()
  while IFS= read -r f; do files+=("$dir/$f"); done < <(licence_files "$dir")
  {
    printf '<a id="%s"></a>\n### %s %s\n\n' "$anchor" "$name" "$version"
    printf -- '- Licence: `%s`\n- Repository: <%s>\n' "$licence" "$repo"
    if [[ "$licence" == *MPL-2.0* ]]; then
      printf -- '- Source code: <https://crates.io/crates/%s/%s> (archive: <https://static.crates.io/crates/%s/%s-%s.crate>)\n' \
        "$name" "$version" "$name" "$name" "$version"
    fi
    if ((${#files[@]})); then
      copyright_bullets "${authors:-The $name developers}" "${files[@]}"
      echo
      for f in "${files[@]}"; do text_block "${f##*/}" "$f"; done
    else
      printf -- '- Copyright (c) %s\n\n' "${authors:-The $name developers}"
      printf 'The crate ships no licence file; the standard SPDX texts follow.\n\n'
      while IFS= read -r id; do text_block "$id (SPDX standard text)" "$(spdx_text "$id")"; done \
        < <(licence_ids "$licence" | awk '!seen[$0]++')
    fi
  } >>"$TMP/crates.md"
  crate_count=$((crate_count + 1))
done <"$TMP/crates.tsv"

# --- transcribe-cpp-sys vendored components -------------------------------------------------
TCS_DIR="$(awk -F'\t' '$1 == "transcribe-cpp-sys" {print $5}' "$TMP/crates.tsv")"
TCS_VERSION="$(awk -F'\t' '$1 == "transcribe-cpp-sys" {print $2}' "$TMP/crates.tsv")"
[[ -n "$TCS_DIR" && -f "$TCS_DIR/THIRD-PARTY-LICENSES.md" ]] || die "transcribe-cpp-sys or its THIRD-PARTY-LICENSES.md not found"
{
  printf '<a id="vendored-transcribe-cpp"></a>\n### transcribe.cpp (in transcribe-cpp-sys %s)\n\n' "$TCS_VERSION"
  printf -- '- Licence: `MIT`\n- Repository: <%s>\n' "$(awk -F'\t' '$1 == "transcribe-cpp-sys" {print $4}' "$TMP/crates.tsv")"
  copyright_bullets "The transcribe.cpp authors" "$TCS_DIR/LICENSE"
  echo
  text_block LICENSE "$TCS_DIR/LICENSE"
} >"$TMP/vendored.md"
summary transcribe.cpp vendored-transcribe-cpp "$TCS_VERSION" MIT
note_expr MIT

# Rows of the component table: | Name | Licence | [`path`](path) | Pin |
vendored=0
while IFS='|' read -r _ comp lic path _; do
  comp="$(sed -E 's/^ +| +$//g' <<<"$comp")"
  lic="$(sed -E 's/^ +| +$//g' <<<"$lic")"
  path="$(sed -E 's/.*\]\(([^)]*)\).*/\1/' <<<"$path")"
  [[ -f "$TCS_DIR/$path" ]] || die "vendored licence $path for $comp not found"
  anchor="vendored-$(tr "[:upper:] " "[:lower:]-" <<<"$comp")"
  summary "$comp" "$anchor" "in transcribe-cpp-sys $TCS_VERSION" "$lic"
  note_expr "$lic"
  {
    printf '<a id="%s"></a>\n### %s (vendored in transcribe-cpp-sys %s)\n\n' "$anchor" "$comp" "$TCS_VERSION"
    printf -- '- Licence: `%s`\n' "$lic"
    copyright_bullets "The $comp authors" "$TCS_DIR/$path"
    echo
    text_block "$path" "$TCS_DIR/$path"
  } >>"$TMP/vendored.md"
  vendored=$((vendored + 1))
done < <(grep -E '^\| *[^ |-][^|]*\|[^|]*\| *\[`' "$TCS_DIR/THIRD-PARTY-LICENSES.md")
((vendored)) || die "no components parsed from transcribe-cpp-sys THIRD-PARTY-LICENSES.md"

# --- Swift packages --------------------------------------------------------------------------
: >"$TMP/swift.md"
swift_count=0
while IFS=$'\t' read -r location version revision; do
  slug="$(sed -E 's#^https://github\.com/##; s#\.git$##; s#/$##' <<<"$location")"
  [[ "$slug" =~ ^[^/]+/[^/]+$ ]] || die "only GitHub packages are supported: $location"
  repo="${slug#*/}"
  text="$TMP/swift/$repo.txt"
  found=""
  for name in LICENSE license LICENSE.md license.md; do
    if fetch -o "$text" "https://raw.githubusercontent.com/$slug/$revision/$name" 2>/dev/null; then
      found="$name"
      break
    fi
  done
  [[ -n "$found" ]] || die "no licence file for $slug at $revision"
  spdx="$(fetch "https://api.github.com/repos/$slug/license?ref=$revision" | jq -r '.license.spdx_id // empty')"
  [[ -n "$spdx" && "$spdx" != NOASSERTION ]] || die "GitHub reports no SPDX licence for $slug"
  anchor="swift-$(tr "[:upper:]" "[:lower:]" <<<"$repo")"
  summary "$repo" "$anchor" "$version" "$spdx"
  note_expr "$spdx"
  {
    printf '<a id="%s"></a>\n### %s %s\n\n' "$anchor" "$repo" "$version"
    printf -- '- Licence: `%s`\n- Repository: <https://github.com/%s> (revision `%s`)\n' "$spdx" "$slug" "$revision"
    copyright_bullets "${slug%%/*}" "$text"
    echo
    text_block "$found" "$text"
  } >>"$TMP/swift.md"
  swift_count=$((swift_count + 1))
done < <(jq -r '.pins | sort_by(.identity)[] | [.location, (.state.version // .state.branch // .state.revision), .state.revision] | @tsv' "$RESOLVED")

# --- licence gate ----------------------------------------------------------------------------
copyleft=""
while IFS= read -r expr; do
  while IFS= read -r id; do
    if [[ "$id" =~ ^(AGPL|LGPL|GPL)(-|\+|$) ]]; then copyleft+="$expr"$'\n'; fi
  done < <(licence_ids "$expr")
done < <(sort -u "$TMP/exprs.txt")
echo "Licence expressions found (count, expression):"
sort "$TMP/exprs.txt" | uniq -c
[[ -z "$copyleft" ]] || die "GPL-family licences found: $(sort -u <<<"$copyleft" | tr '\n' ';')"

# --- assemble --------------------------------------------------------------------------------
{
  cat <<EOF
# Third-party notices

This file covers the third-party software that ships in just transcribe.app. just transcribe itself is MIT-licensed; see LICENSE.

Generated by \`scripts/notices.sh\` from ostt $OSTT_VERSION (commit \`$OSTT_COMMIT\`) for $TARGET and the repo's \`Package.resolved\`. Do not edit by hand.

Contents:

1. [ostt](#ostt): the bundled transcription helper.
2. [Rust crates](#rust-crates): $crate_count packages from ostt's \`Cargo.lock\` that its $TARGET build uses.
3. [Vendored C/C++ components](#vendored): transcribe.cpp and the components it vendors, built into ostt by transcribe-cpp-sys.
4. [Swift packages](#swift-packages): $swift_count packages built into the app.
5. [Speech models](#speech-models): credits for the optional offline models.

## Summary

| Package | Version | Licence |
|---|---|---|
EOF
  cat "$TMP/summary.md"
  echo
  cat "$TMP/ostt.md"
  printf '<a id="rust-crates"></a>\n## Rust crates\n\nEvery package in ostt %s'"'"'s `Cargo.lock` that its %s build uses through normal or build dependencies. For dual- or multi-licensed crates, all licence texts the crate ships are included.\n\n' "$OSTT_VERSION" "$TARGET"
  cat "$TMP/crates.md"
  printf '<a id="vendored"></a>\n## Vendored C/C++ components\n\nThe transcribe-cpp-sys crate compiles transcribe.cpp and the components listed in its `THIRD-PARTY-LICENSES.md` into ostt.\n\n'
  cat "$TMP/vendored.md"
  printf '<a id="swift-packages"></a>\n## Swift packages\n\n'
  cat "$TMP/swift.md"
  cat <<'EOF'
<a id="speech-models"></a>
## Speech models

No model ships in just transcribe.app or in ostt. ostt downloads an offline model only when you choose one; each model keeps its own licence.

- **Whisper** by OpenAI, MIT licence: <https://github.com/openai/whisper>
- **Parakeet** by NVIDIA, CC-BY-4.0 licence: <https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3>
EOF
} >"$TMP/notices.md"

mkdir -p "$(dirname "$OUT")"
chmod 644 "$TMP/notices.md"
mv "$TMP/notices.md" "$OUT"
echo "Wrote $OUT: ostt, $crate_count crates, $((vendored + 1)) vendored components, $swift_count Swift packages"
