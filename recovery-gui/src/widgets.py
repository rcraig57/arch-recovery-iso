"""Small reusable widgets: page titles, a disk picker, and path chooser rows."""

import disks
from gi.repository import GLib, Gtk


def make_title(text: str) -> Gtk.Label:
    label = Gtk.Label(xalign=0)
    label.set_name("title")
    label.set_text(text)
    return label


def make_intro(text: str) -> Gtk.Label:
    label = Gtk.Label(xalign=0)
    label.set_wrap(True)
    label.set_markup(text)
    label.set_margin_bottom(6)
    return label


class DiskPicker(Gtk.Box):
    """Label + dropdown of whole disks + a refresh button.

    include_mounted=False hides disks with a mounted partition (the running
    system); the backend scripts refuse those anyway.
    """

    def __init__(self, label_text: str, include_mounted: bool = False):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.include_mounted = include_mounted
        self._disks = []

        label = Gtk.Label(xalign=0, label=label_text)
        label.set_size_request(110, -1)
        self.append(label)

        self.model = Gtk.StringList()
        self.dropdown = Gtk.DropDown(model=self.model)
        self.dropdown.set_hexpand(True)
        self.append(self.dropdown)

        refresh = Gtk.Button()
        refresh.set_icon_name("view-refresh-symbolic")
        refresh.set_tooltip_text("Rescan disks")
        refresh.connect("clicked", lambda _b: self.refresh())
        self.append(refresh)

        self.refresh()

    def refresh(self):
        self._disks = disks.list_disks(include_mounted=self.include_mounted)
        # Rebuild the string model.
        while self.model.get_n_items() > 0:
            self.model.remove(0)
        if not self._disks:
            self.model.append("(no eligible disks found)")
            self.dropdown.set_sensitive(False)
            return
        self.dropdown.set_sensitive(True)
        for disk in self._disks:
            self.model.append(disks.describe(disk))

    def get_selected(self):
        """Return the selected disk dict, or None."""
        if not self._disks:
            return None
        idx = self.dropdown.get_selected()
        if idx == Gtk.INVALID_LIST_POSITION or idx >= len(self._disks):
            return None
        return self._disks[idx]


class PathChooser(Gtk.Box):
    """Label + entry + Browse button. mode is 'folder' or 'file'."""

    def __init__(self, label_text: str, mode: str = "folder", placeholder: str = ""):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.mode = mode

        label = Gtk.Label(xalign=0, label=label_text)
        label.set_size_request(110, -1)
        self.append(label)

        self.entry = Gtk.Entry()
        self.entry.set_hexpand(True)
        if placeholder:
            self.entry.set_placeholder_text(placeholder)
        self.append(self.entry)

        browse = Gtk.Button(label="Browse…")
        browse.connect("clicked", self._on_browse)
        self.append(browse)

    def get_path(self) -> str:
        return self.entry.get_text().strip()

    def set_path(self, path: str):
        self.entry.set_text(path)

    def _on_browse(self, _button):
        dialog = Gtk.FileDialog()
        dialog.set_title("Select a folder" if self.mode == "folder" else "Select a file")
        window = self.get_root()
        if self.mode == "folder":
            dialog.select_folder(window, None, self._on_folder_chosen)
        else:
            dialog.open(window, None, self._on_file_chosen)

    def _on_folder_chosen(self, dialog, result):
        try:
            folder = dialog.select_folder_finish(result)
        except GLib.Error:
            return
        if folder:
            self.entry.set_text(folder.get_path())

    def _on_file_chosen(self, dialog, result):
        try:
            gfile = dialog.open_finish(result)
        except GLib.Error:
            return
        if gfile:
            self.entry.set_text(gfile.get_path())
