# Disk Recovery Tool

Whole-disk **backup and restore** for Arch-family Linux, built on
[partclone](https://partclone.org) + [zstd](https://github.com/facebook/zstd),
with a GTK4 graphical front end styled after Erik Dubois' Arch Linux Tweak Tool.

It images only the **used blocks** of each filesystem (so a 1 TB disk that is
100 GB full produces ~100 GB, not 1 TB), preserves **btrfs snapshots and
subvolumes** and **filesystem UUIDs**, verifies every image with SHA-256, and can
grow the last partition onto a larger disk on restore. The GUI is a thin wrapper:
every operation runs the same audited shell scripts you can run from a terminal,
so the GUI and CLI never drift apart.

> **Heads up:** restoring **erases the target disk**. It is guarded by a typed
> `ERASE` confirmation and a final dialog, and the backend refuses mounted disks
> and verifies checksums before writing anything.

---

## Features

- **Used-blocks-only imaging** with partclone (btrfs, ext4, vfat, exfat, xfs,
  ntfs, f2fs), raw `partclone.dd` fallback for anything else.
- **Complete, bit-exact backups** — all btrfs subvolumes and snapshots included.
- **zstd compression** with a selectable level.
- **SHA-256 verification** of every image, checked before any restore writes.
- **Restore to a same or larger disk**, optionally growing the last partition to
  fill the extra space.
- **Optional bootloader re-registration** (Limine / GRUB / systemd-boot) for
  restoring onto a different machine; same-machine restores boot via the existing
  EFI fallback with no extra step.
- **GTK4 GUI** with a live progress bar (parsed from partclone) and a full log,
  plus a CLI for scripting and rescue environments.

## Repository layout

```
recovery-gui/        GTK4 application (launcher, src/, data/)
part_clone/          backend: partclone-backup.sh, partclone-restore.sh, self-tests
PKGBUILD             Arch package (-git)
disk-recovery-tool.install
LICENSE / NOTICE     GPL-3.0-or-later + credits
docs/                notes and checklists
```

## Install (Arch / CachyOS / Kiro / EndeavourOS / …)

```
git clone https://github.com/rcraig57/disk-recovery-tool.git
cd disk-recovery-tool
makepkg -si
```

`makepkg -si` pulls the dependencies and installs the package. Afterwards launch
**Disk Recovery Tool** from your application menu, or run `recovery-tool`.

> Do **not** run it as root yourself — the launcher elevates the whole app once
> via `pkexec` (your desktop's polkit agent prompts for the admin password).
> partclone, losetup and mount all need root.

## Use it from the terminal (no GUI / rescue environment)

The scripts in `part_clone/` are standalone. Back up `/dev/sdX` to a folder:

```
sudo ./part_clone/partclone-backup.sh /dev/sdX /mnt/storage
```

Restore a backup folder onto a target disk (this erases it):

```
sudo ./part_clone/partclone-restore.sh /mnt/storage/HOST-img-YYYYMMDD-HHMMSS /dev/sdX
```

Both are interactive by default and accept flags for unattended use
(`--yes`, `--erase`, `--grow`/`--no-grow`, `--bootloader`/`--no-bootloader`,
`--no-reboot`). The source disk for a backup must be unmounted — image a disk you
did **not** boot from (e.g. from a live USB, or a second drive).

## How it works

`partclone-backup.sh` writes, per partition: a compressed image
(`partclone.<fs> -c | zstd`), a `.sha256`, the GPT/MBR layout (`sfdisk -d`), a
manifest, and metadata. `partclone-restore.sh` verifies all checksums, recreates
the partition table, restores each image, optionally grows the last partition,
and optionally re-registers the bootloader in a chroot. Because images are
block-exact and UUIDs are preserved, the restored system's `fstab` and bootloader
command line already match.

## Dependencies

`python` `python-gobject` `gtk4` `partclone` `zstd` `util-linux` `gptfdisk`
`parted` `btrfs-progs` `e2fsprogs` `polkit`. Optional: `xorg-xhost` (to run the
GUI as root under X11/XWayland), `limine`/`grub` (bootloader re-registration),
`dosfstools` (loopback self-test). The PKGBUILD declares all of these.

## Credits & license

Engine: **partclone** (GPL-2.0-or-later). GUI look/feel and launcher modelled on
**Erik Dubois' Arch Linux Tweak Tool** (GPL-3.0). See `NOTICE` for full credits.

Licensed under **GPL-3.0-or-later** — see `LICENSE`.
