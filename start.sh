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
#   darkhttpd 0.0.0.0:8080  →  browser
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
# Relative site_url so this works on any zone domain without
# the operator having to edit this file before deploying.
site_url: /
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
# Launch darkhttpd
# -----------------------------------------------------------------
echo "[start.sh] Starting darkhttpd on 0.0.0.0:8080 -> $OUTPUT_DIR"
# NOTE: no --chroot here (unlike openhost-darkhttpd).  rebuild.sh
# atomically swaps $OUTPUT_DIR via rename(2); darkhttpd needs to
# re-resolve the path on every request to see the new dir, which
# chroot() prevents.  See openhost-hugo/start.sh for the long
# rationale.
#
# Debian uses 'nogroup' as the group for the nobody user; alpine
# uses 'nobody'.  We're debian-based here, so 'nogroup'.
darkhttpd "$OUTPUT_DIR" \
    --port 8080 \
    --addr 0.0.0.0 \
    --no-listing \
    --uid nobody \
    --gid nogroup \
    --log /dev/stderr &
DARKHTTPD_PID=$!

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
# Same model as openhost-hugo: darkhttpd is the only fatal
# child.  Watcher crashes restart in-place.
trap 'kill -TERM "$DARKHTTPD_PID" "$WATCHER_PID" 2>/dev/null; wait' TERM INT

while true; do
    set +e
    wait -n "$DARKHTTPD_PID" "$WATCHER_PID"
    EXIT_CODE=$?
    set -e

    if ! kill -0 "$DARKHTTPD_PID" 2>/dev/null; then
        echo "[start.sh] darkhttpd exited (code=$EXIT_CODE); container will shut down"
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

kill -TERM "$DARKHTTPD_PID" "$WATCHER_PID" 2>/dev/null || true
wait || true
exit "$EXIT_CODE"
