#!/bin/bash
# Launch MkDocs on OpenHost.
#
# Topology:
#
#   $SOURCE_DIR (persistent, edited via SSH)
#         │
#         │  inotifywait sees changes
#         ▼
#   rebuild.sh runs `mkdocs build --strict`
#         │
#         ▼
#   /output/site/  (ephemeral inside container)
#         │
#         ▼
#   caddy 0.0.0.0:8080  →  browser
#
# Same architecture as openhost-hugo; only the SSG binary
# differs.  See that package's start.sh for the long-form
# rationale on inotify + debounce + atomic swap.
set -euo pipefail

PERSIST="${OPENHOST_APP_DATA_DIR:-/data/app_data/mkdocs}"
SOURCE_DIR="$PERSIST/site"
OUTPUT_DIR="/output/site"

mkdir -p "$SOURCE_DIR" "$OUTPUT_DIR"

# -----------------------------------------------------------------
# First-boot scaffolding
# -----------------------------------------------------------------
#
# Drop a minimal Material-themed placeholder so the first
# visit doesn't 404.
if [[ -z "$(ls -A "$SOURCE_DIR" 2>/dev/null)" ]]; then
    echo "[start.sh] First boot: scaffolding empty MkDocs site"

    cat > "$SOURCE_DIR/mkdocs.yml" <<'YAML'
site_name: openhost-mkdocs
site_description: Placeholder site from openhost-mkdocs
# We don't set site_url because MkDocs requires it to be a
# full URL (http://... / https://...) and we don't know the
# zone domain at scaffold time.  MkDocs falls back to
# relative URLs everywhere, which works on whatever public
# URL the OpenHost router serves us on.
theme:
  name: material
  features:
    - navigation.instant
    - navigation.tracking
    - navigation.top
    - search.suggest
    - search.highlight
    - content.code.copy
  palette:
    # Dark mode by default; operators can flip via mkdocs.yml.
    - scheme: slate
      primary: indigo
      accent: indigo
markdown_extensions:
  - admonition
  - pymdownx.highlight
  - pymdownx.superfences
  - pymdownx.details
  - tables
  - toc:
      permalink: true
plugins:
  - search
YAML

    mkdir -p "$SOURCE_DIR/docs"
    cat > "$SOURCE_DIR/docs/index.md" <<'MARKDOWN'
# openhost-mkdocs

This is the placeholder home page from the openhost-mkdocs container.
Replace it by SSHing into the OpenHost host:

```bash
cd ~/.openhost/local_compute_space/persistent_data/app_data/mkdocs/site/

# Edit existing pages:
$EDITOR docs/index.md

# Add new pages:
$EDITOR docs/getting-started.md

# Reconfigure the site:
$EDITOR mkdocs.yml
```

The container watches `docs/` and `mkdocs.yml` with inotify and
rebuilds on every change. Refresh the browser to see the update.

## Bundled tools

- **mkdocs** 1.6 — the static-site generator
- **mkdocs-material** 9.6 — the theme rendering this page
- **mkdocs-minify-plugin** 0.8 — optional HTML/CSS/JS minifier
- **pymdownx** extensions — admonitions, code blocks, etc.

## Add a theme override

To customize colours/layout beyond what `mkdocs.yml` exposes:

```bash
mkdir overrides
# (see https://squidfunk.github.io/mkdocs-material/customization/)
```

Then in `mkdocs.yml`:

```yaml
theme:
  name: material
  custom_dir: overrides
```
MARKDOWN
fi

# -----------------------------------------------------------------
# Initial build (synchronous)
# -----------------------------------------------------------------
echo "[start.sh] Running initial MkDocs build"
if ! /opt/openhost-mkdocs/rebuild.sh; then
    echo "[start.sh] WARNING: initial MkDocs build failed; serving empty /output/site until next source change"
    mkdir -p "$OUTPUT_DIR"
fi

# -----------------------------------------------------------------
# Launch caddy
# -----------------------------------------------------------------
# -----------------------------------------------------------------
# Caddy static-file server
# -----------------------------------------------------------------
#
# Why caddy: Debian Trixie does not ship a darkhttpd package,
# and the Alpine darkhttpd binary is musl-linked so it fails
# on a glibc base.  Caddy IS in Debian's apt repo and the
# config for static-file serving is one block.
#
# Caddy re-resolves the document root on every request (no
# chroot equivalent), so rebuild.sh's atomic-swap pattern
# works cleanly.

