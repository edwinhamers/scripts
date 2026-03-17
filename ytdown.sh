#!/opt/homebrew/bin/bash
set -Eeuo pipefail

show_help() {
  cat <<'EOF'
Usage:
  ./ytaudio.sh -audio      links.txt [output_dir] [prefix] [parallel]
  ./ytaudio.sh -video      links.txt [output_dir] [prefix] [parallel]
  ./ytaudio.sh -audiovideo links.txt [output_dir] [prefix] [parallel]

Examples:
  ./ytaudio.sh -audio ytlinks.txt
  ./ytaudio.sh -video ytlinks.txt "$HOME/Movies/KKS" "KKS" 3
  ./ytaudio.sh -audiovideo ytlinks.txt "$HOME/Media/KKS" "KKS" 4
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
  echo "Parallel must be a positive integer"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/audio"
mkdir -p "$OUTPUT_DIR/video"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

URLS_FILE="$TMP_DIR/urls.txt"
COUNTER_FILE="$TMP_DIR/counter.txt"
LOCK_DIR="$TMP_DIR/counter.lock"
RUNNER_FILE="$TMP_DIR/runner.sh"

AUDIO_ARCHIVE="$OUTPUT_DIR/.downloaded_audio.txt"
VIDEO_ARCHIVE="$OUTPUT_DIR/.downloaded_video.txt"
CSV_FILE="$OUTPUT_DIR/download_report.csv"

grep -E 'https?://' "$INPUT_FILE" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | awk 'NF' > "$URLS_FILE"

TOTAL="$(wc -l < "$URLS_FILE" | tr -d ' ')"
if [[ "$TOTAL" -eq 0 ]]; then
  echo "No valid URLs found in $INPUT_FILE"
  exit 1
fi

echo 0 > "$COUNTER_FILE"
touch "$AUDIO_ARCHIVE" "$VIDEO_ARCHIVE"

if [[ ! -f "$CSV_FILE" ]]; then
  printf 'recording_date,title,location,channel_name,original_link,status\n' > "$CSV_FILE"
fi

build_metadata() {
  python3 - "$1" "$2" <<'PY'
import json, sys, re, unicodedata
from datetime import datetime

raw = sys.argv[1]
prefix = sys.argv[2].strip()
data = json.loads(raw)

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

def slugify(s):
    s = (s or "").strip()
    s = unicodedata.normalize("NFKD", s)
    s = s.encode("ascii", "ignore").decode("ascii")
    s = re.sub(r"[\[\]\(\)\|]", "-", s)
    s = re.sub(r"[.,:;]", "-", s)
    s = re.sub(r"['’`]", "", s)
    s = re.sub(r"[^A-Za-z0-9]+", "-", s)
    s = re.sub(r"-{2,}", "-", s)
    s = s.strip("-")
    return s or "untitled"

def extract_date(text):
    text = (text or "").lower()

    m = re.search(r'\b(20\d{2})-(\d{2})-(\d{2})\b', text)
    if m:
        return f"{m.group(1)}-{m.group(2)}-{m.group(3)}"

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
            except Exception:
                pass

    return ""

title_raw = (data.get("title") or "").strip()
location_raw = (data.get("location") or "").strip()
channel_raw = (data.get("channel") or data.get("uploader") or "").strip()
recording_date = extract_date(title_raw)

parts = []
if recording_date:
    parts.append(recording_date)
if prefix:
    parts.append(slugify(prefix))
parts.append(slugify(title_raw))
if location_raw:
    parts.append(slugify(location_raw))

basename = "_".join([p for p in parts if p])

print("\t".join([
    basename,
    recording_date,
    title_raw.replace("\t", " ").replace("\n", " "),
    location_raw.replace("\t", " ").replace("\n", " "),
    channel_raw.replace("\t", " ").replace("\n", " "),
]))
PY
}

append_csv_row() {
  local recording_date="$1"
  local title="$2"
  local location="$3"
  local channel_name="$4"
  local original_link="$5"
  local status="$6"

  python3 - "$CSV_FILE" "$recording_date" "$title" "$location" "$channel_name" "$original_link" "$status" <<'PY'
import csv, sys, os, time

csv_file, recording_date, title, location, channel_name, original_link, status = sys.argv[1:]
lock_dir = csv_file + ".lock"

while True:
    try:
        os.mkdir(lock_dir)
        break
    except FileExistsError:
        time.sleep(0.05)

try:
    with open(csv_file, "a", newline="", encoding="utf-8") as f:
        csv.writer(f).writerow([recording_date, title, location, channel_name, original_link, status])
finally:
    os.rmdir(lock_dir)
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
      --write-thumbnail \
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

  if compgen -G "$OUTPUT_DIR/video/$base.*" > /dev/null; then
    echo "  SKIP video: already exists"
    return 0
  fi

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

  echo "  DONE video: $OUTPUT_DIR/video/$base.mp4"
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
    append_csv_row "" "" "" "" "$url" "failed"
    echo
    return 0
  fi

  local meta_line
  meta_line="$(build_metadata "$meta_json" "$PREFIX")"

  local base recording_date raw_title raw_location raw_channel
  IFS=$'\t' read -r base recording_date raw_title raw_location raw_channel <<< "$meta_line"

  case "$MODE" in
    -audio)
      if download_audio "$url" "$base"; then
        append_csv_row "$recording_date" "$raw_title" "$raw_location" "$raw_channel" "$url" "completed"
      else
        append_csv_row "$recording_date" "$raw_title" "$raw_location" "$raw_channel" "$url" "failed"
      fi
      ;;
    -video)
      if download_video "$url" "$base"; then
        append_csv_row "$recording_date" "$raw_title" "$raw_location" "$raw_channel" "$url" "completed"
      else
        append_csv_row "$recording_date" "$raw_title" "$raw_location" "$raw_channel" "$url" "failed"
      fi
      ;;
    -audiovideo)
      local ok_audio=1
      local ok_video=1

      download_audio "$url" "$base" || ok_audio=0
      download_video "$url" "$base" || ok_video=0

      if [[ "$ok_audio" -eq 1 && "$ok_video" -eq 1 ]]; then
        append_csv_row "$recording_date" "$raw_title" "$raw_location" "$raw_channel" "$url" "completed"
      else
        append_csv_row "$recording_date" "$raw_title" "$raw_location" "$raw_channel" "$url" "failed"
      fi
      ;;
  esac

  echo
}

export MODE OUTPUT_DIR PREFIX TOTAL
export AUDIO_ARCHIVE VIDEO_ARCHIVE CSV_FILE COUNTER_FILE LOCK_DIR
export -f build_metadata append_csv_row reserve_index download_audio download_video process_url

cat > "$RUNNER_FILE" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
process_url "$1"
EOF
chmod +x "$RUNNER_FILE"

echo "Mode       : $MODE"
echo "Input file : $INPUT_FILE"
echo "Output dir : $OUTPUT_DIR"
echo "Prefix     : $PREFIX"
echo "Parallel   : $PARALLEL"
echo "Total URLs : $TOTAL"
echo "CSV file   : $CSV_FILE"
echo

xargs -P "$PARALLEL" -I {} "$BASH" "$RUNNER_FILE" "{}" < "$URLS_FILE"

echo
echo "Finished."
echo "CSV report: $CSV_FILE"
maced@Uddhavas-MacBook-Pro youtube %
