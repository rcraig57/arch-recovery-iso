#!/usr/bin/env bash
#
# build-recovery-iso.sh — Build a bootable, installable recovery ISO that is a
# clone of THIS running Arch-based system (Arch / CachyOS / Kiro).
#
# Architecture (Option B, "clone as payload"):
#   1. rsync the live root filesystem into a work directory (honoring an
#      editable exclude list that strips secrets and volatile data).
#   2. Pack that clone into a single SquashFS file: clone.sfs (zstd -19).
#   3. Drop clone.sfs + a restore script + a metadata file into a stock archiso
#      "releng" profile, then run mkarchiso.
#
# The resulting ISO boots a NORMAL Arch live environment (its own stock kernel,
# so it always boots and needs no AUR). The clone is inert payload. To restore,
# the user boots the ISO and runs /root/restore-system.sh, which wipes a chosen
# disk, unpacks clone.sfs onto it, regenerates fstab/initramfs, and reinstalls
# the matching bootloader — bringing the system back "as if nothing happened".
#
# Conceptually this is the Arch-world answer to MX Linux's MX Snapshot.
#
# Run as root on the system you want to clone:  sudo ./build-recovery-iso.sh
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

# msg  = normal progress line; warn = caution; err = fatal (then exit).
msg()  { printf '%s==>%s %s\n'  "$C_BLUE$C_BOLD" "$C_RESET" "$*"; }
ok()   { printf '%s==>%s %s\n'  "$C_GREEN$C_BOLD" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n'  "$C_YELLOW$C_BOLD" "$C_RESET" "$*" >&2; }
err()  { printf '%s[x]%s %s\n'  "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Ask a yes/no question; default is shown in capitals. Returns 0 for yes.
confirm() {
  # $1 = prompt, $2 = default ("y" or "n")
  local prompt="$1" default="${2:-n}" reply hint
  if [[ "$default" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  read -r -p "$prompt $hint " reply || true
  reply="${reply:-$default}"
  [[ "$reply" =~ ^([yY]|[yY][eE][sS])$ ]]
}

# --------------------------------------------------------------------------- #
# Locations. SCRIPT_DIR is where this script (and the exclude list) live.
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXCLUDE_LIST="$SCRIPT_DIR/recovery-exclude.list"

# These get filled in by the interactive questions later.
WORK_DIR=""        # scratch area for the build (needs lots of space)
OUT_DIR=""         # where the finished .iso is written
ISO_BASENAME=""    # e.g. kiro-vbox-recovery-20260612

# --------------------------------------------------------------------------- #
# 0. Must be root. mkarchiso and reading the whole root fs both need it.
# --------------------------------------------------------------------------- #
[[ "$(id -u)" -eq 0 ]] || die "Run as root (e.g. sudo $0)."

# --------------------------------------------------------------------------- #
# 1. Dependency preflight. Confirm the four packages that provide the tools we
#    call, and offer to install any that are missing (pacman is always present
#    on the target distros).
# --------------------------------------------------------------------------- #
# Map: package name -> a command it provides (used only for the message).
declare -A DEP_PKGS=(
  [archiso]="mkarchiso"
  [arch-install-scripts]="genfstab"
  [rsync]="rsync"
  [squashfs-tools]="mksquashfs"
)

preflight_deps() {
  msg "Checking build dependencies..."
  local missing=()
  local pkg
  for pkg in "${!DEP_PKGS[@]}"; do
    # pacman -Q is the authoritative "is this package installed?" check.
    if ! pacman -Q "$pkg" &>/dev/null; then
      missing+=("$pkg")
      warn "Missing: $pkg (provides ${DEP_PKGS[$pkg]})"
    fi
  done

  if ((${#missing[@]})); then
    if confirm "Install the missing package(s) now with pacman?" "y"; then
      pacman -S --needed --noconfirm "${missing[@]}"
    else
      die "Cannot continue without: ${missing[*]}"
    fi
  fi
  ok "All build dependencies present."
}

# --------------------------------------------------------------------------- #
# 2. Detect this system's boot setup so the restore script can reproduce it.
#    We record the results into recovery-metadata.conf inside the ISO.
# --------------------------------------------------------------------------- #
SRC_FIRMWARE=""     # uefi | bios
SRC_BOOTLOADER=""   # systemd-boot | grub
SRC_ROOT_FSTYPE=""  # ext4 | btrfs | xfs ...
SRC_HOSTNAME=""

detect_system() {
  msg "Detecting boot configuration of this system..."

  # Firmware: the presence of the EFI runtime directory is the standard test.
  if [[ -d /sys/firmware/efi ]]; then
    SRC_FIRMWARE="uefi"
  else
    SRC_FIRMWARE="bios"
  fi

  # Bootloader: systemd-boot leaves an EFI/systemd dir on the ESP; otherwise we
  # look for a GRUB install. bootctl is the reliable systemd-boot probe.
  if [[ "$SRC_FIRMWARE" == "uefi" ]] && bootctl is-installed &>/dev/null; then
    SRC_BOOTLOADER="systemd-boot"
  elif [[ -d /boot/grub ]] || command -v grub-install &>/dev/null; then
    SRC_BOOTLOADER="grub"
  else
    # Default to grub; the user can correct the metadata file before building.
    SRC_BOOTLOADER="grub"
    warn "Could not auto-detect the bootloader; assuming GRUB."
  fi

  # Filesystem type of the running root — restore formats the target to match.
  SRC_ROOT_FSTYPE="$(findmnt -no FSTYPE /)"

  SRC_HOSTNAME="$(hostnamectl --static 2>/dev/null || hostname)"
  [[ -n "$SRC_HOSTNAME" ]] || SRC_HOSTNAME="archrecovery"

  ok "Firmware=$SRC_FIRMWARE  Bootloader=$SRC_BOOTLOADER  Root=$SRC_ROOT_FSTYPE  Host=$SRC_HOSTNAME"
}

# --------------------------------------------------------------------------- #
# 3. The exclude list. If it does not exist next to this script, write a sane
#    default that strips secrets, caches, and volatile/pseudo filesystems.
#    Then show it and let the user edit before the clone runs. This is the #1
#    safety control: it stops private keys and saved logins being baked into a
#    shareable ISO.
# --------------------------------------------------------------------------- #
write_default_exclude_list() {
  cat >"$EXCLUDE_LIST" <<'EOF'
# recovery-exclude.list — rsync exclude patterns for the system clone.
#
# Format: one pattern per line; lines starting with '#' are comments.
# Patterns are anchored at the root of the clone (leading '/').
# A trailing '/*' excludes a directory's CONTENTS but keeps the empty
# directory itself (important for mountpoints like /proc and /dev).
# A single '*' matches one path component, so '/home/*/.cache' matches every
# user's cache directory.
#
# Edit freely: remove a line to INCLUDE that data, add a line to EXCLUDE more.

# --- Pseudo / virtual / volatile filesystems (must never be cloned) --------
/dev/*
/proc/*
/sys/*
/run/*
/tmp/*
/var/tmp/*
/mnt/*
/media/*
/lost+found

# --- The EFI System Partition (regenerated fresh on restore) ---------------
/boot/efi/*

# --- Regenerable package / log data (saves space, rebuilt automatically) ---
/var/cache/pacman/pkg/*
/var/lib/pacman/sync/*
/var/log/journal/*

# --- Swap files ------------------------------------------------------------
/swapfile
/swap/*

# --- Per-user caches and trash ---------------------------------------------
/home/*/.cache/*
/root/.cache/*
/home/*/.local/share/Trash/*

# ===========================================================================
# SECRETS — default-excluded. Removing any of these will bake that secret into
# the ISO. Only do so for a recovery image you will keep PRIVATE.
# ===========================================================================

# --- SSH and GPG private keys ----------------------------------------------
/home/*/.ssh/id_*
/home/*/.ssh/*_vm
/home/*/.ssh/*.pem
/root/.ssh/id_*
/home/*/.gnupg/*
/root/.gnupg/*

# --- Password stores, wallets, keyrings ------------------------------------
/home/*/.password-store/*
/home/*/.local/share/keyrings/*
/home/*/.gnome2/keyrings/*
/home/*/.local/share/kwalletd/*

# --- Cloud / API / container credentials -----------------------------------
/home/*/.aws/*
/home/*/.config/gcloud/*
/home/*/.azure/*
/home/*/.kube/*
/home/*/.docker/config.json
/home/*/.config/rclone/*
/home/*/.netrc

# --- Browser saved logins, cookies, sessions (keeps bookmarks/extensions) --
/home/*/.mozilla/firefox/*/key4.db
/home/*/.mozilla/firefox/*/logins.json
/home/*/.mozilla/firefox/*/cookies.sqlite
/home/*/.config/*/Default/Login Data
/home/*/.config/*/Default/Cookies
/home/*/.config/*/Default/Web Data

# --- Shell history ---------------------------------------------------------
/home/*/.bash_history
/home/*/.zsh_history
/home/*/.local/share/fish/fish_history
/root/.bash_history
EOF
}

prepare_exclude_list() {
  if [[ ! -f "$EXCLUDE_LIST" ]]; then
    msg "No exclude list found; writing default to: $EXCLUDE_LIST"
    write_default_exclude_list
  else
    msg "Using existing exclude list: $EXCLUDE_LIST"
  fi

  printf '\n%s----- exclusion list (what will be LEFT OUT of the clone) -----%s\n' \
    "$C_BOLD" "$C_RESET"
  grep -vE '^\s*#|^\s*$' "$EXCLUDE_LIST" | sed 's/^/  /'
  printf '%s--------------------------------------------------------------%s\n\n' \
    "$C_BOLD" "$C_RESET"

  warn "Review the list above. Anything NOT listed will be copied into the ISO."
  if confirm "Open the exclude list in an editor before building?" "n"; then
    "${EDITOR:-nano}" "$EXCLUDE_LIST"
  fi
  confirm "Proceed with these exclusions?" "y" || die "Aborted by user."
}

# --------------------------------------------------------------------------- #
# 4. Interactive questions: where to build, where to output, ISO name.
# --------------------------------------------------------------------------- #
ask_config() {
  local default_work default_out default_name reply
  default_work="/var/tmp/recovery-build"
  default_out="$SCRIPT_DIR/out"
  default_name="${SRC_HOSTNAME}-recovery-$(date +%Y%m%d)"

  read -r -p "Work directory (needs lots of free space) [$default_work]: " reply
  WORK_DIR="${reply:-$default_work}"

  read -r -p "Output directory for the .iso [$default_out]: " reply
  OUT_DIR="${reply:-$default_out}"

  read -r -p "ISO base name [$default_name]: " reply
  ISO_BASENAME="${reply:-$default_name}"

  mkdir -p "$WORK_DIR" "$OUT_DIR"
}

# --------------------------------------------------------------------------- #
# 5. Free-space preflight. The build holds the clone twice (the rsync copy plus
#    the SquashFS and the assembled ISO), so apply the brief's 2-3x rule
#    against the estimated clone size.
# --------------------------------------------------------------------------- #
check_free_space() {
  msg "Estimating clone size and checking free space..."

  # Estimate the clone size with a dry-run rsync (counts only included files).
  # --stats prints "Total file size: N bytes"; N may carry thousands separators
  # (commas), so grab the first number on that line and strip the commas.
  local est_bytes
  est_bytes="$(rsync -aHAXn --stats --exclude-from="$EXCLUDE_LIST" / "$WORK_DIR/clone-rootfs-probe/" 2>/dev/null \
    | grep -m1 'Total file size' | grep -oE '[0-9,]+' | head -1 | tr -d ',')"
  est_bytes="${est_bytes:-0}"

  local est_gib=$(( est_bytes / 1024 / 1024 / 1024 ))
  # Require ~2.5x the estimated clone (rounded up) in the work fs.
  local need_gib=$(( est_gib * 5 / 2 + 1 ))

  local avail_kib avail_gib
  avail_kib="$(df --output=avail -k "$WORK_DIR" | tail -1 | tr -d ' ')"
  avail_gib=$(( avail_kib / 1024 / 1024 ))

  msg "Estimated clone: ~${est_gib} GiB | recommended free: ~${need_gib} GiB | available in work dir: ${avail_gib} GiB"

  if (( avail_gib < need_gib )); then
    warn "Work directory may not have enough free space (${avail_gib} < ${need_gib} GiB)."
    confirm "Continue anyway?" "n" || die "Aborted: choose a work dir with more space."
  fi
}

# --------------------------------------------------------------------------- #
# 6. Clone the live root filesystem into the work area.
#    -a archive, -H hardlinks, -A ACLs, -X xattrs, --numeric-ids preserve IDs.
#    We do NOT use -x (one-file-system) because a user may keep /home or /boot
#    on a separate partition and we want those included; mounts we must skip are
#    handled explicitly by the exclude list instead.
# --------------------------------------------------------------------------- #
CLONE_ROOT=""   # set in clone_system()

clone_system() {
  CLONE_ROOT="$WORK_DIR/clone-rootfs"
  msg "Cloning live root filesystem into: $CLONE_ROOT"
  mkdir -p "$CLONE_ROOT"

  # Build a runtime exclude file = the user's list PLUS dynamic paths that would
  # otherwise cause the build to copy its own output into the clone.
  local runtime_excludes="$WORK_DIR/rsync-excludes.runtime"
  cp -- "$EXCLUDE_LIST" "$runtime_excludes"
  {
    printf '%s\n' "# --- auto-added by build-recovery-iso.sh ---"
    printf '%s/*\n' "$WORK_DIR"
    printf '%s/*\n' "$OUT_DIR"
  } >>"$runtime_excludes"

  rsync -aHAX --numeric-ids --info=progress2 \
    --exclude-from="$runtime_excludes" \
    / "$CLONE_ROOT/"

  ok "Clone complete."
}

# --------------------------------------------------------------------------- #
# 7. Pack the clone into clone.sfs (zstd -19) and write the restore script and
#    metadata into a copy of the stock releng archiso profile.
# --------------------------------------------------------------------------- #
PROFILE_DIR=""  # set in build_profile()

build_profile() {
  PROFILE_DIR="$WORK_DIR/profile"
  msg "Preparing archiso profile from releng..."
  rm -rf "$PROFILE_DIR"
  cp -a /usr/share/archiso/configs/releng "$PROFILE_DIR"

  # The outer (releng) SquashFS only needs to wrap a minimal live system plus
  # our already-compressed clone.sfs, so use FAST zstd for it — recompressing
  # clone.sfs would gain nothing and cost build time.
  sed -i \
    "s|^airootfs_image_tool_options=.*|airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '1' '-b' '1M')|" \
    "$PROFILE_DIR/profiledef.sh"

  # Brand the ISO.
  sed -i "s|^iso_name=.*|iso_name=\"${ISO_BASENAME}\"|" "$PROFILE_DIR/profiledef.sh"
  sed -i "s|^iso_publisher=.*|iso_publisher=\"archiso personal recovery\"|" "$PROFILE_DIR/profiledef.sh"
  sed -i "s|^iso_application=.*|iso_application=\"Personal recovery clone of ${SRC_HOSTNAME}\"|" "$PROFILE_DIR/profiledef.sh"

  # Make the restore script executable in the built ISO.
  sed -i "/^file_permissions=(/a\\  [\"/root/restore-system.sh\"]=\"0:0:755\"" \
    "$PROFILE_DIR/profiledef.sh"

  # --- Build clone.sfs ---------------------------------------------------- #
  local payload="$PROFILE_DIR/airootfs/root/clone.sfs"
  msg "Packing clone into SquashFS (zstd -19) — this is the slow step..."
  mksquashfs "$CLONE_ROOT" "$payload" \
    -comp zstd -Xcompression-level 19 -b 1M -noappend

  local clone_sha
  clone_sha="$(sha256sum "$payload" | awk '{print $1}')"
  ok "clone.sfs built (sha256 $clone_sha)."

  # --- Metadata the restore script reads ---------------------------------- #
  cat >"$PROFILE_DIR/airootfs/root/recovery-metadata.conf" <<EOF
# Generated by build-recovery-iso.sh on $(date -Iseconds)
SRC_HOSTNAME="$SRC_HOSTNAME"
SRC_FIRMWARE="$SRC_FIRMWARE"
SRC_BOOTLOADER="$SRC_BOOTLOADER"
SRC_ROOT_FSTYPE="$SRC_ROOT_FSTYPE"
CLONE_SHA256="$clone_sha"
EOF

  # --- The restore script (static; reads the metadata above) -------------- #
  write_restore_script "$PROFILE_DIR/airootfs/root/restore-system.sh"

  # A short pointer for whoever boots the ISO.
  cat >"$PROFILE_DIR/airootfs/root/README-RESTORE.txt" <<EOF
This live ISO is a personal recovery clone of "$SRC_HOSTNAME".

To restore the system onto a disk, run:

    /root/restore-system.sh

WARNING: restoring ERASES the target disk you select.
EOF
}

# --------------------------------------------------------------------------- #
# write_restore_script — emits the bundled text-menu restore tool. Written with
# a quoted heredoc so nothing here is expanded at build time; the script reads
# its real values from recovery-metadata.conf at restore time.
# --------------------------------------------------------------------------- #
write_restore_script() {
  local dest="$1"
  cat >"$dest" <<'RESTORE_EOF'
#!/usr/bin/env bash
#
# restore-system.sh — Restore this recovery clone onto a disk.
# Runs inside the live ISO as root. ERASES the target disk you choose.
#
set -euo pipefail

C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
C_BLUE=$'\e[34m'; C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
msg()  { printf '%s==>%s %s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$*"; }
ok()   { printf '%s==>%s %s\n' "$C_GREEN$C_BOLD" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW$C_BOLD" "$C_RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Run as root."

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$HERE/clone.sfs"
META="$HERE/recovery-metadata.conf"
[[ -f "$PAYLOAD" ]] || die "clone.sfs not found next to this script."
[[ -f "$META" ]]    || die "recovery-metadata.conf not found."
# shellcheck source=/dev/null
source "$META"

cat <<BANNER

${C_BOLD}=== Personal recovery restore — clone of ${SRC_HOSTNAME} ===${C_RESET}
  Firmware (source): ${SRC_FIRMWARE}
  Bootloader:        ${SRC_BOOTLOADER}
  Root filesystem:   ${SRC_ROOT_FSTYPE}

BANNER

# --- 1. Verify the payload checksum before touching any disk --------------- #
msg "Verifying clone.sfs integrity..."
actual_sha="$(sha256sum "$PAYLOAD" | awk '{print $1}')"
[[ "$actual_sha" == "$CLONE_SHA256" ]] \
  || die "Checksum mismatch! Expected $CLONE_SHA256, got $actual_sha. Media may be corrupt."
ok "Checksum OK."

# --- 2. Pick the target disk ----------------------------------------------- #
echo
msg "Available disks:"
lsblk -dpno NAME,SIZE,MODEL | grep -vE 'loop|sr[0-9]' | sed 's/^/  /'
echo
read -r -p "Enter the FULL target disk path to ERASE (e.g. /dev/sda): " TARGET
[[ -b "$TARGET" ]] || die "$TARGET is not a block device."

# Refuse to overwrite the device the live ISO itself is running from.
live_src="$(findmnt -no SOURCE / || true)"
if [[ "$live_src" == "$TARGET"* ]]; then
  die "$TARGET appears to be the live medium. Choose a different disk."
fi

echo
warn "EVERYTHING on $TARGET will be PERMANENTLY ERASED:"
lsblk -po NAME,SIZE,FSTYPE,MOUNTPOINTS "$TARGET" | sed 's/^/  /'
echo
read -r -p "Type ERASE in capitals to confirm: " CONFIRM
[[ "$CONFIRM" == "ERASE" ]] || die "Not confirmed; nothing was changed."

# --- 3. Partition and format ----------------------------------------------- #
# Determine target firmware (usually matches the source machine on recovery).
if [[ -d /sys/firmware/efi ]]; then TGT_FIRMWARE="uefi"; else TGT_FIRMWARE="bios"; fi
msg "Target firmware detected as: $TGT_FIRMWARE"

msg "Wiping old partition signatures on $TARGET..."
wipefs -a "$TARGET"
sgdisk --zap-all "$TARGET"

ESP_PART=""; ROOT_PART=""
partdev() {
  # Handle nvme/mmc naming (need a 'p' before the number) vs sd* naming.
  local disk="$1" num="$2"
  if [[ "$disk" =~ [0-9]$ ]]; then printf '%sp%s' "$disk" "$num"; else printf '%s%s' "$disk" "$num"; fi
}

if [[ "$TGT_FIRMWARE" == "uefi" ]]; then
  # GPT: 1 GiB EFI System Partition + rest as root.
  sgdisk -n1:0:+1GiB -t1:ef00 -c1:EFI "$TARGET"
  sgdisk -n2:0:0     -t2:8300 -c2:root "$TARGET"
  ESP_PART="$(partdev "$TARGET" 1)"
  ROOT_PART="$(partdev "$TARGET" 2)"
else
  # GPT for BIOS/GRUB: tiny BIOS boot partition + root.
  sgdisk -n1:0:+1MiB -t1:ef02 -c1:bios "$TARGET"
  sgdisk -n2:0:0     -t2:8300 -c2:root "$TARGET"
  ROOT_PART="$(partdev "$TARGET" 2)"
fi
partprobe "$TARGET"; sleep 1

msg "Formatting root ($ROOT_PART) as $SRC_ROOT_FSTYPE..."
case "$SRC_ROOT_FSTYPE" in
  ext4)  mkfs.ext4 -F "$ROOT_PART" ;;
  btrfs) mkfs.btrfs -f "$ROOT_PART" ;;
  xfs)   mkfs.xfs -f "$ROOT_PART" ;;
  *) die "Unsupported root filesystem '$SRC_ROOT_FSTYPE' (extend the script)." ;;
esac

mount "$ROOT_PART" /mnt
if [[ "$TGT_FIRMWARE" == "uefi" ]]; then
  msg "Formatting ESP ($ESP_PART) as FAT32..."
  mkfs.fat -F32 "$ESP_PART"
  mkdir -p /mnt/boot/efi
  mount "$ESP_PART" /mnt/boot/efi
fi

# --- 4. Unpack the clone --------------------------------------------------- #
msg "Unpacking clone.sfs onto $ROOT_PART (this takes a while)..."
unsquashfs -f -d /mnt "$PAYLOAD"
ok "Clone unpacked."

# --- 5. Regenerate fstab with the NEW partition UUIDs ---------------------- #
msg "Generating /etc/fstab from the new disk..."
genfstab -U /mnt >/mnt/etc/fstab

# The new root partition's UUID. The clone still carries the OLD disk's
# root=UUID= in /etc/kernel/cmdline; we must rewrite it to this value or the
# restored systemd-boot system will fail to find its root and not boot.
NEW_ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
msg "New root UUID is $NEW_ROOT_UUID"

# --- 6. Reinstall bootloader + rebuild initramfs inside the clone ---------- #
msg "Rebuilding initramfs and reinstalling bootloader in chroot..."
arch-chroot /mnt /bin/bash -euo pipefail <<CHROOT
# Rebuild every initramfs from the cloned config.
mkinitcpio -P

if [[ "$TGT_FIRMWARE" == "uefi" && "$SRC_BOOTLOADER" == "systemd-boot" ]]; then
  # Install systemd-boot to the ESP and re-create EFI boot entry.
  bootctl install

  # Fix the kernel command line so the BootLoaderSpec entries that
  # kernel-install is about to write point at the NEW root UUID, not the
  # cloned-in old one. Preserve any other options (quiet, splash, ...).
  if [[ -f /etc/kernel/cmdline ]]; then
    sed -i -E "s|root=UUID=[^[:space:]]+|root=UUID=$NEW_ROOT_UUID|" /etc/kernel/cmdline
    grep -q "root=UUID=$NEW_ROOT_UUID" /etc/kernel/cmdline \
      || printf ' root=UUID=%s' "$NEW_ROOT_UUID" >>/etc/kernel/cmdline
  else
    printf 'quiet rw root=UUID=%s\n' "$NEW_ROOT_UUID" >/etc/kernel/cmdline
  fi
  # Re-populate the ESP Boot-Loader-Spec entries for every installed kernel.
  # Arch kernel packages place the kernel image at /usr/lib/modules/\$kver/vmlinuz,
  # which is exactly what kernel-install expects.
  for kver in /usr/lib/modules/*/; do
    kver="\$(basename "\$kver")"
    if [[ -f "/usr/lib/modules/\$kver/vmlinuz" ]]; then
      kernel-install add "\$kver" "/usr/lib/modules/\$kver/vmlinuz"
    fi
  done
elif [[ "$TGT_FIRMWARE" == "uefi" && "$SRC_BOOTLOADER" == "grub" ]]; then
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
  grub-mkconfig -o /boot/grub/grub.cfg
else
  # BIOS / GRUB.
  grub-install --target=i386-pc "$TARGET"
  grub-mkconfig -o /boot/grub/grub.cfg
fi
CHROOT

# --- 7. Clean up ----------------------------------------------------------- #
sync
umount -R /mnt
ok "Restore complete. Remove the ISO media and reboot."
RESTORE_EOF
}

# --------------------------------------------------------------------------- #
# 8. Run mkarchiso to assemble the final ISO, then checksum it.
# --------------------------------------------------------------------------- #
build_iso() {
  msg "Running mkarchiso (this is long and very disk-heavy)..."
  # -w work dir, -o output dir. mkarchiso wants its own clean work subdir.
  local archiso_work="$WORK_DIR/archiso-work"
  rm -rf "$archiso_work"
  mkarchiso -v -w "$archiso_work" -o "$OUT_DIR" "$PROFILE_DIR"

  # mkarchiso names the file from iso_name + version; find the newest .iso.
  local iso
  iso="$(find "$OUT_DIR" -maxdepth 1 -name '*.iso' -printf '%T@ %p\n' \
    | sort -nr | head -1 | cut -d' ' -f2-)"
  [[ -n "$iso" ]] || die "mkarchiso finished but no .iso was found in $OUT_DIR."

  msg "Writing checksum..."
  ( cd "$OUT_DIR" && sha256sum "$(basename "$iso")" >"$(basename "$iso").sha256" )

  ok "ISO ready: $iso"
  ok "Checksum:  ${iso}.sha256"
  printf '\n%sBoot it, log in as root, and run /root/restore-system.sh to restore.%s\n' \
    "$C_BOLD" "$C_RESET"
}

# --------------------------------------------------------------------------- #
# Main flow.
# --------------------------------------------------------------------------- #
main() {
  preflight_deps
  detect_system
  prepare_exclude_list
  ask_config
  check_free_space
  clone_system
  build_profile
  build_iso
}

main "$@"
