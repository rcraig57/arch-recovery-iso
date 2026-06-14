#!/usr/bin/env bash
#
# partclone-backup.sh — PROTOTYPE: image a whole disk, one filesystem at a time,
# using partclone (used-blocks-only) + zstd compression.
#
# This is the BACKUP half of a planned partclone-based recovery pair. It does NOT
# restore anything and it NEVER writes to the source disk. It produces a folder
# of compressed per-partition images plus the metadata a future restore script
# needs (partition table, per-partition filesystem/UUID/size, checksums).
#
# Why partclone instead of dd:
#   - It is filesystem-aware (btrfs/ext4/fat/xfs/ntfs/...) and copies only the
#     USED blocks, so a 1 TB disk that is 100 GB full images ~100 GB, not 1 TB.
#   - For btrfs it captures the whole filesystem in one pass, so subvolumes come
#     along for free (no per-subvolume bookkeeping).
#   - It preserves filesystem UUIDs, so on restore fstab/bootloader still match.
#
# Hard rule (from partclone itself): the source filesystem MUST be unmounted.
# Run this against a disk you did NOT boot from (e.g. from a live USB, or — as in
# our test — back up /dev/sdb while booted off a different disk).
#
# Usage:
#   sudo ./partclone-backup.sh                 # interactive: pick disk + dest
#   sudo ./partclone-backup.sh /dev/sdb DEST   # non-interactive (for testing)
#   sudo ./partclone-backup.sh --yes [--force] /dev/sdb DEST   # no prompts (GUI)
#
# Env knobs:
#   ZSTD_LEVEL=3   zstd compression level (1 fastest/biggest .. 19 slow/smaller)
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Small output helpers (colored only when writing to a terminal).
# --------------------------------------------------------------------------- #
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_BLUE=$'\e[34m'
  C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'
else
  C_RESET=""; C_BOLD=""; C_BLUE=""; C_YELLOW=""; C_RED=""; C_GREEN=""
fi
msg()  { printf '%s==>%s %s\n'  "$C_BLUE$C_BOLD" "$C_RESET" "$*"; }
ok()   { printf '%s==>%s %s\n'  "$C_GREEN$C_BOLD" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n'  "$C_YELLOW$C_BOLD" "$C_RESET" "$*" >&2; }
err()  { printf '%s[x]%s %s\n'  "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

confirm() {
  # $1 = prompt, $2 = default ("y" or "n"). Returns 0 for yes.
  local prompt="$1" default="${2:-n}" reply hint
  if [[ "$default" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  read -r -p "$prompt $hint " reply || true
  reply="${reply:-$default}"
  [[ "$reply" =~ ^([yY]|[yY][eE][sS])$ ]]
}

# zstd level: speed-vs-size knob, not a correctness one.
ZSTD_LEVEL="${ZSTD_LEVEL:-3}"

# --------------------------------------------------------------------------- #
# 0. Must be root (raw block-device reads + partclone need it).
# --------------------------------------------------------------------------- #
[[ "$(id -u)" -eq 0 ]] || die "Run as root (e.g. sudo $0)."

# --------------------------------------------------------------------------- #
# 1. Tool preflight. partclone.<fs> binaries are checked per-partition later
#    (we only need the engines for the filesystems actually present).
# --------------------------------------------------------------------------- #
for t in lsblk blkid findmnt sfdisk zstd sha256sum partclone.dd; do
  command -v "$t" >/dev/null 2>&1 || die "Missing required tool: $t"
done
# Trim to the bare version token. Upstream's banner embeds an unexpanded
# "$Format:%h$" git placeholder; if that string lands in the metadata file it
# breaks the restore script's `source` under `set -u` ($Format = unbound).
PARTCLONE_VERSION="$(partclone.dd -v 2>&1 | grep -oiE 'v[0-9]+(\.[0-9]+)+' | head -1 || true)"
PARTCLONE_VERSION="${PARTCLONE_VERSION:-unknown}"

# --------------------------------------------------------------------------- #
# 2. Choose the SOURCE disk. Either passed as $1 or picked from a numbered menu.
#    We refuse any disk that has a mounted partition — that is almost certainly
#    the running system, and partclone needs the source quiescent anyway.
# --------------------------------------------------------------------------- #
disk_has_mount() {
  # 0 (true) if any partition of /dev/$1 is currently mounted.
  local d="$1" line
  while read -r line; do
    [[ -n "$line" ]] && return 0
  done < <(lsblk -nro MOUNTPOINTS "/dev/$d" | grep -v '^$' || true)
  return 1
}

estimate_used_bytes() {
  # Echo an UPPER-BOUND byte count for what imaging $1 will write, read from the
  # filesystem's own superblock WITHOUT mounting it (partclone needs the source
  # unmounted, so we must not mount it here either). Used-block engines report
  # their in-use bytes; anything we can't probe counts as the full partition
  # size; swap images nothing. zstd only ever shrinks this, so summing these is
  # a safe "will it fit?" check — never an under-estimate.
  local dev="$1" fstype used part_size
  fstype="$(lsblk -nro FSTYPE "$dev")"; fstype="${fstype:-none}"
  part_size="$(blockdev --getsize64 "$dev")"
  case "$fstype" in
    swap)
      echo 0 ;;
    btrfs)
      used="$(btrfs inspect-internal dump-super "$dev" 2>/dev/null \
              | awk '/^bytes_used/{print $2; exit}')"
      echo "${used:-$part_size}" ;;
    ext2|ext3|ext4)
      used="$(dumpe2fs -h "$dev" 2>/dev/null | awk -F: '
        /Block count/ {bc=$2}
        /Free blocks/ {fb=$2}
        /Block size/  {bs=$2}
        END { if (bc!="" && fb!="" && bs!="") printf "%d", (bc-fb)*bs }')"
      echo "${used:-$part_size}" ;;
    *)
      echo "$part_size" ;;
  esac
}

