#!/bin/bash
# Turn an upstream livekit/rust-sdks libwebrtc release into the prefixed desktop archives
# webrtc-sys-build downloads from this fork (see remap-lib.sh).
# usage: make-prefixed-prebuilts.sh <upstream-tag> <workdir>
# Archives already present in <workdir>/upstream/ are used instead of downloaded.
# Outputs: <workdir>/release/webrtc-<target>-release.zip and <workdir>/summary.md
set -euo pipefail
tag=$1; work=$2; here=$(cd "$(dirname "$0")" && pwd)
targets=${TARGETS:-"linux-x64 linux-arm64 mac-x64 mac-arm64 win-x64 win-arm64"}
mkdir -p "$work/upstream" "$work/stage" "$work/release"
{ echo "| target | result |"; echo "| --- | --- |"; } > "$work/summary.md"
for t in $targets; do
  zip="webrtc-$t-release.zip"
  if [ ! -f "$work/upstream/$zip" ]; then
    curl -fsSL --retry 3 -o "$work/upstream/$zip" \
      "https://github.com/livekit/rust-sdks/releases/download/$tag/$zip"
  fi
  rm -rf "$work/stage/$t"; mkdir -p "$work/stage/$t"
  unzip -qo "$work/upstream/$zip" -d "$work/stage/$t"
  dir="$work/stage/$t/$t-release"
  [ -d "$dir/lib" ] || { echo "$zip: no $t-release/lib in the archive"; exit 1; }
  case $t in
    win-*) lib="$dir/lib/webrtc.lib" ;;
    *) lib="$dir/lib/libwebrtc.a" ;;
  esac
  echo "== $t"
  mv "$lib" "$lib.orig"
  "$here/remap-lib.sh" "$lib.orig" "$lib" "$work/remap-$t" | tee "$work/remap-$t.log"
  rm -f "$lib.orig" "$work/release/$zip"
  (cd "$work/stage/$t" && zip -qr "$work/release/$zip" "$t-release")
  rm -rf "$work/stage/$t"
  echo "| $t | $(tr '\n' ';' < "$work/remap-$t.log" | sed 's/;$//; s/;/; /g') |" >> "$work/summary.md"
done
cat "$work/summary.md"
