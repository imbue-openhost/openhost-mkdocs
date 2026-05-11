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

# Stage 1: lift the darkhttpd binary from Alpine.
# Debian Trixie does NOT have a `darkhttpd` apt package, so
# we take the statically-linkable Alpine build and copy just
# the /usr/bin/darkhttpd binary into the runtime image.
# darkhttpd is a ~50 KiB static binary with no runtime deps
# (libc only); it ports cleanly between Alpine and Debian.
FROM docker.io/library/alpine:3.20 AS darkhttpd-source
RUN apk add --no-cache darkhttpd

# Stage 2: runtime image.
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
# small.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        bash \
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

# Copy the darkhttpd binary from the alpine stage.  Drop it at
# /usr/local/bin/ so it precedes any future debian-supplied
# darkhttpd on PATH.
COPY --from=darkhttpd-source /usr/bin/darkhttpd /usr/local/bin/darkhttpd

# Copy entrypoint + rebuild helper (mode 0755 in git).
COPY start.sh /opt/openhost-mkdocs/start.sh
COPY rebuild.sh /opt/openhost-mkdocs/rebuild.sh

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/openhost-mkdocs/start.sh"]
