#!/usr/bin/env bash
set -Eeuo pipefail

show_help() {
  cat <<'EOF'
Usage:
  ./ytdown.sh -audio      links.txt [output_dir] [prefix] [parallel]
  ./ytdown.sh -video      links.txt [output_dir] [prefix] [parallel]
  ./ytdown.sh -audiovideo links.txt [output_dir] [prefix] [parallel]

Examples:
  ./ytdown.sh -audio ytlinks.txt
  ./ytdown.sh -video ytlinks.txt "$HOME/Movies/KKS" "KKS" 3
  ./ytdown.sh -audiovideo ytlinks.txt "$HOME/Media/KKS" "KKS" 4
EOF
}

MODE="${1:-}"
INPUT_FILE="${2:-}"
OUTPUT_DIR="${3:-$HOME/Downloads/YT_Media}"
PREFIX="${4:-KKS}"
PARALLEL="${5:-3}"

case "$MODE" in
  -audio|-video|-audiovideo) ;;
  -h|--help|"")
    show_help
    exit 0
    ;;
  *)
    echo "Unknown mode: $MODE"
    show_help
    exit 1
    ;;
esac

if [[ -z "$INPUT_FILE" ]]; then
  show_help
  exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "Input file not found: $INPUT_FILE"
  exit 1
fi

for cmd in yt-dlp ffmpeg ffprobe python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd"
    exit 1
  fi
done

if ! [[ "$PARALLEL" =~ ^[0-9]+$ ]] || [[ "$PARALLEL" -lt 1 ]]; then
  echo "Parallel must be a positive number"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/audio"
mkdir -p "$OUTPUT_DIR/video"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

URLS_FILE="$TMP_DIR/urls.txt"
COUNTER_FILE="$TMP_DIR/counter.txt"
LOCK_DIR="$TMP_DIR/lockdir"

AUDIO_ARCHIVE="$OUTPUT_DIR/.downloaded_audio.txt"
VIDEO_ARCHIVE="$OUTPUT_DIR/.downloaded_video.txt"

grep -E 'https?://' "$INPUT_FILE" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | awk 'NF' > "$URLS_FILE"

TOTAL="$(wc -l < "$URLS_FILE" | tr -d ' ')"
if [[ "$TOTAL" -eq 0 ]]; then
  echo "No valid URLs found in $INPUT_FILE"
  exit 1
fi

echo 0 > "$COUNTER_FILE"
touch "$AUDIO_ARCHIVE" "$VIDEO_ARCHIVE"

build_filename() {
  python3 - "$1" "$2" <<'PY'
import json, sys, re, unicodedata
from datetime import datetime

raw = sys.argv[1]
prefix = sys.argv[2].strip()
data = json.loads(raw)

def slugify(s):
    s = (s or "").strip()
    s = unicodedata.normalize("NFKD", s)
    s = s.encode("ascii", "ignore").decode("ascii")
    s = s.replace("&", " and ")
    s = re.sub(r"['’`]", "", s)
    s = re.sub(r"[^A-Za-z0-9]+", "-", s)
    s = re.sub(r"-{2,}", "-", s).strip("-")
    return s or "untitled"

title_raw = data.get("title") or ""
title = slugify(title_raw)
location = slugify(data.get("location") or "")

# --- DATE EXTRACTION (STRICT) ---

months = {
    "jan":1,"january":1,
    "feb":2,"february":2,
    "mar":3,"march":3,
    "apr":4,"april":4,
    "may":5,
    "jun":6,"june":6,
    "jul":7,"july":7,
    "aug":8,"august":8,
    "sep":9,"sept":9,"september":9,
    "oct":10,"october":10,
    "nov":11,"november":11,
    "dec":12,"december":12,
}

def extract_date(text):
    text = text.lower()

    # 1. ISO format YYYY-MM-DD
    m = re.search(r'\b(20\d{2})-(\d{2})-(\d{2})\b', text)
    if m:
        return f"{m.group(1)}-{m.group(2)}-{m.group(3)}"

    # 2. Formats like "10th Dec 2016" or "10 Dec 2016" or "23 November 2019"
    m = re.search(r'\b(\d{1,2})(st|nd|rd|th)?\s+([a-zA-Z]+)\s+(20\d{2})\b', text)
    if m:
        day = int(m.group(1))
        month_str = m.group(3).lower()
        year = int(m.group(4))

        month = months.get(month_str[:3]) or months.get(month_str)
        if month:
            try:
                dt = datetime(year, month, day)
                return dt.strftime("%Y-%m-%d")
            except:
                pass

    return None

date_part = extract_date(title_raw)

# --- BUILD FILENAME ---

parts = []

if date_part:
    parts.append(date_part)

if prefix:
    parts.append(slugify(prefix))

parts.append(title)

if location:
    parts.append(location)

print("_".join([p for p in parts if p]))
PY
}

