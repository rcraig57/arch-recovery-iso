#!/usr/bin/env bash
#
# partclone-restore.sh — PROTOTYPE: restore a whole disk from a backup folder
# produced by partclone-backup.sh.
#
# It recreates the partition table, writes each saved filesystem image back with
# partclone.restore, optionally grows the last partition to fill a larger target
# disk, and (optionally) re-registers the bootloader. Because partclone images
# are block-exact and preserve filesystem UUIDs, the restored disk's fstab and
# bootloader cmdline already match — so on the SAME or a NEW machine it should
# boot via the EFI fallback already present on the restored ESP. The bootloader
# step is belt-and-suspenders.
#
# *** THIS ERASES THE TARGET DISK. *** It refuses mounted disks, verifies every
# image checksum BEFORE touching the target, and requires you to type ERASE.
#
# Usage:
#   sudo ./partclone-restore.sh                       # interactive
#   sudo ./partclone-restore.sh BACKUP_DIR /dev/sdX   # non-interactive target
#   sudo ./partclone-restore.sh --erase --no-grow --no-bootloader --no-reboot \
#        BACKUP_DIR /dev/sdX                           # fully scripted (GUI)
#
# Env knobs:
#   BOOTLOADER_DRYRUN=1   In the bootloader step (8), still mount the restored
#                         root/ESP and DETECT the bootloader, but PRINT the
#                         chroot install command instead of running it. Lets you
#                         validate the detection + command construction on a
#                         same-machine restore without an actual reinstall.
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Output helpers (match partclone-backup.sh).
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
  local prompt="$1" default="${2:-n}" reply hint
  if [[ "$default" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  read -r -p "$prompt $hint " reply || true
  reply="${reply:-$default}"
  [[ "$reply" =~ ^([yY]|[yY][eE][sS])$ ]]
}

# Bootloader-step dry run: print the would-be chroot command instead of running.
BOOTLOADER_DRYRUN="${BOOTLOADER_DRYRUN:-0}"
run_bl() {
  # Execute "$@", or — under BOOTLOADER_DRYRUN=1 — just print it and succeed.
  if [[ "$BOOTLOADER_DRYRUN" == "1" ]]; then
    printf '%s[dry-run]%s would run: %s\n' "$C_YELLOW$C_BOLD" "$C_RESET" "$*"
    return 0
  fi
  "$@"
}

# Given a whole-disk path and a partition number, return the partition device.
# nvme/mmc disks end in a digit and need a 'p' separator (nvme0n1p2); sd* do not.
part_dev() {
  local disk="$1" n="$2"
  if [[ "$disk" =~ [0-9]$ ]]; then echo "${disk}p${n}"; else echo "${disk}${n}"; fi
}

# --------------------------------------------------------------------------- #
# 0. Root + tool preflight.
# --------------------------------------------------------------------------- #
[[ "$(id -u)" -eq 0 ]] || die "Run as root (e.g. sudo $0)."
for t in lsblk blkid findmnt sfdisk sgdisk partprobe zstd sha256sum \
         partclone.restore blockdev; do
  command -v "$t" >/dev/null 2>&1 || die "Missing required tool: $t"
done

# --------------------------------------------------------------------------- #
# 0b. Options (for the GUI / scripted use). All default to the interactive
#     behavior so terminal use is unchanged. Positional args remain
#     BACKUP_DIR then TARGET.
#       --erase            bypass the type-ERASE gate (caller already confirmed)
#       --grow|--no-grow   grow the last partition without prompting
#       --bootloader|--no-bootloader  run/skip §8 without prompting
#       --no-reboot        skip the final reboot/power-off prompts
# --------------------------------------------------------------------------- #
ERASE_OK=0
GROW_MODE=auto      # auto = prompt; yes/no = non-interactive
BOOT_MODE=auto      # auto = prompt; yes/no = non-interactive
NO_REBOOT=0
declare -a POS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --erase)         ERASE_OK=1 ;;
    --grow)          GROW_MODE=yes ;;
    --no-grow)       GROW_MODE=no ;;
    --bootloader)    BOOT_MODE=yes ;;
    --no-bootloader) BOOT_MODE=no ;;
    --no-reboot)     NO_REBOOT=1 ;;
    --)              shift; while [[ $# -gt 0 ]]; do POS+=("$1"); shift; done; break ;;
    -*)              die "Unknown option: $1" ;;
    *)               POS+=("$1") ;;
  esac
  shift
