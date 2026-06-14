#!/usr/bin/env bash
#
# test-grow-loopback.sh — exercise the grow-last-partition path of
# partclone-restore.sh with NO spare hardware, using loopback files.
#
# What it does, entirely inside two sparse image files + /dev/loop devices:
#   1. Builds a SMALL "source" disk: GPT + a vfat ESP + a btrfs (or ext4) last
#      partition with a marker file in it.
#   2. Runs partclone-backup.sh against that source loop device.
#   3. Builds a LARGER "target" loop device and runs partclone-restore.sh onto
#      it non-interactively, accepting the grow prompt.
#   4. Verifies the last partition was grown to fill the larger disk AND the
#      marker file (so the data) survived the restore+grow.
#
# Nothing here touches a real disk: losetup binds the loop devices to files we
# create under a temp dir, and the backup/restore scripts only ever see those
# /dev/loopN paths. Safe to run on the live host.
#
# Usage:
#   sudo ./test-grow-loopback.sh            # btrfs last partition (default)
#   sudo ./test-grow-loopback.sh ext4       # ext4 last partition instead
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Small helpers + a cleanup trap so we never leave loop devices/mounts behind.
# --------------------------------------------------------------------------- #
msg()  { printf '\e[34;1m==>\e[0m %s\n' "$*"; }
ok()   { printf '\e[32;1m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[33;1m[!]\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[31;1m[x]\e[0m %s\n' "$*" >&2; exit 1; }

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$HERE/partclone-backup.sh"
RESTORE_SCRIPT="$HERE/partclone-restore.sh"

WORKDIR=""; SRC_LOOP=""; TGT_LOOP=""; CHECK_MP=""
cleanup() {
  [[ -n "$CHECK_MP" ]] && { umount "$CHECK_MP" 2>/dev/null || true; rmdir "$CHECK_MP" 2>/dev/null || true; }
  [[ -n "$SRC_LOOP" ]] && losetup -d "$SRC_LOOP" 2>/dev/null || true
  [[ -n "$TGT_LOOP" ]] && losetup -d "$TGT_LOOP" 2>/dev/null || true
  [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

# --------------------------------------------------------------------------- #
# 0. Preconditions.
# --------------------------------------------------------------------------- #
[[ "$(id -u)" -eq 0 ]] || die "Run as root (e.g. sudo $0)."
[[ -x "$BACKUP_SCRIPT"  ]] || die "Not found/executable: $BACKUP_SCRIPT"
[[ -x "$RESTORE_SCRIPT" ]] || die "Not found/executable: $RESTORE_SCRIPT"

LASTFS="${1:-btrfs}"
case "$LASTFS" in
  btrfs) MKFS=(mkfs.btrfs -q -f);            NEEDS=(mkfs.btrfs btrfs) ;;
  ext4)  MKFS=(mkfs.ext4 -q -F);             NEEDS=(mkfs.ext4 resize2fs e2fsck) ;;
  *)     die "Unsupported last-fs '$LASTFS' (use btrfs or ext4)." ;;
esac
for t in losetup sgdisk mkfs.vfat partprobe blkid "${NEEDS[@]}"; do
  command -v "$t" >/dev/null 2>&1 || die "Missing required tool: $t"
done

# A sparse file's apparent size; real disk usage stays tiny because mkfs +
# partclone only write used blocks. Source 2 GiB, target 6 GiB (3 GiB+ slack so
# restore's >1 GiB grow threshold fires).
SRC_SIZE_MB=2048
TGT_SIZE_MB=6144
WORKDIR="$(mktemp -d /var/tmp/partclone-growtest.XXXXXX)"
[[ -d "$WORKDIR" ]] || die "Could not create work dir."
# Work dir must live on a SPARSE-capable fs (ext4/btrfs/xfs). exfat/vfat would
# fully allocate the image files; /var/tmp on the root fs is fine.
SRC_IMG="$WORKDIR/source.img"
TGT_IMG="$WORKDIR/target.img"
BACKDIR="$WORKDIR/backup"
mkdir -p "$BACKDIR"
MARKER="partclone-growtest-marker-$(date +%s)"

msg "Work dir : $WORKDIR  (last-partition fs: $LASTFS)"
msg "Source   : ${SRC_SIZE_MB} MiB sparse -> backup -> ${TGT_SIZE_MB} MiB target"

# --------------------------------------------------------------------------- #
# 1. Build the SMALL source disk: GPT, ESP (vfat), last partition ($LASTFS).
# --------------------------------------------------------------------------- #
truncate -s "${SRC_SIZE_MB}M" "$SRC_IMG"
# -P makes the kernel scan the partition table and create loopNpX nodes.
SRC_LOOP="$(losetup --find --show -P "$SRC_IMG")"
msg "Source loop: $SRC_LOOP"

# One invocation: ESP = 256 MiB (EF00), data = rest of disk (8300 Linux).
# Start "0" lets sgdisk pick the next aligned free sector (no manual overlap),
# "+256M" sizes the ESP, the second "0:0" runs from there to the last sector.
sgdisk -Z \
  -n "1:0:+256M" -t "1:EF00" -c "1:ESP"  \
  -n "2:0:0"     -t "2:8300" -c "2:root" "$SRC_LOOP" >/dev/null
