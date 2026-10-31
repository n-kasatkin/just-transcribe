#!/bin/bash
# Writes THIRD_PARTY_NOTICES.md: ostt with its full licence, every Rust crate the
# aarch64-apple-darwin build of ostt compiles (copyright lines plus a reference to each distinct
# licence text, printed once), the vendored C/C++ components (transcribe-cpp-sys's and the
# SQLite bundled by libsqlite3-sys), the Swift packages pinned in Package.resolved, and the
# speech model credits.
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
mkdir -p "$TMP/spdx" "$TMP/swift" "$TMP/texts"

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

# The crates the target build compiles over normal and build edges. cargo tree applies features
# and platform cfgs; resolve.nodes in the metadata also lists disabled optional dependencies.
cargo tree --locked -e normal,build --target "$TARGET" --prefix none \
  --manifest-path "$SRC/Cargo.toml" \
  | sed -E 's/ \(.*$//' | grep -vxF "ostt v$OSTT_VERSION" | sort -u >"$TMP/tree.txt"

# One TSV row per crate: name, version, licence, repository, source dir, authors.
jq -r --rawfile tree "$TMP/tree.txt" '
  ($tree | split("\n") | map(select(. != "") | {key: ., value: true}) | from_entries) as $keep
  | [.packages[] | select($keep["\(.name) v\(.version)"])]
  | sort_by(.name, .version)[]
  | [.name, .version, (.license // ""), (.repository // .homepage // "https://crates.io/crates/\(.name)"),
     (.manifest_path | sub("/Cargo.toml$"; "")),
     (.authors | map(sub("\\s*<[^>]*>"; "")) | join(", "))]
  | @tsv' "$TMP/meta.json" >"$TMP/crates.tsv"
tree_count="$(wc -l <"$TMP/tree.txt" | tr -d ' ')"
crate_rows="$(wc -l <"$TMP/crates.tsv" | tr -d ' ')"
echo "Crates: cargo tree $tree_count, metadata matches $crate_rows"
((tree_count == crate_rows)) || die "cargo tree and cargo metadata disagree on the crate set"
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

# The text without its copyright lines (same test as copyright_lines, minus the template filter).
strip_copyright() {
  tr -d '\r' <"$1" | perl -ne 'print unless /^\s*(copyright|©|\(c\)\s*\d{4})/i && /\d{4}|\(c\)|©/i'
}

# Registers a licence text once per identity (copyright lines and whitespace removed) and sets
# REF to its link. Returns 1 when nothing but copyright lines is left.
text_count=0
register_text() { # label, file, user
  local hash n body="$TMP/body.txt"
  strip_copyright "$2" | sed '/[^[:space:]]/,$!d' >"$body"
  [[ -n "$(tr -d '[:space:]' <"$body")" ]] || return 1
  hash="$(tr -d '[:space:]' <"$body" | shasum -a 256 | awk '{print $1}')"
  if [[ -f "$TMP/texts/$hash" ]]; then
    n="$(cat "$TMP/texts/$hash")"
  else
    text_count=$((text_count + 1))
    n=$text_count
    echo "$n" >"$TMP/texts/$hash"
    {
      printf '<a id="licence-text-%s"></a>\n### Licence text %s\n\n' "$n" "$n"
      printf 'First seen as `%s` in %s. Copyright lines are listed with each crate.\n\n' "$1" "$3"
      text_block "$1" "$body"
    } >>"$TMP/texts.md"
  fi
  REF="$1 ([text $n](#licence-text-$n))"
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
  printf 'just transcribe bundles the official ostt %s release for %s as `Contents/Helpers/ostt`, with its code unmodified. `scripts/embed-ostt.sh` re-signs it with the app'"'"'s signing identity and the hardened runtime, as notarization requires, so its SHA-256 differs from the release binary'"'"'s. After `codesign --remove-signature` on both copies, they differ only in the `__LINKEDIT` segment size that the larger signature grew.\n\n' "$OSTT_VERSION" "$TARGET"
  printf -- '- Licence: `%s`\n- Repository: <%s>\n- Release: <%s/releases/tag/v%s> (commit `%s`)\n' \
    "$OSTT_LICENCE" "$OSTT_REPO" "$OSTT_REPO" "$OSTT_VERSION" "$OSTT_COMMIT"
  copyright_bullets "Kristofer Lund" "$SRC/LICENSE"
  echo
  text_block LICENSE "$SRC/LICENSE"
} >"$TMP/ostt.md"

# --- Rust crates -----------------------------------------------------------------------------
crate_count=0
: >"$TMP/crates.md"
: >"$TMP/texts.md"
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
    else
      printf -- '- Copyright (c) %s\n' "${authors:-The $name developers}"
    fi
  } >>"$TMP/crates.md"
  refs=()
  for f in "${files[@]+"${files[@]}"}"; do
    if register_text "${f##*/}" "$f" "$name $version"; then refs+=("$REF"); fi
  done
  # No licence text in the crate: reference the standard SPDX texts.
  if ((${#refs[@]} == 0)); then
    while IFS= read -r id; do
      register_text "$id (SPDX standard text)" "$(spdx_text "$id")" "$name $version" \
        || die "SPDX text for $id is empty"
      refs+=("$REF")
    done < <(licence_ids "$licence" | awk '!seen[$0]++')
  fi
  ref_list="$(printf '%s, ' "${refs[@]}")"
  printf -- '- Licence texts: %s\n\n' "${ref_list%, }" >>"$TMP/crates.md"
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

# ggml files compiled into ostt that carry their own MIT notices, which ggml/LICENSE omits:
# llamafile's sgemm (GGML_LLAMAFILE is forced on) and the YaRN RoPE code (CPU and Metal).
ggml_embedded_notices() {
  local sgemm="ggml/src/ggml-cpu/llamafile/sgemm.cpp" ops="ggml/src/ggml-cpu/ops.cpp"
  local rope="ggml/src/ggml-metal/kernels/rope.metal" sgemm_line yarn_line
  sgemm_line="$(sed -nE 's#^// (Copyright .*)$#\1#p' "$TCS_DIR/$sgemm" | head -n 1)"
  [[ "$sgemm_line" == *"Mozilla Foundation"* ]] || die "$sgemm no longer carries the Mozilla Foundation copyright"
  yarn_line="$(sed -nE 's|^// MIT licensed\. (Copyright .*Quesnelle.*)\.$|\1|p' "$TCS_DIR/$ops" | head -n 1)"
  if [[ -z "$yarn_line" ]] || ! grep -qF "$yarn_line" "$TCS_DIR/$rope"; then
    die "no YaRN copyright line in $ops and $rope"
  fi
  printf -- '- %s (llamafile sgemm, `%s`, MIT)\n' "$sgemm_line" "$sgemm"
  printf -- '- %s (YaRN RoPE, `%s` and `%s`, MIT)\n' "$yarn_line" "$ops" "$rope"
  printf '\nThe sgemm and YaRN RoPE files are MIT-licensed under the same terms as the text below.\n'
}

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
    [[ "$comp" != ggml ]] || ggml_embedded_notices
    echo
    text_block "$path" "$TCS_DIR/$path"
  } >>"$TMP/vendored.md"
  vendored=$((vendored + 1))
done < <(grep -E '^\| *[^ |-][^|]*\|[^|]*\| *\[`' "$TCS_DIR/THIRD-PARTY-LICENSES.md")
((vendored)) || die "no components parsed from transcribe-cpp-sys THIRD-PARTY-LICENSES.md"

# libsqlite3-sys compiles its SQLite amalgamation into ostt only with the bundled feature.
SQLITE_SYS="$(jq -r '. as $m | .resolve.nodes[] | select(.features | index("bundled"))
  | .id as $id | $m.packages[] | select(.id == $id and .name == "libsqlite3-sys")
  | [.version, (.manifest_path | sub("/Cargo.toml$"; ""))] | @tsv' "$TMP/meta.json")"
if [[ -n "$SQLITE_SYS" ]] && grep -qxF "libsqlite3-sys v${SQLITE_SYS%%$'\t'*}" "$TMP/tree.txt"; then
  sys_version="${SQLITE_SYS%%$'\t'*}"
  header="${SQLITE_SYS#*$'\t'}/sqlite3/sqlite3.h"
  sqlite_version="$(sed -nE 's/^#define SQLITE_VERSION +"([^"]+)".*/\1/p' "$header")"
  [[ -n "$sqlite_version" ]] || die "no SQLITE_VERSION in $header"
  # The blessing that stands in for a licence, from the header's first comment.
  sed -n '/The author disclaims copyright/,/never taking more than you give/{p;/never taking/q;}' "$header" \
    | sed -E 's/^\*\* ?//; s/^ +//' >"$TMP/sqlite-blessing.txt"
  [[ -s "$TMP/sqlite-blessing.txt" ]] || die "no SQLite blessing in $header"
  summary SQLite vendored-sqlite "$sqlite_version (in libsqlite3-sys $sys_version)" blessing
  note_expr blessing
  {
    printf '<a id="vendored-sqlite"></a>\n### SQLite %s (bundled in libsqlite3-sys %s)\n\n' "$sqlite_version" "$sys_version"
    printf -- '- Licence: public domain (SPDX `blessing`)\n- Website: <https://sqlite.org/copyright.html>\n\n'
    text_block "sqlite3.h" "$TMP/sqlite-blessing.txt"
  } >>"$TMP/vendored.md"
  vendored=$((vendored + 1))
fi

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
2. [Rust crates](#rust-crates): $crate_count packages from ostt's \`Cargo.lock\` that its $TARGET build compiles.
3. [Licence texts](#licence-texts): the $text_count distinct licence texts the crates reference.
4. [Vendored C/C++ components](#vendored): transcribe.cpp and the components it vendors, built into ostt by transcribe-cpp-sys, and SQLite, built in by libsqlite3-sys.
5. [Swift packages](#swift-packages): $swift_count packages built into the app.
6. [Speech models](#speech-models): credits for the optional offline models.

## Summary

| Package | Version | Licence |
|---|---|---|
EOF
  cat "$TMP/summary.md"
  echo
  cat "$TMP/ostt.md"
  printf '<a id="rust-crates"></a>\n## Rust crates\n\nEvery package in ostt %s'"'"'s `Cargo.lock` that its %s build compiles through normal or build dependencies. Each crate lists its copyright lines and links every licence text it ships; for dual- or multi-licensed crates, all of them.\n\n' "$OSTT_VERSION" "$TARGET"
  cat "$TMP/crates.md"
  printf '<a id="licence-texts"></a>\n## Licence texts\n\nEach distinct licence text appears once, without its copyright lines; texts that differ only in copyright lines or whitespace count as one.\n\n'
  cat "$TMP/texts.md"
  printf '<a id="vendored"></a>\n## Vendored C/C++ components\n\nThe transcribe-cpp-sys crate compiles transcribe.cpp and the components listed in its `THIRD-PARTY-LICENSES.md` into ostt; libsqlite3-sys compiles its bundled SQLite.\n\n'
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
echo "Wrote $OUT: ostt, $crate_count crates, $text_count licence texts, $((vendored + 1)) vendored components, $swift_count Swift packages"
