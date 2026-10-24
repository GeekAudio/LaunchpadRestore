#!/usr/bin/env python3
"""Exercise the readonly auditor against a disposable database, never user data."""

import hashlib
import json
from pathlib import Path
import sqlite3
import struct
import subprocess
import sys
import tempfile
import zlib


def png(width, height, alpha, depth=8):
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data)))

    component = "B" if depth == 8 else ">H"
    maximum = (1 << depth) - 1
    pixel = b"".join(struct.pack(component, value)
                     for value in (maximum, 0, 0, alpha))
    scanlines = (b"\0" + pixel * width) * height
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, depth, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(scanlines)) + chunk(b"IEND", b""))


def main():
    source = Path(__file__).resolve().parents[1] / "launchpad-icon-audit.m"
    with tempfile.TemporaryDirectory(prefix="launchpad-icon-audit-") as temporary:
        directory = Path(temporary)
        binary = directory / "audit"
        if len(sys.argv) > 1:
            binary = Path(sys.argv[1]).resolve()
        else:
            subprocess.run(["xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra",
                            "-Werror", "-framework", "Foundation", "-framework",
                            "CoreGraphics", "-framework", "ImageIO", "-lsqlite3",
                            str(source), "-o", str(binary)], check=True)
        database = directory / "fixture.sqlite"
        connection = sqlite3.connect(database)
        connection.executescript("""
            CREATE TABLE apps(item_id INTEGER PRIMARY KEY,title TEXT,bundleid TEXT);
            CREATE TABLE image_cache(item_id INTEGER,size_big INTEGER,
                size_mini INTEGER,image_data BLOB,image_data_mini BLOB);
        """)
        fixtures = [
            ("small-valid", png(3, 3, 255), "ok"),
            ("transparent", png(4, 4, 0), "transparent"),
            ("undecodable", b"not an image", "undecodable"),
            ("missing-row", None, "missing"),
            ("null-and-empty", None, "missing"),
            ("low-alpha-16bit", png(2, 2, 1, 16), "ok"),
        ]
        for item_id, (name, data, _) in enumerate(fixtures, 1):
            connection.execute("INSERT INTO apps VALUES(?,?,?)",
                               (item_id, name, "test." + name))
            if name != "missing-row":
                mini = b"" if name == "null-and-empty" else data
                connection.execute("INSERT INTO image_cache VALUES(?,128,30,?,?)",
                                   (item_id, data, mini))
        connection.commit()
        connection.close()
        before = hashlib.sha256(database.read_bytes()).hexdigest()
        all_entries = json.loads(subprocess.check_output(
            [str(binary), "--db", str(database), "--all"], text=True))
        anomalies = json.loads(subprocess.check_output(
            [str(binary), "--db", str(database)], text=True))
        assert all_entries["readonly"] is True
        assert all_entries["counts"] == {
            "apps": 6, "rows": 6, "cacheEntries": 5, "affectedApps": 4,
            "images": {"ok": 4, "transparent": 2, "undecodable": 2, "missing": 4},
        }, all_entries
        assert len(anomalies["entries"]) == 4
        for entry, (name, _, expected) in zip(all_entries["entries"], fixtures):
            assert entry["title"] == name
            for size in ("big", "mini"):
                assert entry[size]["status"] == expected, entry
        small = all_entries["entries"][0]["big"]
        assert small["byteLength"] < 5000 and small["alphaNonzeroCount"] == 9
        low = all_entries["entries"][-1]["big"]
        assert low["alphaNonzeroCount"] == 4 and 0 < low["maxAlpha"] < 1 / 255
        assert hashlib.sha256(database.read_bytes()).hexdigest() == before
        missing = directory / "does-not-exist.sqlite"
        result = subprocess.run([str(binary), "--db", str(missing)],
                                capture_output=True, text=True)
        assert result.returncode != 0 and not missing.exists()
        print(json.dumps({"fixture": "passed", "counts": all_entries["counts"],
                          "smallValidBytes": small["byteLength"],
                          "lowAlphaMaximum": low["maxAlpha"],
                          "databaseUnchanged": True}, sort_keys=True))


if __name__ == "__main__":
    main()
