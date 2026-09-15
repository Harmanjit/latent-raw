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
