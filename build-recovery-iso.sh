#!/usr/bin/env bash
#
# build-recovery-iso.sh — Build a bootable, installable recovery ISO that is a
# clone of THIS running Arch-based system (Arch / CachyOS / Kiro).
#
# Architecture:
#   1. rsync the live root filesystem into a work directory (honoring an
#      editable exclude list that strips secrets and volatile data).
#   2. Pack that clone into a single SquashFS file: clone.sfs (zstd, level set
#      by CLONE_ZSTD_LEVEL — defaults to 3 for a fast build).
#   3. Drop clone.sfs + a restore script + a metadata file into a stock archiso
#      "releng" profile, then run mkarchiso.
#
# The resulting ISO boots a NORMAL Arch live environment (its own stock kernel,
# so it always boots and needs no AUR). The clone is inert payload. On boot the
# restore tool (/root/restore-system.sh) starts automatically on the console
# after a short, cancelable countdown; it wipes a chosen disk, unpacks clone.sfs
# onto it, regenerates fstab/initramfs, and reinstalls the matching bootloader —
# bringing the system back "as if nothing happened".
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

# The list actually fed to rsync. Normally the file above, but for a private
# "personal use" ISO the user can opt to bake their secrets in, in which case
# this points at a filtered temp copy with the SECRETS section stripped.
EFFECTIVE_EXCLUDE_LIST="$EXCLUDE_LIST"

# Temp files to remove on exit (e.g. the filtered exclude list above).
TMP_FILES=()

# Build log + timing. BUILD_LOG is a tee of the whole run; on success it is
# copied next to the finished ISO. BUILD_OK flips to 1 only when the ISO is done,
# so a failed run leaves the temp log behind and tells the user where it is.
START_EPOCH="$(date +%s)"
BUILD_LOG=""
BUILD_OK=""

cleanup() {
  local f
  for f in "${TMP_FILES[@]:-}"; do
    [[ -n "$f" ]] && rm -f "$f"
  done
  # If we bailed out before the ISO finished, point at the log for debugging.
  if [[ -z "$BUILD_OK" && -n "$BUILD_LOG" && -f "$BUILD_LOG" ]]; then
    printf '\nThe build did not complete. Full log: %s\n' "$BUILD_LOG" >&2
  fi
}
trap cleanup EXIT

# These get filled in by the interactive questions later.
WORK_DIR=""        # scratch area for the build (needs lots of space)
OUT_DIR=""         # where the finished .iso is written
ISO_BASENAME=""    # e.g. kiro-vbox-recovery-20260612

# zstd compression level for the clone.sfs payload (the slowest build step).
# This is a SPEED-vs-SIZE knob, not a correctness one: lower = much faster build
# + bigger ISO, higher = slower build + smaller ISO. Override from the shell,
# e.g.  CLONE_ZSTD_LEVEL=1 sudo ./build-recovery-iso.sh
#   1  fastest, biggest    3  zstd's own default (fast, good ratio)  <-- our default
#   19 v1's old setting (much slower, ~10-20% smaller)  22 max/ultra (slowest)
CLONE_ZSTD_LEVEL="${CLONE_ZSTD_LEVEL:-3}"

# --------------------------------------------------------------------------- #
# 0. Must be root. mkarchiso and reading the whole root fs both need it.
# --------------------------------------------------------------------------- #
[[ "$(id -u)" -eq 0 ]] || die "Run as root (e.g. sudo $0)."

# Tee everything from here on to a log file (colors already decided above, so
# they are preserved on screen even though stdout is now a pipe).
BUILD_LOG="$(mktemp -t recovery-build-XXXXXX.log)"
exec > >(tee -a "$BUILD_LOG") 2>&1

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
SRC_FIRMWARE=""        # uefi | bios
SRC_BOOTLOADER=""      # systemd-boot | grub
SRC_ROOT_FSTYPE=""     # ext4 | btrfs | xfs ...
SRC_HOSTNAME=""
SRC_ESP_MOUNT=""       # where the EFI System Partition is mounted (/boot/efi, /boot, /efi); empty on BIOS
SRC_LUKS="no"          # yes if the running root sits on a LUKS container
SRC_INITRD_STYLE=""    # systemd | busybox — decides which crypt hook/cmdline restore uses
SRC_SEP_BOOT_FSTYPE="" # fstype of a SEPARATE (non-ESP) /boot partition; empty if /boot is on root
SRC_SEP_HOME_FSTYPE="" # fstype of a SEPARATE /home partition; empty if /home is on root
SRC_ROOT_USED_BYTES=0  # bytes used on the root filesystem alone (for restore partition sizing)
SRC_HOME_USED_BYTES=0  # bytes used on a separate /home (0 if /home is on root)

