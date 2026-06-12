# archiso Personal-Recovery ISO — Design Brief

> Design brief for the recovery-ISO build tool: the architecture decisions, the
> landmines that must be handled, and the test plan. Read top to bottom.

## The goal (what we are building)

A **single, self-contained Bash script** the user runs on their own Arch-based
system. When run, it:

1. Checks that all dependencies are present (and offers to install missing ones).
2. Asks the user a few questions.
3. Builds a **bootable, installable ISO that is a clone of their running system**
   — installed packages, system configs, and their `/home` — so that after a
   drive failure they can boot the ISO on a new drive and reinstall quickly,
   coming back to their system "as if nothing happened."

Audience: members of the **Kiro discussion board** and, by extension, the user
themselves (they run Kiro). Must work on plain **Arch**, **CachyOS**, and
**Kiro**. It is conceptually the Arch-world answer to MX Linux's MX Snapshot.

## Chosen architecture — Option B: clone the live root → SquashFS → mkarchiso

**Decision made on the Mint side, with the user, and it is firm.** Two
architectures were on the table:

- **Option A — reproduce from a package list** (the archiso-idiomatic way):
  capture `pacman -Qqe`, reinstall from repos, overlay dotfiles. REJECTED:
  it breaks on AUR / chaotic-aur / nemesis_repo / the CachyOS kernel, and Kiro's
  repos use `SigLevel = Never` (unsigned). Reproducing this per-distro is fragile
  and high-maintenance.
- **Option B — clone the live root** (chosen): `rsync` the running `/` into a
  work rootfs (honoring an exclude list), `mksquashfs` it, drop that in as the
  `airootfs` of an archiso profile, and run `mkarchiso`. **This copies installed
  files regardless of their origin**, so AUR/chaotic-aur/nemesis_repo/cachyos all
  come along for free and the SAME tool works on Arch, CachyOS, and Kiro.

archiso is NOT a clone tool by default — it rebuilds from a recipe. Option B
bends it into a clone tool by supplying a prebuilt rootfs as the airootfs. This
is the less-idiomatic but far more robust path for a heterogeneous audience.

## Confirmed decisions (locked with the user)

1. **Home directory:** include **full `/home`** WITH a built-in
   secrets/cache exclusion list AND an interactive "here is what will be
   included — edit it?" review step before the build runs.
2. **Restore experience:** a **bundled text-menu restore script** inside the
   ISO. Flow: pick target disk → confirm wipe → partition + format → unpack the
   SquashFS onto it → `genfstab` → `arch-chroot` to reinstall the bootloader and
   rebuild the initramfs. (Kiro ships Calamares, but Calamares is
   package-install-oriented and does not fit a raw file clone — a custom restore
   script is the right match.)

## Landmines that MUST be handled

- **Secrets.** Default-exclude SSH private keys (`~/.ssh/id_*`, `~/.ssh/*_vm`),
  GPG keys (`~/.gnupg`), password stores / wallets / keyrings, browser sessions
  and saved logins, cloud/API tokens, and `~/.bash_history` / shell history.
  Show the full exclusion list and let the user edit it before building. This is
  the #1 risk if board members share the method publicly — they could otherwise
  bake their secrets into a distributable ISO.
- **Boot / hardware specifics.** The restore step must **regenerate `fstab`
  UUIDs with `genfstab`** and **reinstall the bootloader** and **rebuild the
  initramfs (`mkinitcpio -P`)** on the target — never copy the old drive's UUIDs.
- **Bootloader detection.** Detect whether the source uses **systemd-boot**
  (Kiro UEFI default) or **GRUB** (Kiro BIOS) and reinstall the matching one on
  restore.
- **The live ISO needs its own bootable kernel + initramfs.** The clone carries
  the user's actual kernel (e.g. `linux-cachyos`); make sure the archiso profile
  boots a kernel that is present in the clone, or include a stock `linux` as a
  fallback boot path.
- **Disk space.** The build work directory can need ~2–3× the final ISO size.
  Preflight-check free space and let the user choose the work location.
- **Privileges.** `mkarchiso` and the restore script both require root.
- **(Optional) LUKS.** If the source has a `/etc/crypttab`, decide whether the
  restore offers encryption. Park this for v2 unless the user wants it now.

