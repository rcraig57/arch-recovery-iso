"""Restore page — write a backup folder back onto a target disk.

This ERASES the chosen disk. Two independent guards stand in front of the run:
the user must type ERASE to enable the button, AND confirm a final dialog naming
the exact target. The backend additionally refuses mounted disks / the backup's
own disk and verifies every image checksum before writing.
"""

import os

import config
from gi.repository import Gtk
from jobview import JobView
from widgets import DiskPicker, PathChooser, make_intro, make_title

INTRO = (
    "Restore a backup folder (made on the Backup page) onto a target disk. "
    "<b>This erases the target disk completely.</b> Every image checksum is "
    "verified before anything is written. UUIDs are preserved, so the restored "
    "system's fstab and bootloader already match."
)


class RestorePage(Gtk.Box):
    def __init__(self):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.set_margin_top(18)
        self.set_margin_bottom(18)
        self.set_margin_start(18)
        self.set_margin_end(18)

        self.append(make_title("Restore"))
        self.append(make_intro(INTRO))

        self.backup = PathChooser(
            "Backup folder:", mode="folder",
            placeholder="the …-img-YYYYMMDD-HHMMSS folder to restore from",
        )
        self.append(self.backup)

        self.target = DiskPicker("Target disk:", include_mounted=False)
        self.append(self.target)

        # Optional behavior toggles.
        self.grow = Gtk.CheckButton(
            label="Grow the last partition to fill a larger target disk"
        )
        self.grow.set_active(True)
        self.append(self.grow)

        self.bootloader = Gtk.CheckButton(
            label="Re-register the bootloader (only needed when restoring to a different machine)"
        )
        self.bootloader.connect("toggled", self._on_bootloader_toggled)
        self.append(self.bootloader)

        self.dryrun = Gtk.CheckButton(
            label="Dry-run the bootloader step (detect and print the command, don't run it)"
        )
        self.dryrun.set_margin_start(28)
        self.dryrun.set_sensitive(False)
        self.append(self.dryrun)

        # ERASE confirmation row.
        erase_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        erase_row.append(Gtk.Label(xalign=0, label="Type ERASE to enable:"))
        self.erase_entry = Gtk.Entry()
        self.erase_entry.set_placeholder_text("ERASE")
        self.erase_entry.connect("changed", lambda _e: self._update_start_sensitive())
        erase_row.append(self.erase_entry)
        self.append(erase_row)

        # Action buttons.
        buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        buttons.set_halign(Gtk.Align.START)
        self.start_btn = Gtk.Button(label="Restore (erase target)")
        self.start_btn.add_css_class("destructive-action")
        self.start_btn.set_sensitive(False)
        self.start_btn.connect("clicked", self._on_start)
        self.cancel_btn = Gtk.Button(label="Cancel")
        self.cancel_btn.set_sensitive(False)
        self.cancel_btn.connect("clicked", self._on_cancel)
        buttons.append(self.start_btn)
        buttons.append(self.cancel_btn)
        self.append(buttons)

        self.error_label = Gtk.Label(xalign=0)
        self.error_label.set_name("error_label")
        self.error_label.set_wrap(True)
        self.append(self.error_label)

        self.job = JobView()
        self.job.set_vexpand(True)
        self.append(self.job)

    # -- ui state ----------------------------------------------------------- #
    def _on_bootloader_toggled(self, _btn):
        self.dryrun.set_sensitive(self.bootloader.get_active())
        if not self.bootloader.get_active():
            self.dryrun.set_active(False)

    def _update_start_sensitive(self):
        ready = self.erase_entry.get_text() == "ERASE"
        self.start_btn.set_sensitive(ready)

    def _set_inputs_sensitive(self, sensitive: bool):
        for widget in (
            self.backup, self.target, self.grow, self.bootloader,
            self.dryrun, self.erase_entry,
        ):
            widget.set_sensitive(sensitive)
        # dryrun stays gated on the bootloader checkbox
        if sensitive:
            self.dryrun.set_sensitive(self.bootloader.get_active())
            self._update_start_sensitive()
        else:
            self.start_btn.set_sensitive(False)
        self.cancel_btn.set_sensitive(not sensitive)

    def _error(self, text: str):
        self.error_label.set_text(text)

    # -- actions ------------------------------------------------------------ #
    def _on_start(self, _button):
        self._error("")
        backup_dir = self.backup.get_path()
        disk = self.target.get_selected()
        if not backup_dir or not os.path.isdir(backup_dir):
            self._error("Choose a valid backup folder.")
            return
        if not os.path.isfile(os.path.join(backup_dir, "backup-metadata.conf")):
            self._error("That folder is not a backup (no backup-metadata.conf).")
            return
        if disk is None:
            self._error("Pick a target disk.")
            return

        # Final confirm dialog naming the exact disk.
        dialog = Gtk.AlertDialog()
        dialog.set_modal(True)
        dialog.set_message(f"Erase {disk['path']} and restore?")
        dialog.set_detail(
            f"{disk['path']} — {disk['model']}\n\n"
            "Everything on this disk will be destroyed and replaced from the "
            "backup. This cannot be undone."
        )
        dialog.set_buttons(["Cancel", "Erase and restore"])
        dialog.set_default_button(0)
        dialog.set_cancel_button(0)
        dialog.choose(self.get_root(), None, self._on_confirm, (backup_dir, disk))

    def _on_confirm(self, dialog, result, data):
        try:
            choice = dialog.choose_finish(result)
        except Exception:
            return
        if choice != 1:  # not "Erase and restore"
            return
        backup_dir, disk = data
        self._launch(backup_dir, disk)

    def _launch(self, backup_dir, disk):
        argv = []
        if self.bootloader.get_active() and self.dryrun.get_active():
            argv += ["env", "BOOTLOADER_DRYRUN=1"]
        argv += [str(config.restore_script()), "--erase", "--no-reboot"]
        argv.append("--grow" if self.grow.get_active() else "--no-grow")
        argv.append("--bootloader" if self.bootloader.get_active() else "--no-bootloader")
        argv += [backup_dir, disk["path"]]

        # Reset the gate so a second run needs ERASE typed again.
        self.erase_entry.set_text("")
        self._set_inputs_sensitive(False)
        self.job.run(argv, on_finished=lambda _rc: self._set_inputs_sensitive(True))

    def _on_cancel(self, _button):
        self.job.cancel()