# Print the ESP mountpoint, or empty string if none can be found.
# Tries bootctl first (authoritative for systemd-boot), then falls back to
# scanning the obvious candidate mountpoints for a mounted vfat filesystem.
detect_esp_mount() {
  local esp candidate
  esp="$(bootctl --print-esp-path 2>/dev/null || true)"
  if [[ -n "$esp" ]] && findmnt -no TARGET "$esp" &>/dev/null; then
    printf '%s' "$esp"; return
  fi
  for candidate in /boot/efi /efi /boot; do
    if [[ "$(findmnt -no FSTYPE "$candidate" 2>/dev/null)" == "vfat" ]]; then
      printf '%s' "$candidate"; return
    fi
  done
}

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

  # Where the ESP lives (matters for the clone exclude AND where restore mounts
  # it). v1 wrongly hardcoded /boot/efi; setups with the ESP at /boot or /efi
  # would have restored to the wrong place.
  if [[ "$SRC_FIRMWARE" == "uefi" ]]; then
    SRC_ESP_MOUNT="$(detect_esp_mount)"
    [[ -n "$SRC_ESP_MOUNT" ]] || warn "UEFI system but no ESP mount found; restore will assume /boot/efi."
  fi

  # Is the running root on top of a LUKS container? findmnt reports the mapper
  # device (e.g. /dev/mapper/root); lsblk tags that device's TYPE as 'crypt'.
  local root_src
  root_src="$(findmnt -no SOURCE / | sed 's/\[.*//')"
  if [[ "$(lsblk -dno TYPE "$root_src" 2>/dev/null)" == "crypt" ]]; then
    SRC_LUKS="yes"
  fi

  # Which initramfs generator style this system uses. A systemd-based initramfs
  # unlocks LUKS with the sd-encrypt hook (rd.luks.* cmdline); a classic busybox
  # one uses the encrypt hook (cryptdevice= cmdline). The bootloader does NOT
  # decide this — the HOOKS line does.
  if grep -qE '^HOOKS=.*\bsystemd\b' /etc/mkinitcpio.conf 2>/dev/null; then
    SRC_INITRD_STYLE="systemd"
  else
    SRC_INITRD_STYLE="busybox"
  fi

  # Separate /home and /boot partitions. A mountpoint is "separate" when it is a
  # real mount whose backing device differs from root's. We ignore /boot when it
  # IS the ESP (that is handled as the ESP, not as a clonable data partition).
  local home_src boot_src
  home_src="$(findmnt -no SOURCE /home 2>/dev/null | sed 's/\[.*//' || true)"
  if [[ -n "$home_src" && "$home_src" != "$root_src" ]]; then
    SRC_SEP_HOME_FSTYPE="$(findmnt -no FSTYPE /home)"
  fi
  boot_src="$(findmnt -no SOURCE /boot 2>/dev/null | sed 's/\[.*//' || true)"
  if [[ -n "$boot_src" && "$boot_src" != "$root_src" && "/boot" != "$SRC_ESP_MOUNT" ]]; then
    SRC_SEP_BOOT_FSTYPE="$(findmnt -no FSTYPE /boot)"
  fi

  # Used bytes per filesystem, for restore-time partition sizing. 'du -sx' stays
  # on one filesystem, so it naturally excludes any separate /home or /boot.
  SRC_ROOT_USED_BYTES="$(du -sxb / 2>/dev/null | awk '{print $1}')"
  SRC_ROOT_USED_BYTES="${SRC_ROOT_USED_BYTES:-0}"
  if [[ -n "$SRC_SEP_HOME_FSTYPE" ]]; then
    SRC_HOME_USED_BYTES="$(du -sxb /home 2>/dev/null | awk '{print $1}')"
    SRC_HOME_USED_BYTES="${SRC_HOME_USED_BYTES:-0}"
  fi

  ok "Firmware=$SRC_FIRMWARE  Bootloader=$SRC_BOOTLOADER  Root=$SRC_ROOT_FSTYPE  Host=$SRC_HOSTNAME"
  ok "ESP=${SRC_ESP_MOUNT:-none}  LUKS=$SRC_LUKS  initrd=$SRC_INITRD_STYLE  sep/home=${SRC_SEP_HOME_FSTYPE:-no}  sep/boot=${SRC_SEP_BOOT_FSTYPE:-no}"
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

