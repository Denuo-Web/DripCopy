# DripCopy — Gentle Optical Media Copier for Underpowered USB Hosts

**Program name:** `DripCopy`  
**One‑line description:** A resilient, rate‑limited, one‑file‑per‑second copier for CD/DVD data on low‑power or unstable USB hosts (e.g., Raspberry Pi), designed to prevent optical drives from ramping to high RPM and brown‑out resetting.

---

## Why this program exists

Conventional file copying from optical media (e.g., `cp -a`, `rsync`, or dumping the whole block device with `dd`) can cause external USB CD/DVD drives to **spin up to high RPM**. On hosts with limited 5 V current—typical of single‑board computers and many bus‑powered ports—these sustained spin‑ups lead to **voltage sag**, **USB resets**, and kernel‑level I/O errors (often surfacing as “`Input/output error`” or the misleading “`Cannot allocate memory`” during directory enumeration). Once the device resets, the filesystem view may partially collapse, causing repeated paths, inflated file counts, and stalled transfers.

`DripCopy` addresses this by copying **gently**:

- It **throttles each file read** (via `pv -L`) to a user‑specified rate (e.g., 150 KiB/s), making the drive firmware less likely to jump to full RPM.  
- It **paces** the drive with a **1‑second sleep between files**, allowing the spindle and the 5 V rail to recover.  
- It **deduplicates paths on the fly**, so transient directory read glitches do not cause repeated work or runaway counts.  
- It **skips already‑copied outputs** (size match) to support **resumable** operation.  
- It performs **atomic writes** to avoid partial/corrupt outputs on interruption.  
- It **retries** failures and attempts to **remount** if the device disappears.  
- It records **success and error logs** for post‑run analysis.

The result is a practical, fault‑tolerant way to extract files from discs when you cannot (yet) use a powered USB hub or dual‑plug Y‑cable, and when imaging the entire disc with `ddrescue` is overkill or impossible due to repeated bus resets.

> **Note:** If you require a *bit‑perfect* image of the disc, use `ddrescue` with a mapfile on `/dev/srX` and power the drive adequately. `DripCopy` focuses on *file extraction* with high tolerance for flaky power and transient device resets.

---

## Features

- **Rate‑limited per‑file I/O** using `pv -L` (default 150 KiB/s; configurable).  
- **One‑file‑per‑second pacing** (`sleep 1` by default; configurable).  
- **On‑the‑fly de‑duplication** of paths from `find` to neutralize repeated directory entries under I/O stress.  
- **Resumable runs** that **skip already‑copied files** by size.  
- **Atomic writes** via a `*.part` temporary with `mv` on success.  
- **Best‑effort kernel hints** to reduce readahead bursts (`read_ahead_kb=0`, `blockdev --setra 0`).  
- **Retry logic** per file with **back‑off delay**.  
- **Mount recovery** attempts if the automounted path collapses after a USB reset.  
- **Structured logs** under `DEST/.slow_copy_logs/` for successes and failures.

---

## System requirements