# Options (for the GUI / scripted use): --yes skips the "Proceed?" prompt,
# --force also proceeds past the "estimate exceeds free space" warning. Both
# default off so interactive terminal use is unchanged. Positional args remain
# SRC then DEST.
ASSUME_YES=0
FORCE=0
declare -a POS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)   ASSUME_YES=1 ;;
    -f|--force) FORCE=1 ;;
    --)         shift; while [[ $# -gt 0 ]]; do POS+=("$1"); shift; done; break ;;
    -*)         die "Unknown option: $1" ;;
    *)          POS+=("$1") ;;
  esac
  shift
done
set -- "${POS[@]+"${POS[@]}"}"

SRC_DISK="${1:-}"
if [[ -z "$SRC_DISK" ]]; then
  msg "Disks available to back up (mounted disks are hidden for safety):"
  mapfile -t CANDIDATES < <(lsblk -dnro NAME,TYPE | awk '$2=="disk"{print $1}')
  declare -a PICK=()
  local_i=0
  for d in "${CANDIDATES[@]}"; do
    if disk_has_mount "$d"; then continue; fi
    local_i=$((local_i+1))
    PICK+=("$d")
    printf '  %2d) /dev/%-8s %s  %s\n' "$local_i" "$d" \
      "$(lsblk -dnro SIZE  "/dev/$d")" \
      "$(lsblk -dno MODEL "/dev/$d" | tr -s ' ')"
  done
  [[ "${#PICK[@]}" -gt 0 ]] || die "No unmounted disks available to back up."
  read -r -p "Back up which disk? [1-${#PICK[@]}] " n || true
  [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$n" -le "${#PICK[@]}" ]] \
    || die "Invalid selection."
  SRC_DISK="/dev/${PICK[$((n-1))]}"
fi
[[ -b "$SRC_DISK" ]] || die "Not a block device: $SRC_DISK"
SRC_NAME="$(basename "$SRC_DISK")"
disk_has_mount "$SRC_NAME" && die "$SRC_DISK has a mounted partition — refusing."

# --------------------------------------------------------------------------- #
# 3. Choose the DESTINATION directory. Free space is reported and checked against
#    a pre-flight size estimate (see section 3b); pipefail is still the last-ditch
#    guard if the estimate is somehow beaten.
# --------------------------------------------------------------------------- #
DEST_PARENT="${2:-}"
if [[ -z "$DEST_PARENT" ]]; then
  read -r -p "Store the backup under which directory? " DEST_PARENT || true
fi
[[ -n "$DEST_PARENT" && -d "$DEST_PARENT" ]] || die "Not a directory: $DEST_PARENT"

# Never write the backup onto the disk we are imaging.
DEST_SRCDISK="$(lsblk -nro PKNAME "$(findmnt -nro SOURCE --target "$DEST_PARENT")" 2>/dev/null || true)"
[[ -n "$DEST_SRCDISK" && "/dev/$DEST_SRCDISK" == "$SRC_DISK" ]] \
  && die "Destination is on the source disk ($SRC_DISK) — choose another location."

HOST="$(hostnamectl --static 2>/dev/null || cat /etc/hostname 2>/dev/null || echo host)"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$DEST_PARENT/${HOST}-img-${STAMP}"
mkdir -p "$DEST"

# Tee the whole run (progress + errors) to a log inside the backup folder.
# NOTE: partclone writes the IMAGE to a pipe (-o - | zstd > file), never to this
# script's stdout, so teeing stdout is safe and won't corrupt the images.
LOGFILE="$DEST/backup.log"
exec > >(tee -a "$LOGFILE") 2>&1

# --------------------------------------------------------------------------- #
# 3b. Enumerate the source partitions once (used for both the estimate below and
#     the imaging loop), then sum a best-effort UPPER-BOUND size and compare it
#     to free space so we fail BEFORE writing anything if it clearly won't fit.
# --------------------------------------------------------------------------- #
mapfile -t PARTS < <(lsblk -rno NAME,TYPE "$SRC_DISK" | awk '$2=="part"{print $1}')
[[ "${#PARTS[@]}" -gt 0 ]] || die "No partitions found on $SRC_DISK."

EST_BYTES=0
for child in "${PARTS[@]}"; do
  EST_BYTES=$(( EST_BYTES + $(estimate_used_bytes "/dev/$child") ))
done
AVAIL_BYTES="$(df -B1 --output=avail "$DEST_PARENT" | tail -1 | tr -d ' ')"

msg "Source : $SRC_DISK ($(lsblk -dnro SIZE "$SRC_DISK"),$(lsblk -dno MODEL "$SRC_DISK" | tr -s ' '))"
msg "Dest   : $DEST"
msg "Free   : $(numfmt --to=iec "$AVAIL_BYTES") available"
msg "Est.   : ~$(numfmt --to=iec "$EST_BYTES") to write (upper bound; zstd only shrinks it)"
msg "zstd   : level $ZSTD_LEVEL (override with ZSTD_LEVEL=)"
echo
if (( EST_BYTES > AVAIL_BYTES )); then
  warn "Estimated size ($(numfmt --to=iec "$EST_BYTES")) exceeds free space ($(numfmt --to=iec "$AVAIL_BYTES"))."
  if (( FORCE )); then
    warn "--force given; continuing despite the space warning."
  else
    confirm "Continue anyway?" "n" || die "Aborted — free up space or pick another destination."
  fi
fi
if (( ASSUME_YES )); then
  msg "--yes given; proceeding without prompting."
else
  confirm "Proceed with the backup?" "y" || die "Aborted."
fi

START_EPOCH="$(date +%s)"

# --------------------------------------------------------------------------- #
# 4. Save the partition table. sfdisk -d preserves the GPT/MBR layout, partition
#    type GUIDs, UUIDs and names — everything restore needs to recreate it.
# --------------------------------------------------------------------------- #
msg "Saving partition table -> layout.sfdisk"
sfdisk -d "$SRC_DISK" > "$DEST/layout.sfdisk"
PART_TABLE="$(sfdisk -l "$SRC_DISK" 2>/dev/null | awk -F': ' '/Disklabel type/{print $2; exit}')"

# --------------------------------------------------------------------------- #
# 5. Map a filesystem type to the right partclone engine. Unknown/empty falls
#    back to partclone.dd (raw, full-size). swap is recorded but not imaged.
#    LUKS is imaged raw (its contents are encrypted, so used-block skipping and
#    compression do not help) — flagged loudly; the production version may keep
#    the existing v2 LUKS handling instead.
# --------------------------------------------------------------------------- #
engine_for_fstype() {
  case "$1" in
    btrfs)                 echo partclone.btrfs ;;
    ext2|ext3|ext4)        echo partclone.ext4  ;;
    vfat|fat|fat16|fat32|msdos) echo partclone.fat ;;
    exfat)                 echo partclone.exfat ;;
    xfs)                   echo partclone.xfs   ;;
    ntfs)                  echo partclone.ntfs  ;;
    f2fs)                  echo partclone.f2fs  ;;
    swap)                  echo SWAP            ;;
    crypto_LUKS)           echo partclone.dd    ;;
    *)                     echo partclone.dd    ;;
  esac
}

