"""Backup page — image a whole disk to a folder of compressed partclone images."""

import os

import config
from gi.repository import Gtk
from jobview import JobView
from widgets import DiskPicker, PathChooser, make_intro, make_title

INTRO = (
    "Create a complete, used-blocks-only image of a whole disk. Each filesystem "
    "is imaged with <b>partclone</b> and compressed with <b>zstd</b>; btrfs "
    "snapshots and subvolumes come along automatically. The source disk must "
    "<b>not</b> be mounted (don't image the disk you booted from)."
)


class BackupPage(Gtk.Box):
    def __init__(self):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.set_margin_top(18)
        self.set_margin_bottom(18)
        self.set_margin_start(18)
        self.set_margin_end(18)

        self.append(make_title("Backup"))
        self.append(make_intro(INTRO))

        self.source = DiskPicker("Source disk:", include_mounted=False)
        self.append(self.source)

        self.dest = PathChooser(
            "Save to folder:", mode="folder",
            placeholder="e.g. /mnt/storage  (a timestamped subfolder is created)",
        )
        self.append(self.dest)

        # zstd level + force option on one row.
        opts = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        opts.append(Gtk.Label(xalign=0, label="Compression (zstd):"))
        self.zstd = Gtk.SpinButton.new_with_range(1, 19, 1)
        self.zstd.set_value(3)
        self.zstd.set_tooltip_text("1 = fastest/biggest … 19 = slow/smallest. Default 3.")
        opts.append(self.zstd)
        self.force = Gtk.CheckButton(label="Proceed even if the estimate exceeds free space")
        self.force.set_margin_start(20)
        opts.append(self.force)
        self.append(opts)

        # Action buttons.
        buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        buttons.set_halign(Gtk.Align.START)
        self.start_btn = Gtk.Button(label="Start backup")
        self.start_btn.add_css_class("suggested-action")
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

    # -- helpers ------------------------------------------------------------ #
    def _set_inputs_sensitive(self, sensitive: bool):
        for widget in (self.source, self.dest, self.zstd, self.force, self.start_btn):
            widget.set_sensitive(sensitive)
        self.cancel_btn.set_sensitive(not sensitive)

    def _error(self, text: str):
        self.error_label.set_text(text)

    # -- actions ------------------------------------------------------------ #
    def _on_start(self, _button):
        self._error("")
        disk = self.source.get_selected()
        dest = self.dest.get_path()
        if disk is None:
            self._error("Pick a source disk.")
            return
        if not dest:
            self._error("Choose a destination folder.")
            return
        if not os.path.isdir(dest):
            self._error(f"Destination folder does not exist: {dest}")
            return

        level = int(self.zstd.get_value())
        argv = ["env", f"ZSTD_LEVEL={level}", str(config.backup_script()), "--yes"]
        if self.force.get_active():
            argv.append("--force")
        argv += [disk["path"], dest]

        self._set_inputs_sensitive(False)
        self.job.run(argv, on_finished=lambda _rc: self._set_inputs_sensitive(True))

    def _on_cancel(self, _button):
        self.job.cancel()
