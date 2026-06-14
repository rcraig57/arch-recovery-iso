# Bare-Metal Recovery Test — Checklist

Real-hardware test of `build-recovery-iso.sh` on the spare disk **sdb**
(HGST HTS721010A9E630, 931.5 GB). Target machine: ASRock X870, NVIDIA 5080,
boot menu key **F11**, Secure Boot **off**.

The daily-driver CachyOS lives on a *different* disk (Samsung 990 PRO,
`nvme1n1`). Nothing in this test should ever touch it.

Each command is on its own line. Run them one at a time and read the output
before moving on.

---

## Phase A — Wipe sdb  (done before CachyOS install)

> `sudo` = run as administrator.

```
sudo wipefs -a /dev/sdb
```
Erases all filesystem/partition-table *signatures* on the HGST disk (`-a` =
all). The old MX partitions disappear.

```
sudo sgdisk --zap-all /dev/sdb
```
Destroys both the GPT and any leftover MBR, leaving a genuinely blank disk.

Confirm it is blank (should show the disk with **no** child partitions):

```
lsblk /dev/sdb
```

---

## Phase B — Install CachyOS to sdb  (manual, you drive this)

Done by hand to mirror a real user. Key points so the test stays valid:

- In the installer, choose **sdb (the 931.5 GB HGST)** as the install disk.
  Do **not** pick `nvme1n1` (daily driver) or any other disk.
- Let the installer use **erase-disk / automatic partitioning on sdb only**.
- Accept the installer's default bootloader (CachyOS uses **systemd-boot**);
  do not hand-swap it — the recovery tool reinstalls whatever it detects.
- After install: boot into the new sdb system (F11 -> the sdb entry), log in,
  confirm the desktop and NVIDIA driver work. This is the "live system" we
  will clone.

---

## Phase C — Build the recovery ISO  (booted INTO sdb's CachyOS)

The builder clones the *running* system, so it must run while booted into
sdb — not from the daily driver.

1. Get the recovery project onto sdb. Easiest: copy the folder from the
   daily driver via the shared storage disk, or re-clone it. You need
   `build-recovery-iso.sh`, `recovery-exclude.list`, and `docs/`.

2. Make sure the script is executable (`chmod +x` = add the run permission):

```
chmod +x ~/archiso-recovery/build-recovery-iso.sh
```

3. Run the builder as root (it installs its own dependencies — archiso,
   arch-install-scripts, squashfs-tools — via pacman):

```
cd ~/archiso-recovery
```
```
sudo ./build-recovery-iso.sh
```

   - It prompts for **Work directory** (needs lots of free space): accept the
     default or give a path on sdb with plenty of room.
   - **Output directory for the .iso**: pick a path on sdb.
   - **ISO base name**: any label, e.g. `cachyos-sdb-recovery`.
   - On a 7200 rpm HDD this is slow. For a faster (less-compressed) build,
     prefix the command with `CLONE_ZSTD_LEVEL=1`:

```
CLONE_ZSTD_LEVEL=1 sudo ./build-recovery-iso.sh
```

4. Verify the ISO and its checksum (`sha256sum -c` recomputes the hash and
   checks it matches the saved `.sha256` file — output should say `OK`):

```
cd <your-output-directory>
```
```
sha256sum -c *.iso.sha256
```

---

## Phase D — Put the ISO on the Ventoy USB and boot it

1. Plug in the Ventoy USB. Copy the ISO onto it (`cp` = copy; replace the
   names with your real filenames — list them first):

```
ls
```
```
cp <your-recovery>.iso /run/media/$USER/Ventoy/
```

   (If Ventoy is mounted elsewhere, use that path instead.)

2. Reboot, press **F11** at power-on, choose the **Ventoy** USB, then select
   the recovery ISO from the Ventoy menu.

3. The recovery tool starts automatically after a short, **cancelable**
   countdown. Let it run.

---

## Phase E — Restore onto sdb  (from the live ISO)

> This ERASES the disk you select. The Ventoy USB itself is auto-excluded
> from the menu.

1. At the numbered disk menu, the target is the **only 931.5 GB HGST**.
   The Samsung (~1.8 TB), Crucial/Windows (~3.6 TB), etc. must **not** be
   chosen. Read the `lsblk` preview it shows.

2. When asked, **decline encryption** (we did not set up LUKS).

3. Type **ERASE** in capitals to confirm.

4. Let it unpack `clone.sfs`, regenerate fstab/UUIDs, rebuild initramfs, and
   reinstall systemd-boot. When it offers to reboot, **remove the USB first**,
   then reboot.

---

## Phase F — Verify the restored system

Boot into sdb (F11 if needed). Then check:

```
findmnt /
```
Root is mounted from sdb, on the expected filesystem.

```
cat /etc/fstab
```
Entries reference the **new** disk's UUIDs (no leftover MX or stale UUIDs).

```
nvidia-smi
```
NVIDIA driver loads and sees the 5080.

```
bootctl status
```
systemd-boot is installed on sdb's ESP and is the active loader.

```
efibootmgr
```
A boot entry points at sdb's ESP. Confirm your **daily-driver entry on
nvme1n1 still exists** and is still the default boot order — the restore may
have added/reordered NVRAM entries (this is non-destructive to other disks'
data, but worth re-setting in the ASRock BIOS if the order changed).

---

## Result to record

- Did sdb boot cleanly into the restored desktop? (Y/N)
- fstab UUIDs correct? NVIDIA working? NVRAM sane?
- Anything the VM test did not catch.