reserve_index() {
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    sleep 0.05
  done

  local n
  n="$(cat "$COUNTER_FILE")"
  n=$((n + 1))
  echo "$n" > "$COUNTER_FILE"

  rmdir "$LOCK_DIR"
  echo "$n"
}

download_audio() {
  local url="$1"
  local base="$2"
  local target="$OUTPUT_DIR/audio/$base.mp3"

  if [[ -f "$target" ]]; then
    echo "  SKIP audio: already exists"
    return 0
  fi

  if ! yt-dlp \
      --extract-audio \
      --audio-format mp3 \
      --audio-quality 0 \
      --embed-metadata \
      --embed-thumbnail \
      --convert-thumbnails jpg \
      --continue \
      --no-overwrites \
      --download-archive "$AUDIO_ARCHIVE" \
      --output "$OUTPUT_DIR/audio/$base.%(ext)s" \
      "$url"; then
    echo "  ERROR audio: download failed"
    echo "  LINK: $url"
    return 1
  fi

  echo "  DONE audio: $target"
  return 0
}

download_video() {
  local url="$1"
  local base="$2"

  # Download best video+audio, merge if needed, prefer mp4 output
  if ! yt-dlp \
      -f "bv*+ba/b" \
      --merge-output-format mp4 \
      --embed-metadata \
      --write-thumbnail \
      --convert-thumbnails jpg \
      --continue \
      --no-overwrites \
      --download-archive "$VIDEO_ARCHIVE" \
      --output "$OUTPUT_DIR/video/$base.%(ext)s" \
      "$url"; then
    echo "  ERROR video: download failed"
    echo "  LINK: $url"
    return 1
  fi

  echo "  DONE video: $OUTPUT_DIR/video/$base.mp4 (or source extension if merge not needed)"
  return 0
}

process_url() {
  local url="$1"
  local index
  index="$(reserve_index)"

  echo "[$index/$TOTAL] $url"

  local meta_json
  if ! meta_json="$(yt-dlp --dump-single-json --skip-download --no-warnings "$url" 2>/dev/null)"; then
    echo "  ERROR: metadata failed"
    echo "  LINK: $url"
    return 0
  fi

  local base
  base="$(build_filename "$meta_json" "$PREFIX")"

  case "$MODE" in
    -audio)
      download_audio "$url" "$base" || true
      ;;
    -video)
      download_video "$url" "$base" || true
      ;;
    -audiovideo)
      download_audio "$url" "$base" || true
      download_video "$url" "$base" || true
      ;;
  esac

  echo
}

export MODE INPUT_FILE OUTPUT_DIR PREFIX PARALLEL TOTAL
export AUDIO_ARCHIVE VIDEO_ARCHIVE TMP_DIR COUNTER_FILE LOCK_DIR
export -f build_filename reserve_index download_audio download_video process_url

echo "Mode       : $MODE"
echo "Input file : $INPUT_FILE"
echo "Output dir : $OUTPUT_DIR"
echo "Prefix     : $PREFIX"
echo "Parallel   : $PARALLEL"
echo "Total URLs : $TOTAL"
echo

xargs -P "$PARALLEL" -I {} bash -c 'process_url "$@"' _ {} < "$URLS_FILE"

echo "Finished."
