#!/usr/bin/env bash
set -euo pipefail

# Compare two local trees:
A="/var/www/cloudmigration.blog"         # FTP copy
B="/var/www/cloudmigration.blog.ssh"     # SSH copy (may contain public_html/)

# If SSH tree contains public_html/, compare that folder instead
if [[ -d "${B}/public_html" ]]; then
  B="${B}/public_html"
fi

TOPN=50
TMP="${TMPDIR:-/tmp}/cmp_$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

A_LIST="$TMP/a.list"     # path|size (sorted, unique by path)
B_LIST="$TMP/b.list"
A_PATHS="$TMP/a.paths"   # path only (sorted unique)
B_PATHS="$TMP/b.paths"
JOIN_AB="$TMP/join_ab"   # joined by path
ONLY_A="$TMP/only_a"
ONLY_B="$TMP/only_b"
DIFF_SIZE="$TMP/diff_size"

# Build manifest (relative path + size), sort & dedupe by path
build_manifest () {
  local root="$1" out="$2"
  if [[ ! -d "$root" ]]; then
    echo "[ERR] Missing directory: $root" >&2
    exit 2
  fi
  # %P = path relative to root, %s = size in bytes
  LC_ALL=C find "$root" -type f -printf '%P|%s\n' \
    | LC_ALL=C sort -t'|' -k1,1 -u > "$out"
}

build_manifest "$A" "$A_LIST"
build_manifest "$B" "$B_LIST"

# Extract just paths, ensure sorted unique for comm
LC_ALL=C cut -d'|' -f1 "$A_LIST" | LC_ALL=C sort -u > "$A_PATHS"
LC_ALL=C cut -d'|' -f1 "$B_LIST" | LC_ALL=C sort -u > "$B_PATHS"

# Totals
read -r A_FILES A_BYTES < <(awk -F'|' '{c++; s+=$2} END{print c+0, s+0}' "$A_LIST")
read -r B_FILES B_BYTES < <(awk -F'|' '{c++; s+=$2} END{print c+0, s+0}' "$B_LIST")

# Only in A / Only in B (inputs must be sorted)
LC_ALL=C comm -23 "$A_PATHS" "$B_PATHS" > "$ONLY_A"
LC_ALL=C comm -13 "$A_PATHS" "$B_PATHS" > "$ONLY_B"

# Same path, different size (join needs both sorted by key)
LC_ALL=C join -t'|' -j 1 "$A_LIST" "$B_LIST" > "$JOIN_AB" || true
awk -F'|' '$2 != $3 {print $1 "|" $2 "|" $3}' "$JOIN_AB" > "$DIFF_SIZE" || true

# Report
echo "=== Compare Trees ==="
echo "A (FTP): $A"
echo "B (SSH): $B"
echo
printf "A files: %'d\tA bytes: %'d\n" "$A_FILES" "$A_BYTES"
printf "B files: %'d\tB bytes: %'d\n" "$B_FILES" "$B_BYTES"
echo

A_MINUS_B=$(wc -l < "$ONLY_A")
B_MINUS_A=$(wc -l < "$ONLY_B")
SZ_MISM=$(wc -l < "$DIFF_SIZE")

echo "Only in A       : $A_MINUS_B"
echo "Only in B       : $B_MINUS_A"
echo "Size mismatches : $SZ_MISM"
echo

show_head () {
  local title="$1" file="$2" mode="$3"
  local n
  n=$(wc -l < "$file")
  [[ "$n" -gt 0 ]] || return 0
  echo "--- $title (showing up to $TOPN of $n) ---"
  if [[ "$mode" == "paths" ]]; then
    head -n "$TOPN" "$file"
  else
    head -n "$TOPN" "$file" | awk -F'|' '{printf "%s  (A:%s  B:%s)\n",$1,$2,$3}'
  fi
  echo
}

show_head "Files only in A (FTP)" "$ONLY_A" paths
show_head "Files only in B (SSH)" "$ONLY_B" paths
show_head "Same path, different size" "$DIFF_SIZE" sizes

# Exit 0 if fully identical by counts/bytes and no diffs; else 1
if [[ "$A_FILES" -eq "$B_FILES" && "$A_BYTES" -eq "$B_BYTES" && "$A_MINUS_B" -eq 0 && "$B_MINUS_A" -eq 0 && "$SZ_MISM" -eq 0 ]]; then
  echo "✅ Trees match (counts, bytes, and per-path sizes)"
  exit 0
else
  echo "⚠ Differences detected (see above)."
  exit 1
fi
