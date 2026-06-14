# Disk Recovery Tool (GUI)

A GTK4 front end for the partclone-based whole-disk **backup** and **restore**
scripts in `../part_clone/`. Look and feel modelled on Erik Dubois' Arch Linux
Tweak Tool. The GUI is a thin wrapper: every operation runs the same audited
shell scripts you can run from a terminal, so the CLI and GUI never drift.

## Run it

```
./recovery-tool
```

Do **not** run it as root yourself. The launcher elevates the whole app once via
`pkexec` (your desktop's polkit agent prompts for the admin password) — partclone,
losetup and mount all need root.

You can preview the UI as a normal user (`python3 src/recovery_tool.py`), but the
actual backup/restore operations will fail without root.

## Layout

```
recovery-tool                 launcher (pkexec, Wayland/X11)
src/
  recovery_tool.py            main: window, sidebar, stack, CSS
  backup_page.py              Backup page
  restore_page.py             Restore page (ERASE-guarded)
  about_page.py               About / Help
  jobview.py                  progress bar + collapsible log, owns the runner
  runner.py                   subprocess + partclone progress parser
  disks.py                    lsblk disk enumeration
  widgets.py                  disk picker, path chooser, titles
  config.py                   app constants + backend-script discovery
  style.css                   ATT-style theme
data/
  org.ohmychadwm.recovery.policy   polkit policy (for a packaged install)
  recovery-tool.desktop            desktop entry
```

## How it talks to the backend

The GUI calls the scripts with their non-interactive flags so nothing blocks on
a prompt:

- **Backup:** `partclone-backup.sh --yes [--force] SRC DEST` (with `ZSTD_LEVEL`
  in the environment).
- **Restore:** `partclone-restore.sh --erase --no-reboot (--grow|--no-grow)
  (--bootloader|--no-bootloader) BACKUP_DIR TARGET` (with `BOOTLOADER_DRYRUN=1`
  when the dry-run box is ticked).

The backend keeps the real safety checks: it refuses mounted disks and the
backup's own disk, verifies every image checksum before writing, and the restore
script still ERASE-gates unless `--erase` is passed (the GUI passes it only after
its own typed-ERASE + confirmation-dialog guards).
