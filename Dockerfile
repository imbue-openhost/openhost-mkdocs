# OpenHost MkDocs container.
#
# Same shape as openhost-hugo: source dir + inotify watcher +
# rebuild script + darkhttpd serving the built output.  The
# difference is the SSG itself — MkDocs is Python-based, with
# the Material theme pre-installed because most operators
# want it and it's a substantial pip install.
#
# Source dir:  $OPENHOST_APP_DATA_DIR/site/        (persistent)
# Output dir:  /output/site/                       (ephemeral)

FROM docker.io/library/python:3.13-slim

# Install:
#   * mkdocs                         — the SSG itself.
#   * mkdocs-material                — the popular Material theme.
#                                       Bundles pymdownx extensions,
#                                       built-in search, social
#                                       cards (with cairosvg /
#                                       pillow optional deps), etc.
#                                       Most operators want it; we
#                                       pre-install so the placeholder
#                                       site renders nicely on first
#                                       boot.
#   * mkdocs-minify-plugin           — optional but tiny; minifies
#                                       the rendered HTML/CSS/JS.
#                                       Operators opt in via
#                                       mkdocs.yml.
#
# We pin major versions to avoid surprise breaking changes on
# rebuild.  Latest at packaging time:
#   * mkdocs        1.6.x
#   * mkdocs-material 9.6.x
#
# Slim deps via --no-install-recommends to keep the image
# small; the apt step installs the system tools start.sh + the
# rebuild scripts need.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        bash \
        darkhttpd \
        inotify-tools \
        git \
        tini \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && apt-get clean \
 && pip install --no-cache-dir \
        'mkdocs>=1.6,<2' \
        'mkdocs-material>=9.6,<10' \
        'mkdocs-minify-plugin>=0.8,<1'

# Copy entrypoint + rebuild helper (mode 0755 in git).
COPY start.sh /opt/openhost-mkdocs/start.sh
COPY rebuild.sh /opt/openhost-mkdocs/rebuild.sh

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/openhost-mkdocs/start.sh"]
