# Personal Recovery ISO Builder

Make a bootable USB/DVD image that is a **clone of your own running system** —
your installed programs, your settings, and your home folder — so that if your
disk dies you can put everything back on a new disk and carry on as if nothing
happened.

This is the Arch-world equivalent of MX Linux's *MX Snapshot*. It works on plain
**Arch**, **CachyOS**, and **Kiro**.

![A system restored from a recovery ISO, booting to its login screen on a fresh disk](docs/boot-test-login.png)

> Verified end-to-end: a system cloned into a recovery ISO, then restored onto a
> blank disk, boots all the way to its login screen — as shown above.

---

## How it works (the short version)

1. The script copies your live system into a temporary folder, leaving out
   junk and secrets (a list you can edit first).
2. It compresses that copy into a single file, `clone.sfs`.
3. It packs `clone.sfs` into a normal Arch live ISO using `mkarchiso`.

The finished ISO boots a plain, reliable Arch live environment. Your cloned
system rides along inside it as data. To put your system back, you boot the ISO
and run one restore command.

---

## What you need

- An Arch-based system (Arch, CachyOS, or Kiro).
- Free disk space of about **2.5 times** the size of your data. The script
  measures this for you and warns if you are short.
- Four software packages. The script checks for them and offers to install any
  that are missing:
  - `archiso` (provides the `mkarchiso` command that builds the ISO)
  - `arch-install-scripts` (provides `genfstab` and `arch-chroot`, used on restore)
  - `rsync` (copies your files)
  - `squashfs-tools` (provides `mksquashfs`, the compressor)

---

## Step 1 — Build the ISO

Open a terminal in the folder that holds `build-recovery-iso.sh`.

Run the build script with administrator rights. The word `sudo` means "run as
the system administrator"; it will ask for your password:

```
sudo ./build-recovery-iso.sh
```

The script will:

1. **Check the four packages** and offer to install any missing ones.
2. **Detect your boot setup** (UEFI or BIOS; systemd-boot or GRUB) so the
   restore can rebuild it correctly later.
3. **Show the exclusion list** — everything that will be *left out* of the clone
   (caches, and secrets such as SSH keys and saved passwords). It offers to open
   this list in an editor so you can change it. **Read this carefully:** anything
   not on the list gets copied into the ISO.
4. **Ask three questions** — where to do the build work, where to save the
   finished `.iso`, and what to name it. Press **Enter** to accept each default.
5. **Clone, compress, and build.** This is slow (it compresses many gigabytes).
   When it finishes it prints the path to your `.iso` and a matching `.sha256`
   checksum file.

> **About secrets (important if you share the ISO).** By default the script
> leaves out SSH private keys, GPG keys, password stores, browser logins, cloud
> tokens, and shell history. If you remove any of those lines from the exclusion
> list, that secret gets baked into the ISO. Only do that for a recovery image
> you will keep **private**.

---

## Step 2 — Write the ISO to a USB stick

Plug in a USB stick that you do not mind erasing (8 GB or larger).

Find its device name. The following command lists your disks and their sizes so
you can identify the stick:

```
lsblk -dpno NAME,SIZE,MODEL
```

Suppose the stick is `/dev/sdX` (replace `sdX` with the real name — getting this
wrong erases the wrong disk). Write the ISO to it. Here `if=` is the input file
and `of=` is the output device; `status=progress` shows a progress bar:

```
sudo dd if=your-recovery.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

---

## Step 3 — Restore onto a new disk

Boot the target machine from the USB stick (use the firmware boot menu). You
arrive at a plain Arch live prompt, logged in as `root`.

Start the restore tool:

```
/root/restore-system.sh
```

It walks you through everything:

1. **Verifies** the clone is undamaged (checks its `.sha256`) **before touching
   any disk**.
2. **Lists the disks** and asks which one to restore onto.
3. **Asks you to type `ERASE`** to confirm — the chosen disk is wiped completely.
4. Partitions and formats the disk, unpacks your clone onto it, writes a fresh
   `/etc/fstab`, rebuilds the boot images, and reinstalls the matching
   bootloader.

When it says it is finished, remove the USB stick and reboot. Your system comes
back up as it was.

---

## What this version does **not** do yet

- **Encrypted (LUKS) disks.** If your source system is encrypted, restore puts
  it back **unencrypted**. Encryption-on-restore is planned for a later version.
- It assumes a single root partition plus (on UEFI) an EFI partition. Exotic
  layouts may need adjusting.

---

## Files in this folder

- `build-recovery-iso.sh` — the build script you run.
- `recovery-exclude.list` — the editable list of what to leave out. It is created
  automatically the first time you run the build script.
- `restore-system.sh` — the restore tool. You do **not** run this here; the build
  script writes a copy of it into the ISO.