done
set -- "${POS[@]+"${POS[@]}"}"

# --------------------------------------------------------------------------- #
# 1. Locate the backup folder and read its metadata + manifest.
# --------------------------------------------------------------------------- #
BACKUP_DIR="${1:-}"
if [[ -z "$BACKUP_DIR" ]]; then
  read -r -p "Path to the backup folder: " BACKUP_DIR || true
fi
[[ -d "$BACKUP_DIR" ]] || die "Not a directory: $BACKUP_DIR"
BACKUP_DIR="$(cd -- "$BACKUP_DIR" && pwd)"
META="$BACKUP_DIR/backup-metadata.conf"
MANIFEST="$BACKUP_DIR/partitions.tsv"
LAYOUT="$BACKUP_DIR/layout.sfdisk"
for f in "$META" "$MANIFEST" "$LAYOUT"; do
  [[ -r "$f" ]] || die "Backup is missing $(basename "$f")."
done

# Source with `set +u` so a stray unexpanded "$Format:%h$" placeholder in an
# older PARTCLONE_VERSION line can't abort us with "unbound variable".
set +u
# shellcheck source=/dev/null
source "$META"
set -u
SRC_DISK_SIZE_BYTES="${SRC_DISK_SIZE_BYTES:-0}"
msg "Backup : $BACKUP_DIR"
msg "Source : ${SRC_DISK:-?} (${SRC_DISK_MODEL:-?}), $(numfmt --to=iec "${SRC_DISK_SIZE_BYTES:-0}")"
msg "Table  : ${SRC_PART_TABLE:-?}"

# --------------------------------------------------------------------------- #
# 2. Verify every image checksum BEFORE we touch any disk. Never restore from a
#    backup we can't prove is intact.
# --------------------------------------------------------------------------- #
msg "Verifying image checksums (this reads every image once)..."
while IFS=$'\t' read -r partn _ fstype engine image uuid _ _; do
  [[ "$partn" == "partn" ]] && continue          # header
  [[ "$engine" == "SWAP" ]] && continue           # swap has no image
  [[ -r "$BACKUP_DIR/$image" ]] || die "Missing image: $image"
  ( cd "$BACKUP_DIR" && sha256sum -c --quiet "$image.sha256" ) \
    || die "Checksum FAILED for $image — backup is corrupt, aborting."
done < "$MANIFEST"
ok "All image checksums verified."

# --------------------------------------------------------------------------- #
# 3. Choose the TARGET disk. Refuse mounted disks and the disk holding the
#    backup itself.
# --------------------------------------------------------------------------- #
disk_has_mount() {
  local d="$1" line
  while read -r line; do
    [[ -n "$line" ]] && return 0
  done < <(lsblk -nro MOUNTPOINTS "/dev/$d" | grep -v '^$' || true)
  return 1
}
BACKUP_DISK="$(lsblk -nro PKNAME "$(findmnt -nro SOURCE --target "$BACKUP_DIR")" 2>/dev/null || true)"

