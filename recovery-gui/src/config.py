"""Shared paths and constants for the Recovery Tool GUI.

The GUI is a thin front end over the partclone backup/restore scripts. It does
NOT reimplement any disk logic — it builds the right command line and shows the
output. Keeping the scripts authoritative means the CLI and GUI can never drift.
"""

import os
from pathlib import Path

APP_ID = "org.ohmychadwm.recovery"
APP_NAME = "Disk Recovery Tool"
APP_VERSION = "0.1.0"
ICON_NAME = "org.ohmychadwm.recovery"

_HERE = Path(__file__).resolve().parent  # .../recovery-gui/src


def icons_dir() -> Path:
    """Base dir holding hicolor/scalable/apps/<icon>.svg (for the icon theme)."""
    return _HERE.parents[0] / "data" / "icons"


def icon_file() -> Path:
    return icons_dir() / "hicolor" / "scalable" / "apps" / f"{ICON_NAME}.svg"


def backend_dir() -> Path:
    """Locate the directory holding partclone-backup.sh / partclone-restore.sh.

    Order: $RECOVERY_BACKEND_DIR, the dev layout (sibling of recovery-gui), then
    a couple of install locations. Falls back to the first candidate so error
    messages name a sensible path.
    """
    candidates = []
    env = os.environ.get("RECOVERY_BACKEND_DIR")
    if env:
        candidates.append(Path(env))
    candidates.append(_HERE.parents[1] / "part_clone")  # archiso-recovery/part_clone
    candidates.append(Path("/usr/share/recovery-tool/scripts"))
    candidates.append(Path("/usr/lib/recovery-tool"))
    for c in candidates:
        if (c / "partclone-backup.sh").is_file():
            return c
    return candidates[0]


def backup_script() -> Path:
    return backend_dir() / "partclone-backup.sh"


def restore_script() -> Path:
    return backend_dir() / "partclone-restore.sh"


def style_path() -> Path:
    return _HERE / "style.css"
