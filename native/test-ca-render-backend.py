#!/usr/bin/env python3
"""Exercise backup/restore using disposable preference domains, never Dock's domain."""

import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import uuid


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: test-ca-render-backend.py /absolute/path/to/built/helper")
    binary = pathlib.Path(sys.argv[1]).resolve()
    key = "CAEnableMetalWhippet"
    domain = "org.launchpadrestore.test." + uuid.uuid4().hex
    other_domain = "org.launchpadrestore.test." + uuid.uuid4().hex

    def call(*arguments, domain_name=domain, success=True):
        result = subprocess.run(
            [str(binary), "--domain", domain_name, *map(str, arguments)],
            text=True, capture_output=True,
        )
        if success:
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)
        assert result.returncode != 0, result.stdout
        return result

    def defaults(*arguments, host=False):
        return subprocess.run(
            ["/usr/bin/defaults", *(["-currentHost"] if host else []), *arguments],
            check=True, text=True, capture_output=True,
        )

    def clear():
        for host in (False, True):
            subprocess.run(
                ["/usr/bin/defaults", *(["-currentHost"] if host else []), "delete", domain],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )

    try:
        with tempfile.TemporaryDirectory(prefix="launchpadrestore-backend-test-") as directory:
            parent = pathlib.Path(directory) / "private"
            state = parent / "backend.plist"

            # First installation: absent values stay absent after rollback.
            original = call("--status")
            assert original["effective"] is None
            assert all(not x["present"] for x in original["scopes"].values())
            applied = call("--apply", state)
            assert applied["backupCreated"] is True
            assert applied["effective"] is False
            assert all(x == {"present": True, "value": False} for x in applied["scopes"].values())
            assert parent.stat().st_mode & 0o777 == 0o700
            assert state.stat().st_mode & 0o777 == 0o600
            saved = state.read_bytes()
            record = plistlib.loads(saved)
            assert record["uid"] == os.getuid()
            assert record["app"] == domain
            assert record["key"] == key and record["version"] == 1
            assert record["anyHost"] == record["currentHost"] == {"present": False}
            repeated = call("--apply", state)
            assert repeated["backupCreated"] is False
            assert state.read_bytes() == saved

            # A different domain must not reuse or overwrite this backup.
            call("--apply", state, domain_name=other_domain, success=False)
            assert state.read_bytes() == saved
            assert call("--status", domain_name=other_domain)["effective"] is None

            restored = call("--restore", state)
            assert restored["restored"] is True
            assert restored["scopes"] == original["scopes"]
            assert not state.exists()
            assert call("--restore", state)["reason"] == "no_backup"

            # Preserve true AnyHost plus a non-boolean CurrentHost exactly.
            defaults("write", domain, key, "-bool", "true")
            defaults("write", domain, key, "-string", "original-host-value", host=True)
            original = call("--status")
            assert original["scopes"]["anyHost"]["value"] is True
            assert original["scopes"]["currentHost"]["value"] == "original-host-value"
            call("--apply", state)
            record = plistlib.loads(state.read_bytes())
            assert record["anyHost"] == {"present": True, "value": True}
            assert record["currentHost"] == {"present": True, "value": "original-host-value"}
            assert call("--restore", state)["scopes"] == original["scopes"]
            assert not state.exists()

            # Also preserve false AnyHost plus true CurrentHost, without deleting false.
            defaults("write", domain, key, "-bool", "false")
            defaults("write", domain, key, "-bool", "true", host=True)
            original = call("--status")
            call("--apply", state)
            assert call("--restore", state)["scopes"] == original["scopes"]

            # A failed reinstallation rolls back its entry state without losing
            # the long-term backup from the original successful installation.
            longterm = parent / "original-install.plist"
            attempt = parent / "reinstall-attempt.plist"
            initial = call("--status")
            call("--apply", longterm)
            longterm_saved = longterm.read_bytes()
            defaults("write", domain, key, "-bool", "true")
            defaults("write", domain, key, "-string", "reinstall-entry-host-value", host=True)
            entry = call("--status")
            assert entry["scopes"] != initial["scopes"]
            call("--apply", attempt)
            attempt_record = plistlib.loads(attempt.read_bytes())
            assert attempt_record["anyHost"] == {"present": True, "value": True}
            assert attempt_record["currentHost"] == {
                "present": True, "value": "reinstall-entry-host-value"
            }
            repeated = call("--apply", longterm)
            assert repeated["backupCreated"] is False
            assert longterm.read_bytes() == longterm_saved
            assert call("--restore", attempt)["scopes"] == entry["scopes"]
            assert not attempt.exists()
            assert longterm.read_bytes() == longterm_saved
            assert call("--restore", longterm)["scopes"] == initial["scopes"]
            assert not longterm.exists()
            original = initial

            # Reject an insecure state directory before changing preferences.
            parent.chmod(0o755)
            call("--apply", state, success=False)
            assert call("--status")["scopes"] == original["scopes"]
            assert not state.exists()
            parent.chmod(0o700)

            # Reject a symlink state file; leave its destination untouched.
            destination = parent / "untouched"
            destination.write_text("untouched")
            state.symlink_to(destination)
            call("--apply", state, success=False)
            assert destination.read_text() == "untouched"
            assert call("--status")["scopes"] == original["scopes"]
            state.unlink()

        print("PASS: apply, repeated apply, scope presence/types, restore, no-op restore, reinstall failure rollback, domain isolation, permissions, symlink rejection")
    finally:
        clear()


if __name__ == "__main__":
    main()
