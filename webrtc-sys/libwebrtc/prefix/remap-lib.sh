#!/bin/bash
# Prefix libwebrtc's bundled ffmpeg + BoringSSL symbol families with `webrtc_` so they cannot
# shadow the copies an application links itself. Mach-O and ELF archives go through
# llvm-objcopy whole. COFF archives are processed member by member: llvm-objcopy 21 writes
# NASM-built COFF objects back with an empty symbol table, so each member's globals are
# checked against the expected set and the members objcopy breaks are patched through
# their string table instead (coff_rename.py).
# usage: remap-lib.sh <in-lib> <out-lib> <workdir>
# LLVM_BIN: directory holding llvm-nm, llvm-objcopy, llvm-ar and llvm-lib.
set -euo pipefail
B=${LLVM_BIN:-/opt/homebrew/opt/llvm/bin}
in=$1; out=$2; work=$3; here=$(cd "$(dirname "$0")" && pwd)
PATTERN="(_)?(av|sws|swr|avio|avcodec|avformat|avfilter|avutil|avdevice|SSL|ssl|CRYPTO|crypto|BIO|bio|EVP|evp|RSA|rsa|X509|x509|PEM|pem|ERR|err|BN|bn|EC|ec|PKCS|pkcs)_"
rm -rf "$work"; mkdir -p "$work/orig" "$work/out"
map="$work/symbols.map"

defined() { $B/llvm-nm --defined-only -g "$1" 2>/dev/null | awk '$NF !~ /:$/ {print $NF}'; }
globals() { $B/llvm-nm -g "$1" 2>/dev/null | awk 'NF >= 2 {print $(NF-1), $NF}' | sort; }
expected() { awk -v mapfile="$map" 'BEGIN { while ((getline l < mapfile) > 0) { split(l, a, " "); m[a[1]] = a[2] } } { if ($2 in m) $2 = m[$2]; print }' | sort; }

defined "$in" | grep -E "^$PATTERN" | sort -u | awk '{print $1, "webrtc_" $1}' > "$map"
echo "renaming $(wc -l < "$map" | tr -d ' ') symbols"

patched=0
case $out in
  *.lib)
    $B/llvm-ar t "$in" > "$work/members.txt"
    while read -r m; do
      mkdir -p "$work/orig/$(dirname "$m")" "$work/out/$(dirname "$m")"
      $B/llvm-ar pP "$in" "$m" > "$work/orig/$m"
      globals "$work/orig/$m" | expected > "$work/want.txt"
      $B/llvm-objcopy --redefine-syms="$map" "$work/orig/$m" "$work/out/$m"
      if ! globals "$work/out/$m" | cmp -s - "$work/want.txt"; then
        python3 -I "$here/coff_rename.py" "$map" "$work/orig/$m" "$work/out/$m" > /dev/null
        globals "$work/out/$m" | cmp -s - "$work/want.txt" || { echo "FAILED: member $m"; exit 1; }
        patched=$((patched + 1))
      fi
    done < "$work/members.txt"
    (cd "$work/out" && $B/llvm-lib "/out:$out" @"$work/members.txt")
    members=$(wc -l < "$work/members.txt" | tr -d ' ')
    [ "$($B/llvm-ar t "$out" | wc -l | tr -d ' ')" = "$members" ] || { echo "FAILED: member count"; exit 1; }
    echo "members: $members, patched via string table: $patched"
    ;;
  *)
    $B/llvm-objcopy --redefine-syms="$map" "$in" "$out"
    ;;
esac

in_count=$(defined "$in" | wc -l | tr -d ' '); out_count=$(defined "$out" | wc -l | tr -d ' ')
left=$(defined "$out" | grep -cE "^$PATTERN" || true)
defined "$out" | sort -u > "$work/defined.txt"
$B/llvm-nm --undefined-only "$out" 2>/dev/null | awk '$NF !~ /:$/ {print $NF}' | sort -u > "$work/undefined.txt"
dangling=$(comm -23 "$work/undefined.txt" "$work/defined.txt" | grep -cE "^(webrtc_|$PATTERN)" || true)
echo "defined globals: in=$in_count out=$out_count, left unrenamed: $left, dangling refs: $dangling"
[ "$in_count" = "$out_count" ] && [ "$left" = 0 ] && [ "$dangling" = 0 ] || { echo "FAILED: checks"; exit 1; }
rm -rf "$work/orig" "$work/out"
