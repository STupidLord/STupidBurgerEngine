#!/usr/bin/env bash
# Losslessly recompress UI background PNGs. No resizing, palette reduction,
# lossy conversion, or filename changes. Dry-run by default.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INPUT_DIR="$ROOT/assets/ui/bg"
DRY_RUN=1
JOBS=1

usage() {
  cat <<'USAGE'
Usage: tools/compress-ui-bg.sh [options]

  --apply           Replace source PNGs when the result is smaller.
  --dir DIRECTORY   Use another directory instead of assets/ui/bg.
  --jobs N          Process up to N files concurrently (default: 1).
  -h, --help        Show this help.

Examples:
  tools/compress-ui-bg.sh
  tools/compress-ui-bg.sh --apply --jobs 4

Optimizer order: oxipng, zopflipng, then Pillow. All are lossless.
USAGE
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

while (($#)); do
  case "$1" in
    --apply) DRY_RUN=0 ;;
    --dir) (($# >= 2)) || die '--dir requires a directory'; INPUT_DIR=$2; shift ;;
    --jobs) (($# >= 2)) || die '--jobs requires a positive integer'; JOBS=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
[[ -d "$INPUT_DIR" ]] || die "directory does not exist: $INPUT_DIR"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die '--jobs must be a positive integer'

if command -v oxipng >/dev/null 2>&1; then
  OPTIMIZER=oxipng
elif command -v zopflipng >/dev/null 2>&1; then
  OPTIMIZER=zopflipng
elif command -v python3 >/dev/null 2>&1 && python3 -c 'from PIL import Image' >/dev/null 2>&1; then
  OPTIMIZER=pillow
else
  die 'install oxipng, zopflipng, or python3 with Pillow'
fi

format_bytes() {
  awk -v n="$1" 'BEGIN { split("B KiB MiB GiB", u); i=1; while (n >= 1024 && i < 4) { n/=1024; i++ } printf "%.1f %s", n, u[i] }'
}

optimize_one() {
  local source=$1 tmp before after delta
  tmp=$(mktemp --tmpdir="${TMPDIR:-/tmp}" 'ui-bg.XXXXXX.png')
  trap 'rm -f "$tmp"' RETURN
  before=$(stat -c '%s' "$source")
  case "$OPTIMIZER" in
    oxipng) oxipng -o 6 --strip safe --out "$tmp" "$source" >/dev/null ;;
    zopflipng) zopflipng -y --iterations=15 "$source" "$tmp" >/dev/null ;;
    pillow) python3 - "$source" "$tmp" <<'PY'
from pathlib import Path
import sys
from PIL import Image
source, target = map(Path, sys.argv[1:])
with Image.open(source) as image:
    image.save(target, format="PNG", optimize=True, compress_level=9)
PY
      ;;
  esac

  # Verify decoded pixels, dimensions, and mode before considering replacement.
  python3 - "$source" "$tmp" <<'PY'
from pathlib import Path
import hashlib
import sys
from PIL import Image
def digest(path: Path) -> tuple:
    with Image.open(path) as image:
        return image.size, image.mode, hashlib.sha256(image.tobytes()).digest()
if digest(Path(sys.argv[1])) != digest(Path(sys.argv[2])):
    raise SystemExit("decoded pixels, dimensions, or mode changed")
PY

  after=$(stat -c '%s' "$tmp")
  delta=$((before - after))
  if (( delta > 0 )); then
    printf '%s: %s -> %s (saved %s)\n' "${source#"$ROOT/"}" "$(format_bytes "$before")" "$(format_bytes "$after")" "$(format_bytes "$delta")"
    if (( ! DRY_RUN )); then
      chmod --reference="$source" "$tmp"
      mv -f -- "$tmp" "$source"
    fi
  else
    printf '%s: unchanged (%s)\n' "${source#"$ROOT/"}" "$(format_bytes "$before")"
  fi
  rm -f "$tmp"
  trap - RETURN
}

export ROOT DRY_RUN OPTIMIZER
export -f format_bytes optimize_one
mapfile -d '' FILES < <(find "$INPUT_DIR" -type f -iname '*.png' -print0 | sort -z)
(( ${#FILES[@]} )) || { printf 'No PNG files found in %s\n' "$INPUT_DIR"; exit 0; }
MODE=apply; (( DRY_RUN )) && MODE=dry-run
printf 'Optimizer: %s | mode: %s | files: %d\n' "$OPTIMIZER" "$MODE" "${#FILES[@]}"
if (( JOBS > 1 )); then
  printf '%s\0' "${FILES[@]}" | xargs -0 -r -n 1 -P "$JOBS" bash -c 'optimize_one "$1"' _
else
  for file in "${FILES[@]}"; do optimize_one "$file"; done
fi
