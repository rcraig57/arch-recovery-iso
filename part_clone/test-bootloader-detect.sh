#!/usr/bin/env bash
#
# test-bootloader-detect.sh — dry-run ONLY the bootloader-detection logic of
# partclone-restore.sh §8 against an ALREADY-restored disk, without erasing or
# rewriting anything. It mounts the target's root (and ESP) READ-ONLY, reports
# which bootloader signals are present, then prints the chroot command that
# restore's §8 would run. Strictly read-only — it never writes to the disk and
# never actually chroots.
#
# Use this to confirm §8 picks the right bootloader + command on your real
# system (e.g. CachyOS/Limine) after you've already done a normal restore,
# so you don't have to repeat the full restore just to test the last step.
#
# Usage:
#   sudo ./test-bootloader-detect.sh /dev/sdX     # the already-restored disk
#
set -euo pipefail

msg()  { printf '\e[34;1m==>\e[0m %s\n' "$*"; }
ok()   { printf '\e[32;1m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[33;1m[!]\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[31;1m[x]\e[0m %s\n' "$*" >&2; exit 1; }

# Same partition-naming rule as the restore script (nvme/mmc need a 'p').
part_dev() {
  local disk="$1" n="$2"
  if [[ "$disk" =~ [0-9]$ ]]; then echo "${disk}p${n}"; else echo "${disk}${n}"; fi
}

ROOT_MP=""; ESP_MOUNTED=""
cleanup() {
  [[ -n "$ESP_MOUNTED" ]] && umount "$ESP_MOUNTED" 2>/dev/null || true
  [[ -n "$ROOT_MP" ]] && { umount "$ROOT_MP" 2>/dev/null || true; rmdir "$ROOT_MP" 2>/dev/null || true; }
}
trap cleanup EXIT

[[ "$(id -u)" -eq 0 ]] || die "Run as root (e.g. sudo $0)."
TARGET="${1:-}"
[[ -b "$TARGET" ]] || die "Usage: sudo $0 /dev/sdX   (pass the already-restored disk)"

# Refuse a disk with a mounted partition (almost certainly the running system).
if lsblk -nro MOUNTPOINTS "$TARGET" | grep -q '[^[:space:]]'; then
  die "$TARGET has a mounted partition — pass the restored (idle) disk, not the live one."
fi

# --------------------------------------------------------------------------- #
# Identify root + ESP the same way restore §8 does, but from the disk's own
# current filesystems (post-restore they equal the manifest): root = first
# btrfs/ext4/xfs/f2fs partition; ESP = first vfat partition.
# --------------------------------------------------------------------------- #
ROOT_N=""; ROOT_FS=""; ESP_N=""
while read -r partn fstype ptype; do
  [[ "$ptype" == "part" ]] || continue
  case "$fstype" in
    btrfs|ext4|xfs|f2fs) [[ -z "$ROOT_N" ]] && { ROOT_N="$partn"; ROOT_FS="$fstype"; } ;;
    vfat)                [[ -z "$ESP_N"  ]] && ESP_N="$partn" ;;
  esac
done < <(lsblk -rno PARTN,FSTYPE,TYPE "$TARGET")

[[ -n "$ROOT_N" ]] || die "No root-like filesystem (btrfs/ext4/xfs/f2fs) found on $TARGET."
RDEV="$(part_dev "$TARGET" "$ROOT_N")"
msg "Target : $TARGET"
msg "Root   : partition $ROOT_N ($ROOT_FS) -> $RDEV"
[[ -n "$ESP_N" ]] && msg "ESP    : partition $ESP_N (vfat) -> $(part_dev "$TARGET" "$ESP_N")" \
                  || warn "No vfat ESP partition found."

# --------------------------------------------------------------------------- #
# Mount root READ-ONLY (btrfs: try the @ subvol like restore does), read the
# ESP mountpoint from the restored fstab, mount the ESP there read-only too.
# --------------------------------------------------------------------------- #
ROOT_MP="$(mktemp -d)"
if [[ "$ROOT_FS" == "btrfs" ]]; then
  mount -o ro,subvol=@ "$RDEV" "$ROOT_MP" 2>/dev/null || mount -o ro "$RDEV" "$ROOT_MP"
