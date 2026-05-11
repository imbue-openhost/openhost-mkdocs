#!/bin/bash
# Rebuild the MkDocs site.
#
# Same atomic-swap pattern as openhost-hugo: build into a
# staging dir, rename into place only on success.  This ensures
# darkhttpd never serves a half-built site mid-rebuild.
set -euo pipefail

PERSIST="${OPENHOST_APP_DATA_DIR:-/data/app_data/mkdocs}"
SOURCE_DIR="${SOURCE_DIR:-$PERSIST/site}"
OUTPUT_DIR="${OUTPUT_DIR:-/output/site}"

PARENT_DIR="$(dirname "$OUTPUT_DIR")"
STAGING_DIR="$(mktemp -d "$PARENT_DIR/mkdocs-build-XXXXXX")"
mkdir -p "$PARENT_DIR"

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

cd "$SOURCE_DIR"

# Build flags:
#   --site-dir          where to write the rendered HTML
#   --strict            treat warnings (broken internal links,
#                       unrecognized config keys) as errors.
#                       Keeps the operator from accidentally
#                       publishing a partially-broken site.
# We deliberately do NOT pass `--clean` because we build into
# a fresh mktemp'd dir each time, so clean is redundant.
if ! mkdocs build \
        --site-dir "$STAGING_DIR" \
        --strict; then
    echo "[rebuild.sh] mkdocs build failed; keeping existing $OUTPUT_DIR" >&2
    exit 1
fi

# Atomic swap.  See openhost-hugo's rebuild.sh for full
# rationale.
OLD_DIR=""
if [[ -d "$OUTPUT_DIR" ]]; then
    OLD_DIR="$PARENT_DIR/mkdocs-old-$$"
    mv "$OUTPUT_DIR" "$OLD_DIR"
fi
mv "$STAGING_DIR" "$OUTPUT_DIR"
trap - EXIT
if [[ -n "$OLD_DIR" ]]; then
    rm -rf "$OLD_DIR"
fi

chmod -R a+rX "$OUTPUT_DIR"

echo "[rebuild.sh] rebuild OK; $(find "$OUTPUT_DIR" -type f | wc -l) files in $OUTPUT_DIR"