- **OS:** Linux (tested on Debian/Raspberry Pi OS “bookworm”).  
- **Shell/tools:** `bash`, `find`, `stat`, `mv`, `touch`, `tee`.  
- **Required package:** [`pv`](https://www.ivarch.com/programs/pv.shtml) for rate limiting.  
- **Optional:** `sudo` for adjusting readahead on `/dev/srX` and for mounting; administrator privileges may be needed depending on your setup.

Install `pv` on Debian/Ubuntu/Raspberry Pi OS:
```bash
sudo apt-get update && sudo apt-get install -y pv
```

---

## Installation

1. Place `dripcopy.sh` somewhere on your `$PATH` (e.g., `~/bin` or `/usr/local/bin`).  
2. Make it executable:
   ```bash
   chmod +x dripcopy.sh
   ```
3. Ensure your disc is inserted and recognized (often automounted under `/media/$USER/...`).

---

## Usage

Basic invocation (defaults shown below are sensible for Raspberry Pi‑class hardware):

```bash
./dripcopy.sh
```

### Important environment variables

You can override behavior without editing the script by setting variables on the command line:

- **DEVICE**: Optical device node. Default: `/dev/sr1`  
  Example: `DEVICE=/dev/sr0 ./dripcopy.sh`

- **SRC_ROOT**: Mountpoint of the disc. Default: `/media/den/Genki1_text1`  
  The script will auto‑detect the current automount for `DEVICE` if `SRC_ROOT` is not a mount point.

- **FOLDERS**: Top‑level folders (array) to copy. Default: `("Genki1_KaiwaBunpo-hen" "Genki1_Yomikaki-hen")`  
  Example: `FOLDERS='("AUDIO_TS" "VIDEO_TS")' ./dripcopy.sh`

- **DEST**: Destination directory for copied files. Default: `~/cd_copy`

- **RATE**: Per‑file read limit passed to `pv -L`. Default: `150k`  
  Lower this (e.g., `120k` or `100k`) if the drive still spins up or resets; raise slightly if stable.

- **SLEEP_BETWEEN**: Seconds to sleep between files. Default: `1`

- **RETRIES**: Copy retries per file. Default: `3`

- **RETRY_SLEEP**: Seconds to sleep before each retry. Default: `3`

- **READAHEAD_KB**: Kernel readahead hint for `/dev/srX`. Default: `0` (disable).

**Examples**

Copy with tighter throttling and longer rests:
```bash
RATE=120k SLEEP_BETWEEN=2 ./dripcopy.sh
```

Use a different device and destination:
```bash
DEVICE=/dev/sr0 DEST="$HOME/genki_copy" ./dripcopy.sh
```

Specify your own top‑level folders:
```bash
FOLDERS='("DiscContent" "Exercises")' ./dripcopy.sh
```

---

## What the script actually does (algorithm overview)

1. **Setup and tuning.** Optionally reduces kernel readahead for the optical device to prevent bursty reads that cause sudden spin‑ups. Ensures `DEST` is writable by the invoking user.  
2. **Mount resolution.** Verifies that `SRC_ROOT` is a mount point; if not, attempts to discover the current automount for `DEVICE` (via `/proc/mounts`) and uses it.  
3. **Streamed traversal.** For each specified top‑level folder, the script streams a `find -print0` of files and processes entries one at a time.  
4. **De‑duplication.** Maintains an in‑memory hash of seen paths to ignore duplicates caused by transient kernel read glitches.  
5. **Skip already‑copied.** Compares source and destination sizes; identical sizes are skipped to allow resumable runs.  
6. **Throttled copy.** Uses `pv -L RATE` to throttle each file read, writing to a `*.part` file, then atomically renames to the target path on success; preserves modification times (`touch -r`).  
7. **Retries and recovery.** On failure, waits `RETRY_SLEEP` seconds and retries up to `RETRIES` times; if the source disappeared, it attempts to re‑establish the mount and continues.  
8. **Pacing.** Sleeps `SLEEP_BETWEEN` seconds between files to let the drive and USB 5 V rail recover.  
9. **Logging.** Records successes in `copied_*.log` and errors in `errors_*.log` under `DEST/.slow_copy_logs/`.

---

## When to use DripCopy vs. ddrescue

- **Use DripCopy** when you primarily need the *files* and your host’s USB power is marginal. DripCopy minimizes sustained current draw and tolerates transient resets.  
- **Use ddrescue** when you need a *bit‑exact* image (ISO) or forensic‑grade recovery. For ddrescue to work well, supply adequate power (powered USB hub or Y‑cable) so the device does not reset mid‑read.

---

## Troubleshooting

- **“Cannot allocate memory”** while listing or copying from the mountpoint:  
  This is typically an optical I/O error/USB reset surfacing via the VFS path. Unmount, power‑cycle the drive, lower `RATE`, and try again. Consider a powered hub.

- **“No medium found” / device disappears:**  
  The drive likely brown‑ed out and reset. Power‑cycle; try `RATE=100k` and ensure `SLEEP_BETWEEN≥1`. A powered hub solves this decisively.

- **Repeated path entries / inflated file counts:**  
  Caused by transient errors during directory enumeration. DripCopy de‑duplicates entries, so it safely ignores duplicates and continues.

- **Permission denied writing to `DEST`:**  
  If you previously wrote as `root`, fix ownership:  
  ```bash
  sudo chown -R "$USER":"$USER" "$DEST"
  chmod -R u+rwX "$DEST"
  ```

- **Automounter conflicts:**  
  If the desktop automounter fights with manual mounts, prefer the existing automount path. DripCopy will discover and use it automatically when possible.

---

## Limitations

- DripCopy does not validate file integrity beyond size and successful read completion; it is not a bit‑exact imaging tool.  
- If firmware insists on full‑RPM retries for damaged sectors, even low `RATE` may not prevent spin‑up; **hardware power fixes** (powered USB hub/Y‑cable) are then required.  
- De‑duplication is path‑based; if the kernel returns *different* bogus paths for the same on‑disc object, both may be attempted (harmless but noisy).

---

## Verifying results

- Spot‑check with `file`, `ffprobe`, or media players for audio content.  
- Use checksums if you have a known‑good reference:
  ```bash
  (cd "$DEST" && find . -type f -print0 | xargs -0 md5sum) > DEST.md5
  ```

---

## License

MIT License. See header in `dripcopy.sh` for details.

---

## Acknowledgements

- The `pv` utility by Andrew Wood.  
- The Linux kernel & userspace tools (`find`, `stat`, `blockdev`) that make controlled I/O patterns possible on constrained hardware.

---

## Changelog (initial)

- **v0.1.0** — First public release: streamed traversal, per‑file throttling, de‑duplication, retries, remount attempt, atomic writes, resumable operation.