partprobe "$SRC_LOOP"; udevadm settle 2>/dev/null || true

mkfs.vfat -F32 "${SRC_LOOP}p1" >/dev/null
"${MKFS[@]}" "${SRC_LOOP}p2"

# Drop a marker file into the data partition so we can prove data survived.
CHECK_MP="$(mktemp -d)"
mount "${SRC_LOOP}p2" "$CHECK_MP"
printf '%s\n' "$MARKER" > "$CHECK_MP/MARKER.txt"
sync
umount "$CHECK_MP"; rmdir "$CHECK_MP"; CHECK_MP=""
ok "Source disk built (ESP + ${LASTFS} with marker)."

# --------------------------------------------------------------------------- #
# 2. Back it up (non-interactive: disk + dest as args).
# --------------------------------------------------------------------------- #
msg "Running partclone-backup.sh ..."
"$BACKUP_SCRIPT" "$SRC_LOOP" "$BACKDIR"
# The backup script makes a timestamped subfolder under $BACKDIR; find it.
IMG_DIR="$(find "$BACKDIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
[[ -n "$IMG_DIR" && -r "$IMG_DIR/backup-metadata.conf" ]] || die "Backup folder not found under $BACKDIR."
ok "Backup written to $IMG_DIR"

# Free the source loop before restore so it can't be a target candidate.
losetup -d "$SRC_LOOP"; SRC_LOOP=""

# --------------------------------------------------------------------------- #
# 3. Build the LARGER target loop and restore onto it. We feed the ERASE gate
#    and the grow prompt over stdin (backup_dir + target are positional args).
# --------------------------------------------------------------------------- #
truncate -s "${TGT_SIZE_MB}M" "$TGT_IMG"
TGT_LOOP="$(losetup --find --show -P "$TGT_IMG")"
msg "Target loop: $TGT_LOOP  (${TGT_SIZE_MB} MiB)"

# stdin answers, in order the restore script reads them:
#   ERASE            -> the type-ERASE gate
#   y                -> "grow last partition to fill it?"
#   n                -> "re-register bootloader?" (loop file has no real OS)
#   n                -> "reboot now?"
#   n                -> "power off now?"
msg "Running partclone-restore.sh onto $TGT_LOOP ..."
printf 'ERASE\ny\nn\nn\nn\n' | "$RESTORE_SCRIPT" "$IMG_DIR" "$TGT_LOOP"

# --------------------------------------------------------------------------- #
# 4. Verify: (a) the last partition now extends to (near) the disk end, and
#    (b) the filesystem was grown, and (c) the marker file survived.
# --------------------------------------------------------------------------- #
partprobe "$TGT_LOOP"; udevadm settle 2>/dev/null || true
msg "Verifying grow + data..."

# Partition end (in sectors) vs disk end. sgdisk -i 2 prints the last sector.
LAST_SECTOR="$(sgdisk -i 2 "$TGT_LOOP" | sed -n 's/^Last sector: \([0-9]\+\).*/\1/p')"
DISK_END="$(sgdisk -p "$TGT_LOOP" | sed -n 's/.*last usable sector is \([0-9]\+\).*/\1/p')"
[[ -n "$LAST_SECTOR" && -n "$DISK_END" ]] || die "Could not read partition/disk geometry."
# Allow a little GPT slack (sgdisk -e leaves the secondary header room).
SLACK_SECTORS=$(( DISK_END - LAST_SECTOR ))
msg "Last partition end sector: $LAST_SECTOR / disk last usable: $DISK_END (slack ${SLACK_SECTORS}s)"
(( SLACK_SECTORS >= 0 && SLACK_SECTORS < 70000 )) \
  || die "Partition was NOT grown to fill the disk (slack ${SLACK_SECTORS} sectors)."
ok "Partition grew to fill the larger disk."

# Filesystem size should now be close to the partition size, and marker intact.
CHECK_MP="$(mktemp -d)"
mount "${TGT_LOOP}p2" "$CHECK_MP"
FS_AVAIL_MB="$(df -BM --output=size "$CHECK_MP" | tail -1 | tr -dc '0-9')"
msg "Grown filesystem total size: ${FS_AVAIL_MB} MiB (target partition ~$((TGT_SIZE_MB-256)) MiB)"
(( FS_AVAIL_MB > SRC_SIZE_MB )) \
  || die "Filesystem did not grow (still ${FS_AVAIL_MB} MiB)."

GOT="$(cat "$CHECK_MP/MARKER.txt" 2>/dev/null || true)"
[[ "$GOT" == "$MARKER" ]] || die "Marker file missing/changed after restore (got: '$GOT')."
umount "$CHECK_MP"; rmdir "$CHECK_MP"; CHECK_MP=""

echo
ok "PASS — grow path works: partition + filesystem expanded and data survived."
msg "(loop devices and image files are cleaned up automatically on exit.)"