# --- The EFI System Partition ----------------------------------------------
# The ESP is auto-detected and excluded by the build script at clone time
# (wherever it is mounted: /boot/efi, /boot, or /efi). It is regenerated fresh
# on restore, so it is never cloned. You do not need a line for it here.

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

  # Personal-use fast path: a private recovery ISO can include the owner's
  # secrets so the restored system is ready to use with no re-setup. This lets
  # the user opt in with a yes/no instead of hand-editing the list in an editor.
  local include_secrets="no"
  echo
  if confirm "Is this recovery ISO for your PERSONAL use only (kept private)?" "n"; then
    warn "Including secrets bakes your private data straight into the ISO:"
    warn "  SSH/GPG keys, saved browser logins, password stores, and shell history."
    warn "Anyone who gets this ISO could read them, so keep it PRIVATE."
    if confirm "Include your secrets in the ISO (no need to edit the list by hand)?" "n"; then
      include_secrets="yes"
    fi
  fi

  if [[ "$include_secrets" == "yes" ]]; then
    # Build a filtered copy with the SECRETS section (banner to EOF) removed.
    # Volatile caches/trash stay excluded — those are bloat, not secrets.
    EFFECTIVE_EXCLUDE_LIST="$(mktemp -t recovery-exclude.XXXXXX)"
    TMP_FILES+=("$EFFECTIVE_EXCLUDE_LIST")
    sed '/^# SECRETS/,$d' "$EXCLUDE_LIST" >"$EFFECTIVE_EXCLUDE_LIST"
    warn "Secrets WILL be included in this ISO. Keep it private."
  else
    EFFECTIVE_EXCLUDE_LIST="$EXCLUDE_LIST"
  fi

  printf '\n%s----- exclusion list (what will be LEFT OUT of the clone) -----%s\n' \
    "$C_BOLD" "$C_RESET"
  grep -vE '^\s*#|^\s*$' "$EFFECTIVE_EXCLUDE_LIST" | sed 's/^/  /'
  printf '%s--------------------------------------------------------------%s\n\n' \
    "$C_BOLD" "$C_RESET"

  warn "Review the list above. Anything NOT listed will be copied into the ISO."
  # Only offer the hand-editor when we did NOT take the include-secrets path
  # (that path exists precisely to avoid editing the list manually).
  if [[ "$include_secrets" != "yes" ]] \
     && confirm "Open the exclude list in an editor before building?" "n"; then
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

  # mkarchiso puts this in the output filename, so keep it to safe characters:
  # turn anything but letters/digits/dot/underscore/dash into a dash, then
  # collapse and trim dashes. Guards against spaces or typos breaking the build.
  local cleaned
  cleaned="$(printf '%s' "$ISO_BASENAME" \
    | tr -c 'A-Za-z0-9._-' '-' | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"
  [[ -n "$cleaned" ]] || cleaned="$default_name"
  if [[ "$cleaned" != "$ISO_BASENAME" ]]; then
    warn "Adjusted ISO name to safe characters: $cleaned"
    ISO_BASENAME="$cleaned"
  fi

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
  est_bytes="$(rsync -aHAXn --stats --exclude-from="$EFFECTIVE_EXCLUDE_LIST" / "$WORK_DIR/clone-rootfs-probe/" 2>/dev/null \
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
  cp -- "$EFFECTIVE_EXCLUDE_LIST" "$runtime_excludes"
  {
    printf '%s\n' "# --- auto-added by build-recovery-iso.sh ---"
    printf '%s/*\n' "$WORK_DIR"
    printf '%s/*\n' "$OUT_DIR"
    # Exclude the EFI System Partition wherever it is actually mounted. It is
    # vfat and regenerated on restore, so cloning it is both pointless and
    # (with the FAT 'dirty bit') a source of fsck noise. A separate non-ESP
    # /boot (e.g. an ext4 boot partition) is deliberately NOT excluded here, so
    # its kernels and initramfs come across in the clone.
    if [[ -n "$SRC_ESP_MOUNT" ]]; then
      printf '%s/*\n' "$SRC_ESP_MOUNT"
    fi
  } >>"$runtime_excludes"

  rsync -aHAX --numeric-ids --info=progress2 \
    --exclude-from="$runtime_excludes" \
    / "$CLONE_ROOT/"

  ok "Clone complete."
}

# --------------------------------------------------------------------------- #
# 7. Pack the clone into clone.sfs (zstd, CLONE_ZSTD_LEVEL) and write the restore
#    script and metadata into a copy of the stock releng archiso profile.
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
  msg "Packing clone into SquashFS (zstd -${CLONE_ZSTD_LEVEL}) — this is the slowest step..."
  mksquashfs "$CLONE_ROOT" "$payload" \
    -comp zstd -Xcompression-level "$CLONE_ZSTD_LEVEL" -b 1M -noappend

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
SRC_ESP_MOUNT="$SRC_ESP_MOUNT"
SRC_LUKS="$SRC_LUKS"
SRC_INITRD_STYLE="$SRC_INITRD_STYLE"
SRC_SEP_BOOT_FSTYPE="$SRC_SEP_BOOT_FSTYPE"
SRC_SEP_HOME_FSTYPE="$SRC_SEP_HOME_FSTYPE"
SRC_ROOT_USED_BYTES="$SRC_ROOT_USED_BYTES"
SRC_HOME_USED_BYTES="$SRC_HOME_USED_BYTES"
CLONE_SHA256="$clone_sha"
EOF

  # --- The restore script (static; reads the metadata above) -------------- #
  write_restore_script "$PROFILE_DIR/airootfs/root/restore-system.sh"

  # A short pointer for whoever boots the ISO.
  cat >"$PROFILE_DIR/airootfs/root/README-RESTORE.txt" <<EOF
