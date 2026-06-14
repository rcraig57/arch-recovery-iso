"""Disk enumeration helpers — thin wrappers over lsblk.

Used to populate the source/target disk pickers. The authoritative safety
checks (refuse-if-mounted, refuse the backup's own disk, size check) still live
in the backend scripts; this module only decides what to OFFER in the UI.
"""

import json
import subprocess


def _run(cmd) -> str:
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, check=False
        ).stdout
    except OSError:
        return ""


def human_size(num_bytes: int) -> str:
    """Format a byte count as IEC units (matches the scripts' numfmt --to=iec)."""
    value = float(num_bytes)
    for unit in ("B", "K", "M", "G", "T", "P"):
        if value < 1024 or unit == "P":
            if unit == "B":
                return f"{int(value)}{unit}"
            return f"{value:.1f}{unit}".replace(".0", "")
        value /= 1024
    return f"{num_bytes}B"


def disk_has_mount(name: str) -> bool:
    """True if any partition of /dev/<name> is currently mounted."""
    out = _run(["lsblk", "-nro", "MOUNTPOINTS", f"/dev/{name}"])
    return any(line.strip() for line in out.splitlines())


def list_disks(include_mounted: bool = False) -> list:
    """Return whole disks as dicts: name, path, size (bytes), model, mounted.

    Mounted disks are excluded by default (they're almost certainly the running
    system and the scripts will refuse them anyway).
    """
    out = _run(["lsblk", "-J", "-d", "-b", "-o", "NAME,SIZE,MODEL,TYPE,RM"])
    try:
        data = json.loads(out) if out else {}
    except json.JSONDecodeError:
        data = {}

    disks = []
    for dev in data.get("blockdevices", []):
        if dev.get("type") != "disk":
            continue
        name = dev["name"]
        mounted = disk_has_mount(name)
        if mounted and not include_mounted:
            continue
        disks.append(
            {
                "name": name,
                "path": f"/dev/{name}",
                "size": int(dev.get("size") or 0),
                "model": (dev.get("model") or "").strip() or "unknown",
                "mounted": mounted,
                "removable": bool(dev.get("rm")),
            }
        )
    return disks


def describe(disk: dict) -> str:
    """One-line label for a disk picker row."""
    return f"{disk['path']}  —  {human_size(disk['size'])}  {disk['model']}"
