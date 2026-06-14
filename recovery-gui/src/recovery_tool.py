#!/usr/bin/env python3
"""Disk Recovery Tool — GTK4 front end for the partclone backup/restore scripts.

Run via the `recovery-tool` launcher, which elevates the whole app through
pkexec/polkit (partclone/losetup/mount all need root). Running it directly as a
normal user is fine for previewing the UI, but the actual operations will fail.
"""

import os
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, Gtk  # noqa: E402

import config  # noqa: E402
from about_page import AboutPage  # noqa: E402
from backup_page import BackupPage  # noqa: E402
from restore_page import RestorePage  # noqa: E402


class RecoveryWindow(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app)
        self.set_title(config.APP_NAME)
        self.set_default_size(1100, 920)

        self.set_icon_name(config.ICON_NAME)

        header = Gtk.HeaderBar()
        self.set_titlebar(header)

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.set_child(root)

        # Warn (non-fatally) if we aren't root — operations would fail.
        if os.geteuid() != 0:
            warn = Gtk.Label(xalign=0)
            warn.set_name("error_label")
            warn.set_wrap(True)
            warn.set_margin_top(8)
            warn.set_margin_start(12)
            warn.set_margin_end(12)
            warn.set_text(
                "Not running as root — disk operations will fail. "
                "Launch with the 'recovery-tool' command to elevate via polkit."
            )
            root.append(warn)

        body = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        body.set_vexpand(True)
        root.append(body)

        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.SLIDE_LEFT)
        self.stack.set_hexpand(True)
        self.stack.set_vexpand(True)

        sidebar = Gtk.StackSidebar()
        sidebar.set_stack(self.stack)
        sidebar.set_name("sidebar")
        sidebar.set_size_request(180, -1)
        body.append(sidebar)
        body.append(Gtk.Separator(orientation=Gtk.Orientation.VERTICAL))

        body.append(self.stack)

        self.stack.add_titled(BackupPage(), "backup", "Backup")
        self.stack.add_titled(RestorePage(), "restore", "Restore")
        self.stack.add_titled(AboutPage(), "about", "About")


class RecoveryApp(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=config.APP_ID)

    def do_activate(self):
        self._register_icons()
        self._load_css()
        win = self.get_active_window() or RecoveryWindow(self)
        win.present()

    def _register_icons(self):
        display = Gdk.Display.get_default()
        if display is None:
            return
        theme = Gtk.IconTheme.get_for_display(display)
        theme.add_search_path(str(config.icons_dir()))

    def _load_css(self):
        display = Gdk.Display.get_default()
        if display is None:
            return
        provider = Gtk.CssProvider()
        try:
            provider.load_from_string(config.style_path().read_text())
        except (OSError, AttributeError):
            # Older GTK without load_from_string: fall back to load_from_path.
            provider.load_from_path(str(config.style_path()))
        Gtk.StyleContext.add_provider_for_display(
            display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )


def main():
    app = RecoveryApp()
    return app.run(sys.argv)


if __name__ == "__main__":
    sys.exit(main())