This live ISO is a personal recovery clone of "$SRC_HOSTNAME".

The restore tool starts automatically a few seconds after boot. If you cancel
it (or want to run it again), start it by hand with:

    /root/restore-system.sh

WARNING: restoring ERASES the target disk you select.
EOF

  # --- Auto-launch the restore tool on boot ------------------------------- #
  # releng autologins root on tty1 and sources ~/.zlogin (which runs
  # ~/.automated_script.sh for the 'script=' boot param). We append our own
  # launcher AFTER that. Because this is a single-purpose restore ISO, dropping
  # the user straight into the tool removes a step. Guards keep it safe:
  #   * only on the physical console (/dev/tty1) — never over SSH or serial;
  #   * a 10-second "press any key for a shell" escape for accidental boots /
  #     when you just want a prompt;
  #   * the tool itself still requires typing ERASE before it touches a disk.
  # Written with a QUOTED heredoc so nothing expands at build time; the
  # hostname is read at boot from recovery-metadata.conf.
  cat >>"$PROFILE_DIR/airootfs/root/.zlogin" <<'ZLOGIN_EOF'

# --- personal recovery ISO: auto-launch the restore tool (console only) ---
if [[ $(tty) == "/dev/tty1" ]]; then
  [[ -r /root/recovery-metadata.conf ]] && source /root/recovery-metadata.conf
  print ""
  print -- "==> This is a personal recovery ISO for ${SRC_HOSTNAME:-this system}."
  print -- "    The restore tool will start in 10 seconds."
  print -- "    Press any key now to cancel and get a shell instead."
  if read -t 10 -k 1 _discard 2>/dev/null; then
    print ""
    print -- "Canceled. Run /root/restore-system.sh when you are ready."
  else
    print ""
    /root/restore-system.sh || true
    print ""
    print -- "Restore tool exited. You are now at a shell;"
    print -- "re-run it any time with: /root/restore-system.sh"
  fi
fi
ZLOGIN_EOF
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