else
  mount -o ro "$RDEV" "$ROOT_MP"
fi

ESP_MP="$(awk '$2=="/boot"||$2=="/boot/efi"{print $2; exit}' "$ROOT_MP/etc/fstab" 2>/dev/null)"
ESP_MP="${ESP_MP:-/boot}"
msg "fstab ESP mountpoint: $ESP_MP"
if [[ -n "$ESP_N" ]]; then
  if mount -o ro "$(part_dev "$TARGET" "$ESP_N")" "$ROOT_MP$ESP_MP" 2>/dev/null; then
    ESP_MOUNTED="$ROOT_MP$ESP_MP"
  else
    warn "Could not mount ESP at $ROOT_MP$ESP_MP (continuing; detection may be partial)."
  fi
fi

# --------------------------------------------------------------------------- #
# Diagnostics: show the actual on-disk signals so we can fix §8 if it guesses
# wrong on this system. Each line shows whether the path exists.
# --------------------------------------------------------------------------- #
yn() { [[ -e "$1" ]] && echo "  [yes] $2" || echo "  [ no] $2"; }
echo
msg "Bootloader signals present on the restored system:"
yn "$ROOT_MP/etc/default/limine"        "/etc/default/limine        (restore's Limine trigger)"
yn "$ROOT_MP/boot/limine.conf"          "/boot/limine.conf"
yn "$ROOT_MP/boot/limine.cfg"           "/boot/limine.cfg"
yn "$ROOT_MP$ESP_MP/limine.conf"        "$ESP_MP/limine.conf"
yn "$ROOT_MP/boot/grub"                 "/boot/grub                 (restore's GRUB trigger)"
yn "$ROOT_MP/boot/loader"               "/boot/loader               (systemd-boot trigger A)"
yn "$ROOT_MP$ESP_MP/loader"             "$ESP_MP/loader             (systemd-boot trigger B)"
echo "  --- EFI binaries on the ESP ---"
if [[ -n "$ESP_MOUNTED" ]]; then
  find "$ROOT_MP$ESP_MP/EFI" -maxdepth 2 -iname '*.efi' 2>/dev/null \
    | sed "s|$ROOT_MP$ESP_MP|  $ESP_MP|" || true
fi
echo "  --- 'limine' commands on PATH inside the restored root ---"
for c in limine limine-install limine-update limine-deploy; do
  [[ -x "$ROOT_MP/usr/bin/$c" || -x "$ROOT_MP/usr/sbin/$c" ]] && echo "  [yes] $c" || echo "  [ no] $c"
done

# --------------------------------------------------------------------------- #
# Run restore §8's exact detection cascade and PRINT the command it would run.
# --------------------------------------------------------------------------- #
echo
msg "What partclone-restore.sh §8 would do (dry-run — nothing executed):"
if   [[ -f "$ROOT_MP/etc/default/limine" ]]; then
  echo "  Detected: Limine"
  echo "  [dry-run] would run: chroot $ROOT_MP limine-install"
elif [[ -d "$ROOT_MP/boot/grub" ]]; then
  echo "  Detected: GRUB"
  echo "  [dry-run] would run: chroot $ROOT_MP grub-install --target=x86_64-efi --efi-directory=$ESP_MP --bootloader-id=GRUB"
  echo "  [dry-run] would run: chroot $ROOT_MP grub-mkconfig -o /boot/grub/grub.cfg"
elif [[ -d "$ROOT_MP/boot/loader" || -d "$ROOT_MP$ESP_MP/loader" ]]; then
  echo "  Detected: systemd-boot"
  echo "  [dry-run] would run: chroot $ROOT_MP bootctl install"
else
  warn "  Detected: NONE — §8 would fall through to 'EFI fallback should still boot'."
fi

echo
ok "Done — read-only probe; the disk was not modified."
