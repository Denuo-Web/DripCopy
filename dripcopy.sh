#!/usr/bin/env bash
# DripCopy — Gentle Optical Media Copier for Underpowered USB Hosts
# Version: 0.1.0
#
# License: MIT
# Copyright (c) 2025
# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal in
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
# of the Software, and to permit persons to do so, subject to the following
# conditions:
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -u

# ---- Configuration ----
DEVICE="${DEVICE:-/dev/sr1}"
SRC_ROOT="${SRC_ROOT:-/media/}"
# Adjust these for your disc's top-level directories
FOLDERS=("Folder_1" "Folder_2")
DEST="${DEST:-$HOME/cd_copy}"

RATE="${RATE:-150k}"            # pv rate limit (e.g., 150k, 120k, 100k)
SLEEP_BETWEEN="${SLEEP_BETWEEN:-1}"   # seconds between files
RETRIES="${RETRIES:-3}"         # per-file retries
RETRY_SLEEP="${RETRY_SLEEP:-3}" # seconds between retries
READAHEAD_KB="${READAHEAD_KB:-0}"     # 0 disables kernel readahead on /dev/srX

# ---- Preconditions ----
if ! command -v pv >/dev/null 2>&1; then
  echo "ERROR: pv is required. Install with: sudo apt-get install -y pv" >&2
  exit 1
fi

mkdir -p "$DEST"
# Make destination writable by invoking user (best-effort)
sudo chown -R "$(id -un)":"$(id -gn)" "$DEST" 2>/dev/null || true
chmod -R u+rwX "$DEST" 2>/dev/null || true

# Reduce bursty reads (best-effort)
devbase="$(basename "$DEVICE")"
if [ -e "/sys/block/$devbase/queue/read_ahead_kb" ]; then
  echo "$READAHEAD_KB" | sudo tee "/sys/block/$devbase/queue/read_ahead_kb" >/dev/null 2>&1 || true
fi
sudo blockdev --setra 0 "$DEVICE" >/dev/null 2>&1 || true

# Try to use an existing mount if SRC_ROOT isn't mounted
if ! mountpoint -q "$SRC_ROOT"; then
  alt_mp="$(awk -v dev="$DEVICE" '$1==dev{print $2}' /proc/mounts | head -n1)"
  if [ -n "${alt_mp:-}" ] && mountpoint -q "$alt_mp"; then
    echo "NOTE: using existing mountpoint: $alt_mp"
    SRC_ROOT="$alt_mp"
  else
    echo "ERROR: $DEVICE is not mounted at $SRC_ROOT (or elsewhere). Mount the disc and re-run." >&2
    exit 1
  fi
fi

# ---- Logging ----
ts="$(date +%Y%m%d-%H%M%S)"
LOGDIR="$DEST/.slow_copy_logs"; mkdir -p "$LOGDIR"
OK_LOG="$LOGDIR/copied_$ts.log"
ERR_LOG="$LOGDIR/errors_$ts.log"
touch "$OK_LOG" "$ERR_LOG"

# ---- Helpers ----
ensure_mounted() {
  if mountpoint -q "$SRC_ROOT"; then return 0; fi
  alt_mp="$(awk -v dev="$DEVICE" '$1==dev{print $2}' /proc/mounts | head -n1)"
  if [ -n "${alt_mp:-}" ] && mountpoint -q "$alt_mp"; then
    SRC_ROOT="$alt_mp"
    return 0
  fi
  sudo mkdir -p "$SRC_ROOT" 2>/dev/null || true
  sudo mount -t iso9660 -o ro,uid=$(id -u),gid=$(id -g) "$DEVICE" "$SRC_ROOT" 2>>"$ERR_LOG"
}

copy_one() {
  local src="$1" rel dst size_src size_dst attempt=0
  rel="${src#"$SRC_ROOT/"}"
  dst="$DEST/$rel"
  mkdir -p "$(dirname "$dst")"

  # Skip if already copied (size match)
  size_src=$(stat -c '%s' "$src" 2>/dev/null || echo -1)
  size_dst=$(stat -c '%s' "$dst" 2>/dev/null || echo -2)
  if [ "$size_src" -ge 0 ] && [ "$size_dst" -eq "$size_src" ]; then
    echo "  -> already copied (size match)"
    return 0
  fi

  while : ; do
    # Throttled read into a temp file; atomic move on success
    if pv -L "$RATE" "$src" > "$dst.part" 2>>"$ERR_LOG"; then
      touch -r "$src" "$dst.part" 2>>"$ERR_LOG" || true
      mv -f "$dst.part" "$dst"
      echo "$rel" >> "$OK_LOG"
      return 0
    fi
    attempt=$((attempt+1))
    echo "WARN: copy failed for $rel (attempt $attempt/$RETRIES)" | tee -a "$ERR_LOG"

    # If the source vanished (reset), try to remount and continue
    [ -e "$src" ] || { ensure_mounted >/dev/null 2>&1 || true; }

    [ "$attempt" -ge "$RETRIES" ] && { echo "FAIL: $rel" | tee -a "$ERR_LOG"; rm -f "$dst.part"; return 1; }
    sleep "$RETRY_SLEEP"
  done
}

# ---- Main (streamed traversal with de-dup) ----
declare -A seen=()
i=0

for top in "${FOLDERS[@]}"; do
  base="$SRC_ROOT/$top"
  if [ ! -d "$base" ]; then
    echo "NOTE: missing folder (skipping): $base" | tee -a "$ERR_LOG"
    continue
  fi

  while IFS= read -r -d '' f; do
    # De-duplicate identical paths (handles repeated directory entries under I/O stress)
    if [[ -n "${seen["$f"]+x}" ]]; then
      continue
    fi
    seen["$f"]=1

    i=$((i+1))
    rel="${f#"$SRC_ROOT/"}"
    printf '[%d] %s\n' "$i" "$rel"

    copy_one "$f" || true
    sleep "$SLEEP_BETWEEN"
  done < <(find "$base" -xdev -type f -print0 2>>"$ERR_LOG" || true)
done

echo
echo "Done. Copied entries listed in: $OK_LOG"
echo "Errors (if any) recorded in:    $ERR_LOG"