# Ask a yes/no question; default shown in capitals. Returns 0 for yes.
confirm() {
  local prompt="$1" default="${2:-n}" reply hint
  if [[ "$default" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  read -r -p "$prompt $hint " reply || true
  reply="${reply:-$default}"
  [[ "$reply" =~ ^([yY]|[yY][eE][sS])$ ]]
}

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

# --- 2. Pick the target disk (numbered menu) ------------------------------- #
# Work out which physical disk the live ISO is running from, so we never offer
# it as a target. On archiso the boot medium is mounted at /run/archiso/bootmnt.
live_disk=""
live_part="$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)"
if [[ -n "$live_part" ]]; then
  pk="$(lsblk -no PKNAME "$live_part" 2>/dev/null | head -1 || true)"
  [[ -n "$pk" ]] && live_disk="/dev/$pk"
fi

echo
msg "Choose the disk to restore onto. Its CONTENTS WILL BE ERASED."
echo
mapfile -t ALL_DISKS < <(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}')
MENU=()
n=0
for d in "${ALL_DISKS[@]}"; do
  [[ "$d" == "$live_disk" ]] && continue   # never the live medium itself
  info="$(lsblk -dno SIZE,MODEL "$d" | sed -E 's/  +/ /g; s/ *$//')"
  n=$(( n + 1 ))
  MENU+=("$d")
  printf '  %2d) %-14s %s\n' "$n" "$d" "$info"
done
(( ${#MENU[@]} > 0 )) || die "No eligible target disks found."
echo
read -r -p "Enter a number (1-${#MENU[@]}): " choice
[[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#MENU[@]} )) \
  || die "Invalid selection."
TARGET="${MENU[choice-1]}"
[[ -b "$TARGET" ]] || die "$TARGET is not a block device."

# --- 2b. Refuse a disk too small to hold the clone (BEFORE wiping it) ------- #
# Otherwise the disk gets erased and the restore fails partway through, leaving
# the user with no system. Sum the cloned data plus the structures we create.
tgt_bytes="$(blockdev --getsize64 "$TARGET")"
GIB=$(( 1024 * 1024 * 1024 ))
need_bytes=$(( ${SRC_ROOT_USED_BYTES:-0} + ${SRC_HOME_USED_BYTES:-0} ))
[[ -d /sys/firmware/efi ]]            && need_bytes=$(( need_bytes + 1 * GIB ))  # ESP
[[ -n "${SRC_SEP_BOOT_FSTYPE:-}" ]]   && need_bytes=$(( need_bytes + 1 * GIB ))  # /boot
need_bytes=$(( need_bytes + 2 * GIB ))   # filesystem overhead + headroom
if (( tgt_bytes < need_bytes )); then
  die "$TARGET holds ~$(( tgt_bytes / GIB )) GiB but the restore needs ~$(( need_bytes / GIB )) GiB. Choose a larger disk."
fi

echo
warn "EVERYTHING on $TARGET will be PERMANENTLY ERASED:"
lsblk -po NAME,SIZE,FSTYPE,MOUNTPOINTS "$TARGET" | sed 's/^/  /'
echo
read -r -p "Type ERASE in capitals to confirm: " CONFIRM
[[ "$CONFIRM" == "ERASE" ]] || die "Not confirmed; nothing was changed."

# --- 3. Decide encryption and partition layout ----------------------------- #
# Determine target firmware (usually matches the source machine on recovery).
if [[ -d /sys/firmware/efi ]]; then TGT_FIRMWARE="uefi"; else TGT_FIRMWARE="bios"; fi
msg "Target firmware detected as: $TGT_FIRMWARE"

# A separate /home and/or /boot are recreated only if the SOURCE had them.
# Empty fstype means "was on root", so we keep it on root here too.
SEP_HOME="no"; [[ -n "${SRC_SEP_HOME_FSTYPE:-}" ]] && SEP_HOME="yes"
SEP_BOOT="no"; [[ -n "${SRC_SEP_BOOT_FSTYPE:-}" ]] && SEP_BOOT="yes"

# The target ESP mountpoint mirrors the source's (/boot/efi, /boot, or /efi).
# Fall back to /boot/efi for an older clone that predates this metadata field.
ESP_MNT="${SRC_ESP_MOUNT:-/boot/efi}"

# Encryption: default to whatever the SOURCE was, but let the operator flip it.
# ENC_STYLE picks the initramfs hook + kernel cmdline form (see chroot below).
ENCRYPT="${SRC_LUKS:-no}"
ENC_STYLE="${SRC_INITRD_STYLE:-busybox}"
echo
if [[ "$ENCRYPT" == "yes" ]]; then
  warn "The source root was LUKS-encrypted; the restore will encrypt the new root by default."
  confirm "Encrypt the restored disk with LUKS?" "y" && ENCRYPT="yes" || ENCRYPT="no"
else
  msg "The source root was NOT encrypted."
  confirm "Encrypt the restored disk with LUKS anyway?" "n" && ENCRYPT="yes" || ENCRYPT="no"
fi

PASSPHRASE=""
if [[ "$ENCRYPT" == "yes" ]]; then
  command -v cryptsetup >/dev/null || die "cryptsetup not found in the live environment."
  warn "LUKS + multi-partition restore paths are NEW in v2 and not yet hardware-tested. Review the result before trusting it."
  local_pw2=""
  while :; do
    read -r -s -p "Enter a LUKS passphrase for the new disk: " PASSPHRASE; echo
    read -r -s -p "Re-enter the passphrase to confirm: " local_pw2; echo
    [[ -n "$PASSPHRASE" ]] || { warn "Passphrase cannot be empty."; continue; }
    [[ "$PASSPHRASE" == "$local_pw2" ]] && break
    warn "Passphrases did not match; try again."
  done
  unset local_pw2
fi

echo
msg "Planned layout on $TARGET:"
printf '  firmware=%s  bootloader=%s  encrypt=%s  esp=%s\n' \
  "$TGT_FIRMWARE" "$SRC_BOOTLOADER" "$ENCRYPT" "${ESP_MNT:-n/a}"
printf '  root=%s  separate /home=%s  separate /boot=%s\n' \
  "$SRC_ROOT_FSTYPE" "$SEP_HOME" "$SEP_BOOT"
confirm "Proceed with this plan?" "y" || die "Aborted; nothing was changed."

# --- 4. Partition the disk -------------------------------------------------- #
msg "Wiping old partition signatures on $TARGET..."
wipefs -a "$TARGET"
sgdisk --zap-all "$TARGET"

partdev() {
  # Handle nvme/mmc naming (need a 'p' before the number) vs sd* naming.
  local disk="$1" num="$2"
  if [[ "$disk" =~ [0-9]$ ]]; then printf '%sp%s' "$disk" "$num"; else printf '%s%s' "$disk" "$num"; fi
}

# Size root only when /home is separate (otherwise root takes the whole rest).
# Give root double its source usage plus 10 GiB of headroom, floor 20 GiB.
GIB=$(( 1024 * 1024 * 1024 ))
root_used_gib=$(( ( ${SRC_ROOT_USED_BYTES:-0} + GIB - 1 ) / GIB ))
root_size_gib=$(( root_used_gib * 2 + 10 ))
(( root_size_gib < 20 )) && root_size_gib=20

ESP_PART=""; BOOT_PART=""; ROOT_PART=""; HOME_PART=""
pn=0
if [[ "$TGT_FIRMWARE" == "uefi" ]]; then
  pn=$(( pn + 1 )); sgdisk -n${pn}:0:+1GiB -t${pn}:ef00 -c${pn}:EFI "$TARGET"
  ESP_PART="$(partdev "$TARGET" "$pn")"
else
  # Tiny BIOS boot partition for GRUB on a GPT disk.
  pn=$(( pn + 1 )); sgdisk -n${pn}:0:+1MiB -t${pn}:ef02 -c${pn}:bios "$TARGET"
fi
if [[ "$SEP_BOOT" == "yes" ]]; then
  pn=$(( pn + 1 )); sgdisk -n${pn}:0:+1GiB -t${pn}:8300 -c${pn}:boot "$TARGET"
  BOOT_PART="$(partdev "$TARGET" "$pn")"
fi
pn=$(( pn + 1 ))
if [[ "$SEP_HOME" == "yes" ]]; then
  sgdisk -n${pn}:0:+${root_size_gib}GiB -t${pn}:8300 -c${pn}:root "$TARGET"
else
  sgdisk -n${pn}:0:0 -t${pn}:8300 -c${pn}:root "$TARGET"
fi
ROOT_PART="$(partdev "$TARGET" "$pn")"
if [[ "$SEP_HOME" == "yes" ]]; then
  pn=$(( pn + 1 )); sgdisk -n${pn}:0:0 -t${pn}:8300 -c${pn}:home "$TARGET"
  HOME_PART="$(partdev "$TARGET" "$pn")"
fi
partprobe "$TARGET"; sleep 1

# --- 5. Optional LUKS containers ------------------------------------------- #
# When encrypting we put a LUKS2 container on the root (and separate /home)
# partition, then format the unlocked mapper device. ROOT_FS_DEV / HOME_FS_DEV
# point at whatever we end up making the filesystem on (mapper or bare part).
ROOT_FS_DEV="$ROOT_PART"; HOME_FS_DEV="$HOME_PART"
ROOT_LUKS_UUID=""; HOME_LUKS_UUID=""
if [[ "$ENCRYPT" == "yes" ]]; then
  msg "Creating LUKS2 container on root ($ROOT_PART)..."
  printf '%s' "$PASSPHRASE" | cryptsetup luksFormat --type luks2 --batch-mode "$ROOT_PART" -
  printf '%s' "$PASSPHRASE" | cryptsetup open "$ROOT_PART" cryptroot -
  ROOT_FS_DEV="/dev/mapper/cryptroot"
  ROOT_LUKS_UUID="$(cryptsetup luksUUID "$ROOT_PART")"
  if [[ "$SEP_HOME" == "yes" ]]; then
    msg "Creating LUKS2 container on home ($HOME_PART)..."
    printf '%s' "$PASSPHRASE" | cryptsetup luksFormat --type luks2 --batch-mode "$HOME_PART" -
    printf '%s' "$PASSPHRASE" | cryptsetup open "$HOME_PART" crypthome -
    HOME_FS_DEV="/dev/mapper/crypthome"
    HOME_LUKS_UUID="$(cryptsetup luksUUID "$HOME_PART")"
  fi
fi

# --- 6. Format filesystems -------------------------------------------------- #
mkfs_for() {
  # $1 = fstype, $2 = device
  case "$1" in
    ext4)  mkfs.ext4 -F "$2" ;;
    btrfs) mkfs.btrfs -f "$2" ;;
    xfs)   mkfs.xfs -f "$2" ;;
    *) die "Unsupported filesystem '$1' on $2 (extend the script)." ;;
  esac
}

msg "Formatting root ($ROOT_FS_DEV) as $SRC_ROOT_FSTYPE..."
mkfs_for "$SRC_ROOT_FSTYPE" "$ROOT_FS_DEV"
if [[ "$SEP_BOOT" == "yes" ]]; then
  msg "Formatting /boot ($BOOT_PART) as $SRC_SEP_BOOT_FSTYPE..."
  mkfs_for "$SRC_SEP_BOOT_FSTYPE" "$BOOT_PART"
fi
if [[ "$SEP_HOME" == "yes" ]]; then
  msg "Formatting /home ($HOME_FS_DEV) as $SRC_SEP_HOME_FSTYPE..."
  mkfs_for "$SRC_SEP_HOME_FSTYPE" "$HOME_FS_DEV"
fi

# --- 7. Mount the target tree (root, then nested mounts) -------------------- #
mount "$ROOT_FS_DEV" /mnt
if [[ "$SEP_BOOT" == "yes" ]]; then
  mkdir -p /mnt/boot
  mount "$BOOT_PART" /mnt/boot
fi
if [[ "$TGT_FIRMWARE" == "uefi" ]]; then
  msg "Formatting ESP ($ESP_PART) as FAT32 and mounting at $ESP_MNT..."
  mkfs.fat -F32 "$ESP_PART"
  mkdir -p "/mnt$ESP_MNT"
  mount "$ESP_PART" "/mnt$ESP_MNT"
fi
if [[ "$SEP_HOME" == "yes" ]]; then
  mkdir -p /mnt/home
  mount "$HOME_FS_DEV" /mnt/home
fi

# --- 8. Unpack the clone --------------------------------------------------- #
# unsquashfs lays the whole tree down across the mounts: files under /home land
# on the /home partition, under /boot on the /boot partition, and so on.
msg "Unpacking clone.sfs onto the new disk (this takes a while)..."
unsquashfs -f -d /mnt "$PAYLOAD"
ok "Clone unpacked."

# --- 9. Regenerate fstab (and crypttab) with the NEW UUIDs ------------------ #
msg "Generating /etc/fstab from the new disk..."
genfstab -U /mnt >/mnt/etc/fstab

# Filesystem UUID of the (possibly unlocked) root — needed for the kernel
# cmdline. The clone still carries the OLD disk's identifiers, so this must be
# rewritten or the restored system will not find its root and will not boot.
NEW_ROOT_UUID="$(blkid -s UUID -o value "$ROOT_FS_DEV")"
msg "New root filesystem UUID is $NEW_ROOT_UUID"

if [[ "$ENCRYPT" == "yes" ]]; then
  # crypttab names each container by the LUKS partition UUID so it is unlocked
  # at boot. 'none' asks for the passphrase interactively.
  msg "Writing /etc/crypttab..."
  {
    printf 'cryptroot UUID=%s none luks\n' "$ROOT_LUKS_UUID"
    [[ "$SEP_HOME" == "yes" ]] && printf 'crypthome UUID=%s none luks\n' "$HOME_LUKS_UUID"
  } >/mnt/etc/crypttab
fi

# Build the root portion of the kernel command line for the chroot to apply.
# Plaintext: plain root=UUID. Encrypted: depends on the initramfs style.
if [[ "$ENCRYPT" == "yes" ]]; then
  if [[ "$ENC_STYLE" == "systemd" ]]; then
    ROOT_SPEC="rd.luks.name=$ROOT_LUKS_UUID=cryptroot root=/dev/mapper/cryptroot"
  else
    ROOT_SPEC="cryptdevice=UUID=$ROOT_LUKS_UUID:cryptroot root=/dev/mapper/cryptroot"
  fi
else
  ROOT_SPEC="root=UUID=$NEW_ROOT_UUID"
fi

# --- 10. Reinstall bootloader + rebuild initramfs inside the clone ---------- #
msg "Rebuilding initramfs and reinstalling bootloader in chroot..."
arch-chroot /mnt /bin/bash -euo pipefail <<CHROOT
# If encrypting, make sure mkinitcpio has the right unlock hook before
# 'filesystems'. We only add a hook when it is missing, to avoid disturbing a
# source config that already has it.
if [[ "$ENCRYPT" == "yes" ]]; then
  if [[ "$ENC_STYLE" == "systemd" ]]; then
    grep -qE '^HOOKS=.*\bsd-encrypt\b' /etc/mkinitcpio.conf \
      || sed -i -E 's/(^HOOKS=\(.*)\bfilesystems\b/\1sd-encrypt filesystems/' /etc/mkinitcpio.conf
  else
    grep -qE '^HOOKS=.*\bencrypt\b' /etc/mkinitcpio.conf \
      || sed -i -E 's/(^HOOKS=\(.*)\bfilesystems\b/\1encrypt filesystems/' /etc/mkinitcpio.conf
    grep -qE '^HOOKS=.*\bkeyboard\b' /etc/mkinitcpio.conf \
      || sed -i -E 's/(^HOOKS=\(.*)\bencrypt\b/\1keyboard encrypt/' /etc/mkinitcpio.conf
  fi
fi

# Rebuild every initramfs from the (now possibly updated) config.
mkinitcpio -P

if [[ "$TGT_FIRMWARE" == "uefi" && "$SRC_BOOTLOADER" == "systemd-boot" ]]; then
  # Install systemd-boot to the detected ESP and re-create the EFI boot entry.
  bootctl --esp-path="$ESP_MNT" install

  # Rewrite the kernel command line: strip any cloned-in root/crypt tokens and
  # append the freshly-computed ones, preserving the rest (quiet, splash, ...).
  CMDLINE_FILE=/etc/kernel/cmdline
  if [[ -f \$CMDLINE_FILE ]]; then base="\$(cat \$CMDLINE_FILE)"; else base="quiet rw"; fi
  clean="\$(printf '%s' "\$base" | tr ' ' '\n' \
    | grep -vE '^(root=|cryptdevice=|rd\.luks\.)' | tr '\n' ' ')"
  printf '%s %s\n' "\$clean" "$ROOT_SPEC" \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ \$//' >\$CMDLINE_FILE

  # Re-populate the ESP Boot-Loader-Spec entries for every installed kernel.
  # Arch kernel packages place the image at /usr/lib/modules/\$kver/vmlinuz.
  for kver in /usr/lib/modules/*/; do
    kver="\$(basename "\$kver")"
    if [[ -f "/usr/lib/modules/\$kver/vmlinuz" ]]; then
      kernel-install add "\$kver" "/usr/lib/modules/\$kver/vmlinuz"
    fi
  done
elif [[ "$TGT_FIRMWARE" == "uefi" && "$SRC_BOOTLOADER" == "grub" ]]; then
  if [[ "$ENCRYPT" == "yes" ]]; then
    # GRUB must be told to unlock the container and pass the cmdline. This path
    # is best-effort; verify /etc/default/grub after restore.
    sed -i 's/^#\?GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
    grep -q '^GRUB_ENABLE_CRYPTODISK=y' /etc/default/grub || printf 'GRUB_ENABLE_CRYPTODISK=y\n' >>/etc/default/grub
    sed -i -E "s|^GRUB_CMDLINE_LINUX=\"(.*)\"|GRUB_CMDLINE_LINUX=\"\1 $ROOT_SPEC\"|" /etc/default/grub
  fi
  grub-install --target=x86_64-efi --efi-directory="$ESP_MNT" --bootloader-id=GRUB
  grub-mkconfig -o /boot/grub/grub.cfg
else
  # BIOS / GRUB.
  if [[ "$ENCRYPT" == "yes" ]]; then
    sed -i 's/^#\?GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
    grep -q '^GRUB_ENABLE_CRYPTODISK=y' /etc/default/grub || printf 'GRUB_ENABLE_CRYPTODISK=y\n' >>/etc/default/grub
    sed -i -E "s|^GRUB_CMDLINE_LINUX=\"(.*)\"|GRUB_CMDLINE_LINUX=\"\1 $ROOT_SPEC\"|" /etc/default/grub
  fi
  grub-install --target=i386-pc "$TARGET"
  grub-mkconfig -o /boot/grub/grub.cfg
fi
CHROOT

# --- 11. Clean up ----------------------------------------------------------- #
sync
umount -R /mnt
[[ "$SEP_HOME" == "yes" && "$ENCRYPT" == "yes" ]] && cryptsetup close crypthome 2>/dev/null || true
[[ "$ENCRYPT" == "yes" ]] && cryptsetup close cryptroot 2>/dev/null || true
ok "Restore complete."

# Offer to reboot/poweroff so the user does not have to recall the command.
echo
if confirm "Reboot into the restored system now?" "y"; then
  warn "Remove the ISO media now so the machine boots from the restored disk."
  read -r -p "Press Enter to reboot... " _ || true
  systemctl reboot
elif confirm "Power off now instead?" "n"; then
  warn "Remove the ISO media after the machine powers off."
  systemctl poweroff
else
  ok "Leaving you at a shell. Remove the media and reboot when you are ready."
fi
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

  # Save the build log next to the ISO so a long run is debuggable after the fact.
  local logdest="${iso%.iso}.log"
  cp -f "$BUILD_LOG" "$logdest" 2>/dev/null || true

  # Final summary: human-readable size and elapsed wall-clock time.
  local iso_size elapsed mins secs
  iso_size="$(du -h "$iso" | cut -f1)"
  elapsed=$(( $(date +%s) - START_EPOCH ))
  mins=$(( elapsed / 60 )); secs=$(( elapsed % 60 ))

  BUILD_OK=1   # mark success so the cleanup trap doesn't flag an aborted build
  ok "ISO ready:  $iso  (${iso_size})"
  ok "Checksum:   ${iso}.sha256"
  ok "Build log:  $logdest"
  ok "Total time: ${mins}m ${secs}s"
  printf '\n%sBoot the ISO: the restore tool starts automatically after a short countdown.%s\n' \
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
