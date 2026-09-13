# Lensfun lens database

Copied from https://github.com/lensfun/lensfun, directory `data/db`.

- Commit: 12f5976ce30c024f98c420835125b9676ac07811
- Date: 2026-09-11

License: CC-BY-SA 3.0 (the database), see the Lensfun project. rawhead ships
the data files unchanged and reads them with its own parser (LensKit); the
Lensfun library itself is not used, so no C dependency or glib is needed.

Edits record this date as their `lensfunDb` version (DESIGN.md 5.6), so a
later database update can never silently change an existing edit.

To update: re-copy `data/db/*.xml` and change the two lines above.
