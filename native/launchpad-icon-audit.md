# Readonly Launchpad icon audit

Build and run as the desktop user:

```sh
xcrun clang -fobjc-arc -Wall -Wextra -framework Foundation -framework CoreGraphics -framework ImageIO -lsqlite3 native/launchpad-icon-audit.m -o /tmp/launchpad-icon-audit
/tmp/launchpad-icon-audit
```

The default database is obtained from `/usr/bin/getconf DARWIN_USER_DIR`, followed
by `com.apple.dock.launchpad/db/db`. It does not search other users' caches and
refuses default lookup as root. `--db PATH` selects an explicit database, including
a temporary test fixture. SQLite uses `SQLITE_OPEN_READONLY` and one read
transaction. The tool does not change preferences, write icons, or restart Dock.

JSON `counts` covers all app/cache rows and both large/mini images. `entries`
contains only affected rows unless `--all` is used. Each image reports byte length,
decoded width/height, `alphaNonzeroCount`, `maxAlpha` (0–1), and a status:

- `ok`: at least one decoded pixel has nonzero alpha.
- `missing`: there is no cache row or the image blob is NULL/empty.
- `undecodable`: ImageIO cannot decode it, dimensions exceed the bounded audit
  limit (4096 pixels per axis), or the software bitmap cannot be allocated.
- `transparent`: the decoded image has no visible alpha at any pixel.

ImageIO decodes the cache data into a caller-owned floating-point bitmap context.
This preserves very low alpha in 16-bit PNGs and avoids guesses based on compressed
file size. An `ok` result establishes alpha coverage only; it cannot establish
that the correct app artwork was cached or that Dock refreshed its visible layer.
The snapshot describes the cache when the audit ran, so a self-healed boot-time
failure may already be absent.

`python3 native/tests/test-launchpad-icon-audit.py` builds the tool and checks a
temporary SQLite fixture: a small valid PNG, an all-transparent PNG, invalid image
data, a missing cache row, NULL/empty image blobs, and very low 16-bit alpha. It
also checks the database hash is unchanged and a nonexistent path is not created.