TARGET="${2:-}"
if [[ -z "$TARGET" ]]; then
  msg "Disks available as a restore target (mounted disks hidden):"
  mapfile -t CANDIDATES < <(lsblk -dnro NAME,TYPE | awk '$2=="disk"{print $1}')
  declare -a PICK=()
  idx=0
  for d in "${CANDIDATES[@]}"; do
    disk_has_mount "$d" && continue
    [[ -n "$BACKUP_DISK" && "$d" == "$BACKUP_DISK" ]] && continue
    idx=$((idx+1)); PICK+=("$d")
    printf '  %2d) /dev/%-8s %s  %s\n' "$idx" "$d" \
      "$(lsblk -dnro SIZE "/dev/$d")" "$(lsblk -dno MODEL "/dev/$d" | tr -s ' ')"
  done
  [[ "${#PICK[@]}" -gt 0 ]] || die "No unmounted target disks available."
  read -r -p "Restore ONTO which disk? [1-${#PICK[@]}] " n || true
  [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$n" -le "${#PICK[@]}" ]] || die "Invalid selection."
  TARGET="/dev/${PICK[$((n-1))]}"
fi
[[ -b "$TARGET" ]] || die "Not a block device: $TARGET"
TARGET_NAME="$(basename "$TARGET")"
disk_has_mount "$TARGET_NAME" && die "$TARGET has a mounted partition — refusing."
[[ -n "$BACKUP_DISK" && "$TARGET_NAME" == "$BACKUP_DISK" ]] \
  && die "Target is the disk holding the backup — refusing."

# --------------------------------------------------------------------------- #
# 4. Size check, then the ERASE gate. Die BEFORE writing if the target is too
#    small (we lay down the source's table verbatim, so target >= source size).
# --------------------------------------------------------------------------- #
TARGET_SIZE="$(blockdev --getsize64 "$TARGET")"
if (( TARGET_SIZE < SRC_DISK_SIZE_BYTES )); then
  die "Target $(numfmt --to=iec "$TARGET_SIZE") is smaller than source $(numfmt --to=iec "$SRC_DISK_SIZE_BYTES") — cannot restore."
fi

echo
warn "About to ERASE $TARGET ($(lsblk -dno MODEL "$TARGET" | tr -s ' '), $(numfmt --to=iec "$TARGET_SIZE"))"
warn "Every partition on it will be destroyed and replaced from the backup."
if (( ERASE_OK )); then
  warn "--erase given; the caller has already confirmed. Proceeding."
else
  read -r -p "Type ERASE to proceed: " reply || true
  [[ "$reply" == "ERASE" ]] || die "Not confirmed — nothing was changed."
fi

# --------------------------------------------------------------------------- #
# 5. Recreate the partition table, then fix the GPT backup header position
#    (harmless on a same-size disk, required on a larger one).
# --------------------------------------------------------------------------- #
msg "Writing partition table to $TARGET"
wipefs -a "$TARGET" >/dev/null
sfdisk "$TARGET" < "$LAYOUT"
[[ "${SRC_PART_TABLE:-}" == "gpt" ]] && sgdisk -e "$TARGET" >/dev/null 2>&1 || true
partprobe "$TARGET"; udevadm settle 2>/dev/null || true

# --------------------------------------------------------------------------- #
# 6. Restore each partition image (swap is recreated, not restored).
# --------------------------------------------------------------------------- #
while IFS=$'\t' read -r partn _ fstype engine image uuid _ _; do
  [[ "$partn" == "partn" ]] && continue
  tdev="$(part_dev "$TARGET" "$partn")"
  [[ -b "$tdev" ]] || die "Expected target partition $tdev did not appear."

  if [[ "$engine" == "SWAP" ]]; then
    msg "Recreating swap on $tdev (UUID $uuid)"
    if [[ "$uuid" != "-" ]]; then mkswap -U "$uuid" "$tdev" >/dev/null
    else mkswap "$tdev" >/dev/null; fi
    continue
  fi

  msg "Restoring $image -> $tdev ($fstype)"
  if [[ "$engine" == "partclone.dd" ]]; then
    zstd -dc "$BACKUP_DIR/$image" | partclone.dd -s - -o "$tdev"
  else
    zstd -dc "$BACKUP_DIR/$image" | partclone.restore -s - -o "$tdev"
  fi
  ok "Restored $tdev"
done < "$MANIFEST"

# --------------------------------------------------------------------------- #
# 7. OPTIONAL: grow the last data partition to fill a larger target. partclone
#    wrote each filesystem at its ORIGINAL size, so on a bigger disk the last
#    partition has free space after it. This is the least battle-tested path —
#    it is offered, not automatic. (btrfs and ext4 only.)
# --------------------------------------------------------------------------- #
SLACK=$(( TARGET_SIZE - SRC_DISK_SIZE_BYTES ))
if (( SLACK > 1024*1024*1024 )); then          # >1 GiB of slack worth using
  # Last data partition = highest partn whose fstype is growable.
  LAST_N=""; LAST_FS=""
  while IFS=$'\t' read -r partn _ fstype engine image uuid _ _; do
    [[ "$partn" == "partn" ]] && continue
    case "$fstype" in btrfs|ext2|ext3|ext4) LAST_N="$partn"; LAST_FS="$fstype" ;; esac
  done < "$MANIFEST"

  if [[ -n "$LAST_N" ]]; then
    echo
    do_grow=0
    case "$GROW_MODE" in
      yes) do_grow=1; msg "Growing partition $LAST_N ($LAST_FS) to fill the larger target (--grow)." ;;
      no)  msg "--no-grow given; leaving partition $LAST_N at its original size." ;;
      *)   confirm "Target is $(numfmt --to=iec "$SLACK") larger. Grow partition $LAST_N ($LAST_FS) to fill it?" "y" && do_grow=1 ;;
    esac
    if (( do_grow )); then
      # Pull the last partition's start/type/uuid/name from the saved layout and
      # recreate it ending at the disk max (same start = data untouched).
      # layout.sfdisk stores the SOURCE device names, so match on SRC_DISK.
      line="$(grep -E "^${SRC_DISK}p?${LAST_N} *:" "$LAYOUT" | head -1 || true)"
      start="$(sed -n 's/.*start= *\([0-9]\+\).*/\1/p' <<<"$line")"
      gtype="$(sed -n 's/.*type=\([0-9A-Fa-f-]\+\).*/\1/p' <<<"$line")"
      guid="$(sed -n 's/.*uuid=\([0-9A-Fa-f-]\+\).*/\1/p' <<<"$line")"
      if [[ -n "$start" ]]; then
        msg "Growing partition $LAST_N to end of disk"
        sgdisk -d "$LAST_N" "$TARGET" >/dev/null
        sgdisk -n "${LAST_N}:${start}:0" "$TARGET" >/dev/null
        [[ -n "$gtype" ]] && sgdisk -t "${LAST_N}:${gtype}" "$TARGET" >/dev/null
        [[ -n "$guid"  ]] && sgdisk -u "${LAST_N}:${guid}"  "$TARGET" >/dev/null
        partprobe "$TARGET"; udevadm settle 2>/dev/null || true
        gdev="$(part_dev "$TARGET" "$LAST_N")"
        case "$LAST_FS" in
          btrfs)
            mp="$(mktemp -d)"; mount "$gdev" "$mp"
            btrfs filesystem resize max "$mp"; umount "$mp"; rmdir "$mp" ;;
          ext2|ext3|ext4)
            e2fsck -f -y "$gdev" >/dev/null || true
            resize2fs "$gdev" ;;
        esac
        ok "Filesystem on $gdev grown to fill the disk."
      else
        warn "Could not parse layout for partition $LAST_N — skipping grow."
      fi
    fi
  fi
