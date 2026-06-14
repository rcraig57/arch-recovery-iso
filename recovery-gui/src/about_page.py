"""About / Help page."""

import config
from gi.repository import Gtk
from widgets import make_intro, make_title

ABOUT = (
    f"<b>{config.APP_NAME}</b>  v{config.APP_VERSION}\n\n"
    "A graphical front end for whole-disk backup and restore built on "
    "<b>partclone</b> + <b>zstd</b>. It is a thin wrapper: every operation runs "
    "the same audited shell scripts you can run from a terminal, so the GUI and "
    "CLI can never drift apart.\n\n"
    "<b>What it does</b>\n"
    "• <b>Backup</b> — images only the used blocks of each filesystem, preserving "
    "btrfs snapshots/subvolumes and filesystem UUIDs.\n"
    "• <b>Restore</b> — verifies every image checksum, recreates the partition "
    "table, writes each filesystem back, can grow the last partition onto a "
    "larger disk, and can re-register the bootloader for a different machine.\n\n"
    "<b>Safety</b>\n"
    "• The source disk for a backup must be unmounted.\n"
    "• Restore erases the target; it is guarded by a typed ERASE confirmation and "
    "a final dialog, and the backend refuses mounted disks and verifies checksums "
    "before writing anything.\n\n"
    "Look and feel inspired by Erik Dubois' Arch Linux Tweak Tool."
)


class AboutPage(Gtk.Box):
    def __init__(self):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.set_margin_top(18)
        self.set_margin_bottom(18)
        self.set_margin_start(18)
        self.set_margin_end(18)
        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        icon = Gtk.Image.new_from_file(str(config.icon_file()))
        icon.set_pixel_size(48)
        header.append(icon)
        header.append(make_title("About"))
        header.set_valign(Gtk.Align.CENTER)
        self.append(header)

        intro = make_intro(ABOUT)
        intro.set_vexpand(True)
        intro.set_valign(Gtk.Align.START)
        self.append(intro)

        info = Gtk.Label(xalign=0)
        info.set_wrap(True)
        info.set_markup(f"<small>Backend scripts: <tt>{config.backend_dir()}</tt></small>")
        self.append(info)
