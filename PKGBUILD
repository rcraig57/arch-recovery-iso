# Maintainer: rcraig <rcraig.netmail@gmail.com>
#
# Disk Recovery Tool — GTK4 front end + partclone backup/restore backend.
#
# This is a VCS (-git) package: it builds the latest commit of the project repo.
# Before publishing/building, set _repo below to YOUR git remote. The repo is
# expected to contain two top-level directories:
#     recovery-gui/   (the GTK4 app: recovery-tool launcher, src/, data/)
#     part_clone/     (the backend: partclone-backup.sh, partclone-restore.sh)
#
# Build & install locally:   makepkg -si
# Generate AUR metadata:     makepkg --printsrcinfo > .SRCINFO

# ----- set this to your repository's clone URL ------------------------------ #
_repo="https://github.com/rcraig57/disk-recovery-tool.git"
# ---------------------------------------------------------------------------- #

_pkgname=disk-recovery-tool
pkgname=disk-recovery-tool-git
pkgver=0.1.0
pkgrel=1
pkgdesc="GTK4 whole-disk backup and restore tool (partclone + zstd), styled like Arch Linux Tweak Tool"
arch=('x86_64')
url="${_repo%.git}"
license=('GPL-3.0-or-later')
depends=(
  'python'
  'python-gobject'
  'gtk4'
  'partclone'
  'zstd'
  'util-linux'      # lsblk, blkid, findmnt, sfdisk, blockdev, wipefs, mkswap, mount
  'gptfdisk'        # sgdisk
  'parted'          # partprobe
  'btrfs-progs'     # btrfs (resize + superblock size estimate)
  'e2fsprogs'       # dumpe2fs, e2fsck, resize2fs
  'polkit'          # pkexec
)
optdepends=(
  'xorg-xhost: run the GUI as root under an X11/XWayland session'
  'limine: bootloader re-registration when restoring a Limine system to a new machine'
  'grub: bootloader re-registration when restoring a GRUB system to a new machine'
  'dosfstools: run the loopback grow self-test (test-grow-loopback.sh)'
)
makedepends=('git')
provides=("$_pkgname")
conflicts=("$_pkgname")
install="$_pkgname.install"
source=("$_pkgname::git+$_repo")
sha256sums=('SKIP')

pkgver() {
  cd "$srcdir/$_pkgname"
  printf 'r%s.%s' "$(git rev-list --count HEAD)" "$(git rev-parse --short=7 HEAD)"
}

package() {
  cd "$srcdir/$_pkgname"

  local share="$pkgdir/usr/share/recovery-tool"

  # --- GUI: python sources + stylesheet ---
  install -dm755 "$share/src"
  install -m644 recovery-gui/src/*.py recovery-gui/src/style.css "$share/src/"

  # --- data: icon used in-app by the About page (config.icon_file()) ---
  install -Dm644 recovery-gui/data/icons/hicolor/scalable/apps/org.ohmychadwm.recovery.svg \
    "$share/data/icons/hicolor/scalable/apps/org.ohmychadwm.recovery.svg"

  # --- backend scripts (authoritative backup/restore logic) ---
  install -dm755 "$share/scripts"
  install -m755 part_clone/partclone-backup.sh part_clone/partclone-restore.sh "$share/scripts/"
  # optional self-test / diagnostic helpers (ignore if absent)
  install -m755 part_clone/test-grow-loopback.sh part_clone/test-bootloader-detect.sh \
    "$share/scripts/" 2>/dev/null || true

  # --- launcher (run as user; elevates the whole app via pkexec) ---
  install -Dm755 recovery-gui/recovery-tool "$pkgdir/usr/bin/recovery-tool"

  # --- desktop entry ---
  install -Dm644 recovery-gui/data/recovery-tool.desktop \
    "$pkgdir/usr/share/applications/recovery-tool.desktop"

  # --- polkit policy (custom auth message for the installed binary) ---
  install -Dm644 recovery-gui/data/org.ohmychadwm.recovery.policy \
    "$pkgdir/usr/share/polkit-1/actions/org.ohmychadwm.recovery.policy"

  # --- system icon (titlebar + application menu) ---
  install -Dm644 recovery-gui/data/icons/hicolor/scalable/apps/org.ohmychadwm.recovery.svg \
    "$pkgdir/usr/share/icons/hicolor/scalable/apps/org.ohmychadwm.recovery.svg"

  # --- docs ---
  install -Dm644 recovery-gui/README.md "$pkgdir/usr/share/doc/$_pkgname/README.md"
}