fi

# --------------------------------------------------------------------------- #
# 8. OPTIONAL: re-register the bootloader. Not needed to boot the SAME machine
#    (the restored ESP already carries \EFI\BOOT\BOOTX64.EFI and UUIDs match),
#    but on a NEW machine the firmware has no NVRAM entry. Best-effort, prompted,
#    and clearly the newest/least-proven path. Limine/GRUB/systemd-boot.
# --------------------------------------------------------------------------- #
echo
do_boot=0
case "$BOOT_MODE" in
  yes) do_boot=1; msg "Re-registering the bootloader in a chroot (--bootloader)." ;;
  no)  msg "--no-bootloader given; skipping bootloader re-registration." ;;
  *)   confirm "Re-register the bootloader in a chroot? (skip if restoring to the same machine)" "n" && do_boot=1 ;;
esac
if (( do_boot )); then
  warn "Bootloader re-registration is the least-tested step — see notes if it fails."
  [[ "$BOOTLOADER_DRYRUN" == "1" ]] && \
    msg "BOOTLOADER_DRYRUN=1 — will mount + detect, then PRINT the chroot command, not run it."
  # Find the root partition: first manifest entry whose fstype is a root-y fs.
  ROOT_N=""; ROOT_FS=""
  while IFS=$'\t' read -r partn _ fstype engine image uuid _ _; do
    [[ "$partn" == "partn" ]] && continue
    case "$fstype" in btrfs|ext4|xfs|f2fs) ROOT_N="$partn"; ROOT_FS="$fstype"; break ;; esac
  done < "$MANIFEST"
  if [[ -z "$ROOT_N" ]]; then
    warn "Could not identify a root partition; skipping bootloader step."
  else
    rdev="$(part_dev "$TARGET" "$ROOT_N")"
    root_mp="$(mktemp -d)"
    if [[ "$ROOT_FS" == "btrfs" ]]; then
      # CachyOS-style layout: root subvol is @. Fall back to bare mount if absent.
      mount -o "subvol=@" "$rdev" "$root_mp" 2>/dev/null || mount "$rdev" "$root_mp"
    else
      mount "$rdev" "$root_mp"
    fi
    # Mount the ESP where the restored fstab expects it (read it from fstab).
    esp_mp="$(awk '$2=="/boot"||$2=="/boot/efi"{print $2; exit}' "$root_mp/etc/fstab" 2>/dev/null)"
    esp_mp="${esp_mp:-/boot}"
    # The ESP is whichever restored partition is vfat.
    esp_n=""
    while IFS=$'\t' read -r partn _ fstype engine image uuid _ _; do
      [[ "$fstype" == "vfat" ]] && { esp_n="$partn"; break; }
    done < "$MANIFEST"
    [[ -n "$esp_n" ]] && mount "$(part_dev "$TARGET" "$esp_n")" "$root_mp$esp_mp"
    for b in proc sys dev; do mount --bind "/$b" "$root_mp/$b"; done

    if   [[ -f "$root_mp/etc/default/limine" ]]; then
      msg "Detected Limine — running limine-install in chroot"
      run_bl chroot "$root_mp" limine-install || warn "limine-install failed."
    elif [[ -d "$root_mp/boot/grub" ]]; then
      msg "Detected GRUB — running grub-install + grub-mkconfig in chroot"
      run_bl chroot "$root_mp" grub-install --target=x86_64-efi --efi-directory="$esp_mp" --bootloader-id=GRUB || warn "grub-install failed."
      run_bl chroot "$root_mp" grub-mkconfig -o /boot/grub/grub.cfg || warn "grub-mkconfig failed."
    elif [[ -d "$root_mp/boot/loader" || -d "$root_mp$esp_mp/loader" ]]; then
      msg "Detected systemd-boot — running bootctl install in chroot"
      run_bl chroot "$root_mp" bootctl install || warn "bootctl install failed."
    else
      warn "Could not detect the bootloader; the EFI fallback should still boot."
    fi

    for b in proc sys dev; do umount "$root_mp/$b" 2>/dev/null || true; done
    [[ -n "$esp_n" ]] && umount "$root_mp$esp_mp" 2>/dev/null || true
    umount "$root_mp" 2>/dev/null || true
    rmdir "$root_mp" 2>/dev/null || true
  fi
fi

# --------------------------------------------------------------------------- #
# 9. Done.
# --------------------------------------------------------------------------- #
echo
ok "Restore complete — $TARGET now holds the backed-up system."
msg "UUIDs were preserved, so fstab and the bootloader cmdline already match."
if (( NO_REBOOT )); then
  msg "--no-reboot given; leaving the machine running."
elif confirm "Reboot now?" "n"; then
  systemctl reboot
elif confirm "Power off now?" "n"; then
  systemctl poweroff
fi