## Dependency preflight the script must perform

- Running as root (or via `sudo`).
- Packages: `archiso` (provides `mkarchiso`), `arch-install-scripts` (provides
  `genfstab`, `arch-chroot`), `rsync`, `squashfs-tools` (provides `mksquashfs`).
- Enough free disk in the chosen work location (apply the 2–3× rule).
- NOTE: on the real Arch host, **`archiso 88-1` and `arch-install-scripts 31-1`
  are ALREADY installed**. The Kiro VM (see below) likely does NOT have archiso
  yet — install it there with `pacman` before testing.

## Distro scope and Kiro specifics

Targets: plain **Arch**, **CachyOS**, **Kiro** — all handled uniformly by the
clone approach. Kiro facts (verified from kiroproject.be, 2026-06-12):

- Repos: standard Arch **+ chaotic-aur + nemesis_repo**, with `SigLevel = Never`
  (unsigned packages).
- Kernels: `linux-cachyos` (default) + `linux-zen` (fallback).
- Installer: Calamares. Bootloader: **systemd-boot (UEFI) / GRUB (BIOS)**, with
  dual-boot autodetect.
- Ships: fish, ArchLinux Tweak Tool (ATT), VS Code, Timeshift, firewalld, zram,
  BBR; desktops **Xfce** and **Ohmychadwm**.

These all reinforce Option B and tell the restore script it must handle BOTH
systemd-boot and GRUB.

## Where to develop and test — the Kiro VirtualBox VM (do NOT risk real systems)

There is a VirtualBox guest named **`Kiro`** on this Arch host that is the ideal
test bed (details in `~/.claude/projects/-/memory/kiro-vm-access.md`):

- A real **Kiro / Arch / CachyOS-kernel 7.0.11** install (Calamares, EFI),
  16 GiB RAM, 8 vCPU, **~76 GiB free** ext4 root — enough for an ISO build, but
  watch the 2–3× work-dir rule.
- Reach it from this host with **`ssh kiro`** (passwordless). In-guest sudo is
  NOPASSWD. Claude Code is installed AND authenticated inside the guest, and
  `shellcheck` + `shfmt` are present for linting.
- **Snapshots exist** — current start point `dev-ready-full`. Take a fresh
  snapshot before destructive testing; roll back from the host with
  `VBoxManage snapshot Kiro restore <name>` after power-off.
- **Plan:** build the script and run a FULL create-an-ISO → restore-to-a-blank-
  disk cycle entirely inside the VM (add a second virtual disk as the restore
  target). Never test the destructive restore on the real machine.
- **AVX-512 build rule** (only matters if we compile anything natively in the
  VM): use `-march=x86-64-v3`, never `-march=native` (guest CPUID masks AVX-512
  → SIGILL). `mkarchiso` itself does not compile, so this is a minor caveat.

## Coding standards for the script (the user's rules)

- `#!/usr/bin/env bash` + `set -euo pipefail`; quote every variable; prefer
  idempotent forms (`mkdir -p`); **one command per line**; comment the *why*
  (and the *what*, since this is teaching material for the board).
- **No untested commands.** Author + `shellcheck`/`shfmt` here, then validate the
  real `mkarchiso` run inside the Kiro VM. The Mint session could only
  statically check it — it cannot run `mkarchiso` (Debian, no pacman).

## Open questions for the next session

1. SquashFS compression: `zstd` at what level (size vs build time)?
2. Emit a checksum + a verify step (like MX Snapshot's `.md5`)?
3. Output ISO naming/versioning (datetime stamp, basename).
4. Single monolithic script vs a small set of files (build script + exclude list
   + restore script template). Leaning: one build script that *writes out* the
   restore script into the ISO, plus an editable exclude list.
5. Offer LUKS on restore if the source is encrypted? (v1 or v2?)

## Immediate next steps when you pick this up on Arch

1. Confirm the user is ready, and confirm/adjust the open questions above.
2. `ssh kiro`, snapshot the VM, install `archiso` + deps in the guest.
3. Draft the build script per the standards; `shellcheck` it.
4. Do a first end-to-end create → restore cycle in the VM against a scratch disk.
