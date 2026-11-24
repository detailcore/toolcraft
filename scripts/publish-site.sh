#!/usr/bin/env bash
# Assemble examples/*/dist into dist-site/demos/<name>/ and publish to origin www root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE_ROOT="${SITE_ROOT:-/var/www/toolcraft.ermolaev.site}"
DIST_SITE="${DIST_SITE:-$ROOT/dist-site}"

cd "$ROOT"

rm -rf "$DIST_SITE"
mkdir -p "$DIST_SITE/demos"

{
  printf '%s\n' '<!doctype html><title>Toolcraft demos</title><h1>demos</h1><ul>'
  for d in examples/*/; do
    name="$(basename "$d")"
    [ -d "$d/dist" ] || continue
    mkdir -p "$DIST_SITE/demos/$name"
    cp -a "$d/dist/." "$DIST_SITE/demos/$name/"
    printf '<li><a href="/demos/%s/">%s</a></li>\n' "$name" "$name"
  done
  printf '%s\n' '</ul>'
} >"$DIST_SITE/demos/index.html"

mkdir -p "$SITE_ROOT"
rsync -a --delete "$DIST_SITE/" "$SITE_ROOT/"
chmod -R a+rX "$SITE_ROOT"