CADDYFILE="/tmp/Caddyfile"
cat > "$CADDYFILE" <<EOF
{
    # Disable Caddy's admin endpoint (default on 127.0.0.1:2019).
    # Nothing in this container talks to it, and dropping it
    # removes a tiny piece of attack surface.
    admin off
    # Suppress automatic HTTPS provisioning — TLS is terminated
    # by the OpenHost outer Caddy, not by us.
    auto_https off
    # Log access lines to stderr so 'oh app logs mkdocs' shows
    # them.
    log {
        output stderr
        format console
        level INFO
    }
    persist_config off
}

:8080 {
    root * $OUTPUT_DIR
    file_server {
        # Don't show directory listings (matches darkhttpd's
        # --no-listing).  Missing-index paths return 404.
        hide .git
    }
    # Pretty 404 for missing paths.  Could point at a custom
    # 404.html in the future.
    handle_errors {
        respond "{http.error.status_code} {http.error.status_text}"
    }
}
EOF

echo "[start.sh] Starting caddy on 0.0.0.0:8080 -> $OUTPUT_DIR"
caddy run --config "$CADDYFILE" --adapter caddyfile &
WEB_PID=$!

# -----------------------------------------------------------------
# Launch the inotify watcher
# -----------------------------------------------------------------
echo "[start.sh] Starting inotify watcher on $SOURCE_DIR"
(
    echo "[watcher] watching $SOURCE_DIR for changes"
    inotifywait -m -r -q \
        -e modify -e create -e delete -e moved_to -e moved_from \
        --format '%T %w%f %e' --timefmt '%Y-%m-%dT%H:%M:%S' \
        "$SOURCE_DIR" | while read -r event; do
        # Drain the event burst with a 1s debounce window.
        last_event="$event"
        while read -r -t 1 next_event; do
            last_event="$next_event"
        done
        echo "[watcher] change detected; rebuilding (last event: $last_event)"
        if /opt/openhost-mkdocs/rebuild.sh; then
            echo "[watcher] rebuild OK"
        else
            echo "[watcher] rebuild FAILED (see mkdocs output above); previous output dir kept"
        fi
    done
) &
WATCHER_PID=$!

# -----------------------------------------------------------------
# Supervision
# -----------------------------------------------------------------
#
# Same model as openhost-hugo: the web server is the only
# fatal child.  Watcher crashes restart in-place.
trap 'kill -TERM "$WEB_PID" "$WATCHER_PID" 2>/dev/null; wait' TERM INT

while true; do
    set +e
    wait -n "$WEB_PID" "$WATCHER_PID"
    EXIT_CODE=$?
    set -e

    if ! kill -0 "$WEB_PID" 2>/dev/null; then
        echo "[start.sh] caddy exited (code=$EXIT_CODE); container will shut down"
        break
    fi

    if ! kill -0 "$WATCHER_PID" 2>/dev/null; then
        echo "[start.sh] watcher exited (code=$EXIT_CODE); restarting" >&2
        (
            echo "[watcher] watching $SOURCE_DIR for changes (restarted)"
            inotifywait -m -r -q \
                -e modify -e create -e delete -e moved_to -e moved_from \
                --format '%T %w%f %e' --timefmt '%Y-%m-%dT%H:%M:%S' \
                "$SOURCE_DIR" | while read -r event; do
                last_event="$event"
                while read -r -t 1 next_event; do
                    last_event="$next_event"
                done
                echo "[watcher] change detected; rebuilding (last event: $last_event)"
                if /opt/openhost-mkdocs/rebuild.sh; then
                    echo "[watcher] rebuild OK"
                else
                    echo "[watcher] rebuild FAILED; previous output dir kept"
                fi
            done
        ) &
        WATCHER_PID=$!
        sleep 2
        continue
    fi
done

kill -TERM "$WEB_PID" "$WATCHER_PID" 2>/dev/null || true
wait || true
exit "$EXIT_CODE"
