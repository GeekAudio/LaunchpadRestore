#!/usr/bin/env python3
"""Import the old Dock Launchpad order and folders into standalone Lunchpad.

The native Dock database is opened read-only. The standalone database is created
only when it does not already exist, unless --force explicitly requests a backup
and replacement. Lunchpad must be closed while importing.
"""

from __future__ import annotations

import argparse
from contextlib import closing
import datetime as dt
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile


TARGET = Path.home() / "Library/Application Support/com.arichyx.Lunchpad/layout.sqlite3"


def native_database() -> Path:
    user_dir = subprocess.check_output(["getconf", "DARWIN_USER_DIR"], text=True).strip()
    return Path(user_dir) / "com.apple.dock.launchpad/db/db"


def readonly(path: Path) -> sqlite3.Connection:
    return sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)


def ordered_children(db: sqlite3.Connection, parent: int) -> list[tuple[int, str, int]]:
    return db.execute(
        "SELECT rowid, COALESCE(uuid, ''), type FROM items "
        "WHERE parent_id = ? ORDER BY ordering, rowid",
        (parent,),
    ).fetchall()


def visible_children(db: sqlite3.Connection, parent: int) -> list[tuple[int, str, int]]:
    result: list[tuple[int, str, int]] = []
    for item_id, uuid, kind in ordered_children(db, parent):
        if kind == 3:  # page, including pages inside a folder
            if uuid.startswith("HOLDINGPAGE"):
                continue
            result.extend(visible_children(db, item_id))
        elif kind in (2, 4, 5):  # folder or app
            result.append((item_id, uuid, kind))
    return result


def read_layout(db: sqlite3.Connection) -> tuple[list[tuple], list[tuple]]:
    root = db.execute(
        "SELECT rowid FROM items WHERE uuid = 'ROOTPAGE' AND type = 1 LIMIT 1"
    ).fetchone()
    if root is None:
        raise ValueError("Native Launchpad root page was not found")

    folders: list[tuple] = []
    applications: list[tuple] = []
    seen_apps: set[str] = set()
    now = dt.datetime.now(dt.timezone.utc).timestamp()

    def add_app(item_id: int, folder_id: str | None, position: int) -> None:
        row = db.execute(
            "SELECT title, bundleid FROM apps WHERE item_id = ?", (item_id,)
        ).fetchone()
        if not row or not row[1]:
            return
        title, bundle_id = row
        identifier = "bundle:" + bundle_id.lower()
        if identifier in seen_apps:
            return
        seen_apps.add(identifier)
        applications.append(
            (
                identifier,
                bundle_id,
                title or bundle_id,
                "",  # The app scanner resolves the current path on first launch.
                folder_id,
                position,
                "user" if folder_id else "none",
                0,  # The app scanner marks present apps after discovering them.
                now,
                now,
            )
        )

    for position, (item_id, uuid, kind) in enumerate(visible_children(db, root[0])):
        if kind in (4, 5):
            add_app(item_id, None, position)
            continue
        folder = db.execute(
            "SELECT title FROM groups WHERE item_id = ?", (item_id,)
        ).fetchone()
        folder_name = (folder[0] if folder else "") or "文件夹"
        # Keep the native default Other folder as Lunchpad's default folder so
        # newly discovered apps join it instead of creating a second one.
        is_other = folder_name in {"其他", "Other"} and not any(
            entry[0] == "system.other" for entry in folders
        )
        folder_id = "system.other" if is_other else "native." + (uuid or str(item_id))
        folders.append(
            (
                folder_id,
                "other" if is_other else None,
                folder_name,
                position,
                now,
                int(is_other),
                int(is_other),
            )
        )
        for member_position, (member_id, _, member_kind) in enumerate(visible_children(db, item_id)):
            if member_kind in (4, 5):
                add_app(member_id, folder_id, member_position)

    return folders, applications


def create_database(path: Path, folders: list[tuple], apps: list[tuple]) -> None:
    with sqlite3.connect(path) as db:
        db.executescript(
            """
            PRAGMA foreign_keys = ON;
            CREATE TABLE folders(
                id TEXT PRIMARY KEY,
                system_key TEXT UNIQUE,
                name TEXT NOT NULL,
                sort_position INTEGER NOT NULL,
                created_at REAL NOT NULL,
                is_system INTEGER NOT NULL DEFAULT 0,
                is_default INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE applications(
                id TEXT PRIMARY KEY,
                bundle_identifier TEXT,
                display_name TEXT NOT NULL,
                path TEXT NOT NULL,
                folder_id TEXT REFERENCES folders(id) ON DELETE SET NULL,
                sort_position INTEGER NOT NULL,
                assignment_source TEXT NOT NULL DEFAULT 'none'
                    CHECK(assignment_source IN ('none', 'default', 'user')),
                is_present INTEGER NOT NULL DEFAULT 1,
                first_seen_at REAL NOT NULL,
                last_seen_at REAL NOT NULL
            );
            CREATE INDEX applications_folder_position
                ON applications(folder_id, sort_position);
            PRAGMA user_version = 1;
            """
        )
        db.executemany(
            "INSERT INTO folders VALUES (?, ?, ?, ?, ?, ?, ?)", folders
        )
        db.executemany(
            "INSERT INTO applications VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", apps
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native-db", type=Path, default=native_database())
    parser.add_argument("--target", type=Path, default=TARGET)
    parser.add_argument("--force", action="store_true", help="Back up and replace an existing standalone layout")
    parser.add_argument("--dry-run", action="store_true", help="Show counts without writing")
    args = parser.parse_args()

    if not args.native_db.is_file():
        parser.error(f"Native Launchpad database not found: {args.native_db}")
    with closing(readonly(args.native_db)) as source:
        source.execute("BEGIN")
        folders, apps = read_layout(source)
    print(f"读取原生布局：{len(apps)} 个应用，{len(folders)} 个文件夹")
    if not apps:
        parser.error("No apps found; refusing to create an empty layout")
    if args.dry_run:
        return 0
    if subprocess.run(["pgrep", "-x", "Lunchpad"], capture_output=True, check=False).returncode == 0:
        parser.error("Please quit Lunchpad before importing")

    target: Path = args.target.expanduser()
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        if not args.force:
            parser.error(f"Target already exists: {target} (use --force to back it up and replace it)")
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        backup = target.with_name(f"layout-backup-{stamp}.sqlite3")
        with sqlite3.connect(target) as existing, sqlite3.connect(backup) as saved:
            existing.backup(saved)
        print(f"已备份现有独立布局：{backup}")

    fd, temp_name = tempfile.mkstemp(prefix=".layout-import-", suffix=".sqlite3", dir=target.parent)
    os.close(fd)
    temp = Path(temp_name)
    try:
        create_database(temp, folders, apps)
        os.replace(temp, target)
        for suffix in ("-wal", "-shm"):
            target.with_name(target.name + suffix).unlink(missing_ok=True)
    finally:
        temp.unlink(missing_ok=True)
    print(f"已导入独立启动台布局：{target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
