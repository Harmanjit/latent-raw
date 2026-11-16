# Wiki source

These pages are the GitHub wiki, kept here so they are versioned with the
code. To publish or update the wiki:

1. Once only: on GitHub, open the Wiki tab and create any first page, which
   creates the wiki repository.
2. Then:

```bash
git clone git@github.com:Harmanjit/latent-raw.wiki.git /tmp/latent-wiki
cp docs/wiki/*.md /tmp/latent-wiki/ && rm /tmp/latent-wiki/README.md
cd /tmp/latent-wiki && git add -A && git commit -m "Update wiki" && git push
```

## The same pages in the app

The pages also ship inside the app, in **Help > Latent Help** (HelpKit renders
them; `scripts/make_app.sh` copies them into the bundle, and `swift run` reads
this folder). A few rules keep both places working:

- `_Sidebar.md` sets the order and titles of the pages. Add every new page to
  it; a page it doesn't list still shows, after the listed ones.
- Link between pages with bare page names, `[Export](Export)` or
  `[Library](Library#the-sidebar)`, where the anchor is the heading as GitHub
  spells it. Web and mail links (`https:`, `mailto:`) open in the browser.
  Help refuses any other link, such as a file path.
- This README is publishing notes, not a page, and is left out of both.
- `Keyboard-Shortcuts.md` is generated from `Sources/latent-app/Shortcuts.swift`.
  Edit the table there, then run
  `LATENT_WRITE_SHORTCUTS_PAGE=1 swift test --filter ShortcutsPageTests`.
- `swift test --filter HelpKitTests` checks that every page parses, follows
  the sidebar, and links only to pages and headings that exist.

## Releasing

A release is an ad hoc signed, unnotarised `Latent-<version>.zip` on a
GitHub Release. There is no developer account, so there is no
notarisation step; the install instructions in `Installation.md` explain
Open Anyway instead.

1. Update `CHANGELOG.md` and `Whats-New.md`, and any version named in
   `README.md`, `Home.md` and `Installation.md`. Commit.
2. Run `scripts/make_release.sh <version>` on a clean checkout of that
   commit. It builds with `make_app.sh`, checks the bundle with
   `check_app_bundle.sh --version <version>`, zips it with `ditto` into
   `build/Latent-<version>.zip`, checks the unzipped copy's signature and
   prints the SHA-256. It publishes nothing and creates no tag.
3. Upgrade test, on a clean Mac (or a fresh macOS user account) running
   macOS 15, and again on 26 if one is at hand:
   - Install the previous release's zip (for 1.0.0, `Latent-0.9.0.zip`
     from the Releases page), get past Gatekeeper with Open Anyway, and
     open a folder of raws with Open Folder…; add a sidebar favourite, rate
     and edit a photo, and save a preset.
   - Quit, then replace `/Applications/Latent.app` with the new build from
     the zip (copied over as a download would arrive, so it is quarantined
     and Open Anyway is needed again).
   - Open it and confirm that the last folder and the favourite still open
     without asking (their bookmarks resolve), the edit, rating and preset
     are still there (the container under
     `~/Library/Containers/com.latent.app` was kept), the catalog was
     updated with a copy in `_latent/backups/`, and the thumbnails rebuild
     once and then stay.
   - Open a raw, export a JPEG, run a Photo Merge on a bracket, and check
     Help › Latent Help shows the new What's New and Licences pages and
     About shows the new version and copyright.
4. Tag the commit (`git tag -a v<version> -m "Latent <version>"`), push
   the tag, and create the GitHub Release from it: upload the zip under
   Assets, paste the version's `CHANGELOG.md` section and the SHA-256.
5. Publish the wiki as above, so the online pages match the app's Help.
