#!/usr/bin/env bash
# Assemble examples/*/dist into dist-site/demos/<name>/ and publish to origin www root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_SITE="${DIST_SITE:-$ROOT/dist-site}"

if [[ -z "${SITE_ROOT:-}" ]]; then
  echo "error: SITE_ROOT must be set (refusing to publish to an implicit path)" >&2
  exit 1
fi

cd "$ROOT"

expected=()
for d in examples/*/; do
  [[ -f "${d}package.json" ]] || continue
  expected+=("$(basename "$d")")
done

if [[ ${#expected[@]} -eq 0 ]]; then
  echo "error: no examples found under examples/*/" >&2
  exit 1
fi

for name in "${expected[@]}"; do
  dist="examples/$name/dist"
  index="$dist/index.html"
  needle="/demos/$name/"

  if [[ ! -d "$dist" ]]; then
    echo "error: missing build output: $dist" >&2
    exit 1
  fi
  if [[ ! -f "$index" ]]; then
    echo "error: missing $index" >&2
    exit 1
  fi
  if ! grep -Fq "$needle" "$index"; then
    echo "error: $index does not contain base path $needle (Vite base misconfigured?)" >&2
    exit 1
  fi
done

rm -rf "$DIST_SITE"
mkdir -p "$DIST_SITE/demos"

{
  printf '%s\n' '<!doctype html><title>Toolcraft demos</title><h1>demos</h1><ul>'
  for name in "${expected[@]}"; do
    mkdir -p "$DIST_SITE/demos/$name"
    cp -a "examples/$name/dist/." "$DIST_SITE/demos/$name/"
    printf '<li><a href="/demos/%s/">%s</a></li>\n' "$name" "$name"
  done
  printf '%s\n' '</ul>'
} >"$DIST_SITE/demos/index.html"

cat >"$DIST_SITE/index.html" <<'EOF'
<!doctype html>
<title>Toolcraft</title>
<meta http-equiv="refresh" content="0; url=/demos/">
<p><a href="/demos/">Toolcraft demos</a></p>
EOF

staging="${SITE_ROOT}.staging.$$"
previous="${SITE_ROOT}.previous.$$"

cleanup() {
  rm -rf "$staging"
}
trap cleanup EXIT

rm -rf "$staging"
mkdir -p "$staging"
cp -a "$DIST_SITE"/. "$staging/"
chmod -R a+rX "$staging"

mkdir -p "$(dirname "$SITE_ROOT")"
if [[ -e "$SITE_ROOT" ]]; then
  mv "$SITE_ROOT" "$previous"
fi
mv "$staging" "$SITE_ROOT"
rm -rf "$previous"
trap - EXIT

echo "published ${#expected[@]} demos to $SITE_ROOT"
