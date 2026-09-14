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
