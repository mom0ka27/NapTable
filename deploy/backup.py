#!/usr/bin/env python3
"""Create a consistent SQLite backup and retain the latest 14 snapshots."""

from datetime import datetime, timezone
from pathlib import Path
import sqlite3


SOURCE = Path("/var/lib/naptable/naptable.sqlite3")
BACKUP_DIR = Path("/var/backups/naptable")
RETAIN = 14


def main():
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    destination = BACKUP_DIR / f"naptable-{stamp}.sqlite3"
    with sqlite3.connect(f"file:{SOURCE}?mode=ro", uri=True) as source:
        with sqlite3.connect(destination) as target:
            source.backup(target)
    destination.chmod(0o600)

    snapshots = sorted(BACKUP_DIR.glob("naptable-*.sqlite3"), reverse=True)
    for old_snapshot in snapshots[RETAIN:]:
        old_snapshot.unlink()


if __name__ == "__main__":
    main()