# --------------------------------------------------------------------------- #
# 6. Write metadata header, then image each partition.
# --------------------------------------------------------------------------- #
META="$DEST/backup-metadata.conf"
{
  echo "# partclone-backup metadata — generated $(date -Is)"
  echo "BACKUP_VERSION=1"
  echo "BACKUP_HOST=$HOST"
  echo "PARTCLONE_VERSION=\"$PARTCLONE_VERSION\""
  echo "SRC_DISK=$SRC_DISK"
  echo "SRC_DISK_MODEL=\"$(lsblk -dno MODEL "$SRC_DISK" | tr -s ' ')\""
  echo "SRC_DISK_SIZE_BYTES=$(blockdev --getsize64 "$SRC_DISK")"
  echo "SRC_PART_TABLE=${PART_TABLE:-unknown}"
  echo "ZSTD_LEVEL=$ZSTD_LEVEL"
} > "$META"

# Manifest consumed by the future restore script (tab-separated).
MANIFEST="$DEST/partitions.tsv"
printf 'partn\tdevname\tfstype\tengine\timage\tuuid\tsize_bytes\tsha256\n' > "$MANIFEST"

# Iterate the partitions in on-disk order (PARTS was gathered in section 3b).
for child in "${PARTS[@]}"; do
  dev="/dev/$child"
  findmnt -rn -S "$dev" >/dev/null 2>&1 && die "$dev is mounted — refusing."

  fstype="$(lsblk -nro FSTYPE "$dev")"; fstype="${fstype:-none}"
  uuid="$(lsblk -nro UUID "$dev")";     uuid="${uuid:--}"
  size="$(blockdev --getsize64 "$dev")"
  partn="$(lsblk -nro PARTN "$dev" 2>/dev/null || true)"; partn="${partn:-?}"
  engine="$(engine_for_fstype "$fstype")"

  # swap: nothing to image, just record it (restore recreates with mkswap).
  if [[ "$engine" == "SWAP" ]]; then
    warn "$dev is swap — recorded, not imaged."
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$partn" "$dev" "$fstype" "SWAP" "-" "$uuid" "$size" "-" >> "$MANIFEST"
    continue
  fi

  # Make sure the chosen engine exists; fall back to raw dd if not.
  if ! command -v "$engine" >/dev/null 2>&1; then
    warn "Engine $engine not installed; falling back to partclone.dd for $dev."
    engine="partclone.dd"
  fi
  [[ "$fstype" == "crypto_LUKS" ]] && \
    warn "$dev is LUKS — imaging raw (no used-block skip, poor compression)."

  if [[ "$engine" == "partclone.dd" ]]; then
    label="raw"
  else
    label="$fstype"
  fi
  img="p${partn}.${label}.img.zst"

  msg "Imaging $dev  ($fstype, $(numfmt --to=iec "$size"))  via $engine -> $img"

  # The key pipeline. partclone reads only used blocks (except dd) and streams
  # the image to stdout; zstd compresses it; tee writes the compressed image to
  # disk while sha256sum hashes the SAME stream in flight — so the checksum costs
  # nothing extra (no second full re-read of the image afterwards). pipefail
  # makes any stage failing (partclone error, zstd error, or tee hitting a full
  # disk) abort the run, and set -e propagates that out of the command sub.
  if [[ "$engine" == "partclone.dd" ]]; then
    sum="$("$engine" -s "$dev" -o - \
      | zstd -T0 "-$ZSTD_LEVEL" \
      | tee "$DEST/$img" \
      | sha256sum | awk '{print $1}')"
  else
    sum="$("$engine" -c -s "$dev" -o - \
      | zstd -T0 "-$ZSTD_LEVEL" \
      | tee "$DEST/$img" \
      | sha256sum | awk '{print $1}')"
  fi

  # Write the checksum file in standard `sha256sum` format (hash + two spaces +
  # filename) so a future `sha256sum -c *.sha256` works from inside $DEST.
  printf '%s  %s\n' "$sum" "$img" > "$DEST/$img.sha256"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$partn" "$dev" "$fstype" "$engine" "$img" "$uuid" "$size" "$sum" >> "$MANIFEST"
  ok "Done $dev -> $img ($(du -h "$DEST/$img" | cut -f1))"
done

# --------------------------------------------------------------------------- #
# 7. Summary.
# --------------------------------------------------------------------------- #
ELAPSED=$(( $(date +%s) - START_EPOCH ))
TOTAL="$(du -sh "$DEST" | cut -f1)"
echo
ok "Backup complete."
msg "Folder : $DEST"
msg "Size   : $TOTAL"
msg "Time   : ${ELAPSED}s ($(printf '%dm%02ds' $((ELAPSED/60)) $((ELAPSED%60))))"
msg "Files  : layout.sfdisk, backup-metadata.conf, partitions.tsv, *.img.zst(+.sha256)"
