# openhost-mkdocs

[MkDocs](https://www.mkdocs.org/) with [Material](https://squidfunk.github.io/mkdocs-material/) — the popular Python-based documentation
site generator — packaged for OpenHost with a live-rebuild loop.

## What you get

- MkDocs + Material theme + minify plugin + the common pymdownx
  extensions, running on `https://mkdocs.<zone>/`.
- Public by default. Anonymous visitors can read the site.
- Markdown source in `$OPENHOST_APP_DATA_DIR/site/docs/` on the host.
- `mkdocs.yml` config in `$OPENHOST_APP_DATA_DIR/site/mkdocs.yml`.
- An `inotify` watcher rebuilds within seconds of any source change.
- Built output served by Caddy (Debian Trixie doesn't ship
  `darkhttpd`; Caddy is the closest one-config equivalent).

## Authoring

```bash
ssh host@<zone>
cd ~/.openhost/local_compute_space/persistent_data/app_data/mkdocs/site/

# Edit pages:
$EDITOR docs/index.md
$EDITOR docs/getting-started.md

# Add a new page (and add it to the nav in mkdocs.yml if you want
# manual navigation; otherwise Material auto-detects):
$EDITOR docs/topic/installation.md

# Reconfigure theme / plugins / nav:
$EDITOR mkdocs.yml

# Or replace the whole site:
rm -rf .
git clone https://github.com/me/my-docs.git .
```

The container watches `docs/` and `mkdocs.yml` with inotify; refresh
the browser within a few seconds of saving and you see the update.

## Bundled

- `mkdocs` 1.6
- `mkdocs-material` 9.6 (the theme)
- `mkdocs-minify-plugin` 0.8
- All Material-recommended `pymdownx` extensions

## Why Material

Material has built-in search, dark mode, navigation styles, code-copy
buttons, and admonition styling out of the box. It's what most teams
use for self-hosted docs sites and it works without configuration.

If you don't want Material, edit `mkdocs.yml`:

```yaml
theme:
  name: mkdocs  # or readthedocs, or any other theme you `pip install`
```

To install additional themes/plugins, the operator can either:

1. Add a `requirements.txt` to the source dir and rebuild the
   container with a custom Dockerfile that pip-installs from it.
2. Use one of the bundled themes/plugins and live with that.

This package is opinionated toward "Material with sensible defaults"
because that's what 90% of self-hosted MkDocs sites are.

## Architecture

```
SSH author
   │
   │  rsync / git pull / vim
   ▼
$OPENHOST_APP_DATA_DIR/site/   (persistent: mkdocs.yml + docs/)
   │
   │  inotifywait -m -r -e modify -e create -e delete ...
   ▼
rebuild.sh
   │
   │  mkdocs build --site-dir <staging> --strict
   │  mv <staging> /output/site  (atomic)
   ▼
/output/site/   (ephemeral)
   │
   ▼
caddy file_server 0.0.0.0:8080
   │
   ▼
OpenHost router (public_paths = ["/"])
   │
   ▼
browser
```

## `--strict` is on

We invoke `mkdocs build --strict` so warnings (broken internal links,
unrecognized config keys) fail the build. The previous good output
keeps serving until the operator fixes the issue. Errors appear in
`oh app logs mkdocs`.

## When NOT to use this

- You want a "drop HTML" workflow → `openhost-darkhttpd`.
- You prefer Hugo's Go-template based theming → `openhost-hugo`.
- You want a wiki where users edit in the browser → `openhost-outline`.
