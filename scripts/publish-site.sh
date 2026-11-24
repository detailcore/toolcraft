#!/usr/bin/env bash
# Assemble examples/*/dist into dist-site/demos/<name>/ and publish that tree
# as $SITE_ROOT/demos. The site directory itself stays in place, so the deploy
# user only needs write access inside SITE_ROOT.
# `/` is not a published file: origin nginx returns 302 /demos/.
set -euo pipefail

PUBLISH_PHASE=""
PUBLISH_STAGING=""
PUBLISH_PREVIOUS=""
PUBLISH_DEMOS=()
FETCH_CONTENT_TYPE=""
PUBLISH_OK_NAME=".publish-ok"

publish_root() {
  local dir
  if [[ -n "${PUBLISH_ROOT:-}" ]]; then
    dir="$PUBLISH_ROOT"
  else
    dir="$(dirname "${BASH_SOURCE[0]}")/.."
  fi
  (cd "$dir" && pwd)
}

live_demos() {
  printf '%s\n' "$SITE_ROOT/demos"
}

validate_site_root() {
  local root="$1"
  if [[ -z "$root" ]]; then
    echo "error: SITE_ROOT must be set (refusing to publish to an implicit path)" >&2
    return 1
  fi
  if [[ "$root" != /* || "$root" == *"//"* ]]; then
    echo "error: SITE_ROOT must be an absolute path: $root" >&2
    return 1
  fi
  if [[ "$root" == "/" ]]; then
    echo "error: SITE_ROOT must not be /" >&2
    return 1
  fi
  if [[ "$root" == */ ]]; then
    echo "error: SITE_ROOT must not end with a slash: $root" >&2
    return 1
  fi
  if [[ "$root" == *"/.." || "$root" == *"/../"* || "$root" == *"/." || "$root" == *"/./"* ]]; then
    echo "error: SITE_ROOT must not contain . or .. segments: $root" >&2
    return 1
  fi
}

validate_site_url() {
  local url="${1:-}"
  if [[ ! "$url" =~ ^https?://[^[:space:]/]+$ ]]; then
    echo "error: SITE_URL must be an absolute origin without a path or trailing slash: ${url:-<empty>}" >&2
    return 1
  fi
}

filesystem_id() {
  if stat -c %d "$1" >/dev/null 2>&1; then
    stat -c %d "$1"
    return 0
  fi
  if stat -f %d "$1" >/dev/null 2>&1; then
    stat -f %d "$1"
  fi
}

assert_publish_target() {
  local live root_id live_id
  live="$(live_demos)"
  if [[ ! -d "$SITE_ROOT" ]]; then
    echo "error: SITE_ROOT must already exist (create it and chown it to the deploy user): $SITE_ROOT" >&2
    return 1
  fi
  if [[ -L "$SITE_ROOT" ]]; then
    echo "error: SITE_ROOT must be a real directory, not a symlink: $SITE_ROOT" >&2
    return 1
  fi
  if [[ ! -w "$SITE_ROOT" ]]; then
    echo "error: SITE_ROOT is not writable by the deploy user: $SITE_ROOT" >&2
    return 1
  fi
  if [[ -L "$live" ]]; then
    echo "error: $live must be a real directory, not a symlink" >&2
    return 1
  fi
  if [[ -e "$live" && ! -d "$live" ]]; then
    echo "error: $live exists and is not a directory" >&2
    return 1
  fi
  if [[ -d "$live" ]]; then
    root_id="$(filesystem_id "$SITE_ROOT")"
    live_id="$(filesystem_id "$live")"
    if [[ -n "$root_id" && -n "$live_id" && "$root_id" != "$live_id" ]]; then
      echo "error: demos is on a different filesystem from SITE_ROOT; refusing a non-atomic replace: $live" >&2
      return 1
    fi
  fi
}

demo_re() {
  local name="$1"
  name="${name//./\\.}"
  printf '%s' "$name"
}

demo_asset_grep_pattern() {
  local name_re
  name_re="$(demo_re "$1")"
  printf '%s\n' "<(script|link)[^>]*(src|href)=[\"']/demos/${name_re}/[^\"']+[\"']"
}

demo_html_has_asset() {
  local file="$1"
  local name="$2"
  grep -Eq "$(demo_asset_grep_pattern "$name")" "$file"
}

collect_asset_urls() {
  local file="$1"
  local name="$2"
  local name_re line rest url regex
  name_re="$(demo_re "$name")"
  regex="(src|href)=[\"'](/demos/${name_re}/[^\"']+)[\"']"
  while IFS= read -r line; do
    rest="$line"
    while [[ "$rest" =~ $regex ]]; do
      url="${BASH_REMATCH[2]}"
      rest="${rest#*"${BASH_REMATCH[0]}"}"
      printf '%s\n' "$url"
    done
  done < <(grep -E "$(demo_asset_grep_pattern "$name")" "$file" || true)
}

demo_asset_path() {
  local file="$1"
  local name="$2"
  local url picked=""
  while IFS= read -r url; do
    case "$url" in
      *.js)
        printf '%s\n' "$url"
        return 0
        ;;
      *.css)
        [[ -n "$picked" ]] || picked="$url"
        ;;
      *)
        [[ -n "$picked" ]] || picked="$url"
        ;;
    esac
  done < <(collect_asset_urls "$file" "$name")
  [[ -n "$picked" ]] || return 1
  printf '%s\n' "$picked"
}

read_example_names() {
  local root="$1"
  local d name
  local -a found=()
  shopt -s nullglob
  for d in "$root"/examples/*/; do
    [[ -f "${d}package.json" ]] || continue
    name="$(basename "$d")"
    if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
      shopt -u nullglob
      echo "error: example directory name must be a slug: $name" >&2
      return 1
    fi
    found+=("$name")
  done
  shopt -u nullglob
  if [[ ${#found[@]} -eq 0 ]]; then
    echo "error: no examples found under examples/*/" >&2
    return 1
  fi
  PUBLISH_DEMOS=("${found[@]}")
}

assert_example_dist() {
  local root="$1"
  local name dist index
  for name in "${PUBLISH_DEMOS[@]}"; do
    dist="$root/examples/$name/dist"
    index="$dist/index.html"
    if [[ ! -d "$dist" ]]; then
      echo "error: missing build output: examples/$name/dist" >&2
      return 1
    fi
    if [[ ! -f "$index" ]]; then
      echo "error: missing examples/$name/dist/index.html" >&2
      return 1
    fi
    if ! demo_html_has_asset "$index" "$name"; then
      echo "error: examples/$name/dist/index.html has no script/link URL under /demos/$name/ (build without --base /demos/$name/?)" >&2
      return 1
    fi
  done
}

write_dist_site() {
  local root="$1"
  local dest="$2"
  local name
  rm -rf -- "$dest" || return 1
  mkdir -p "$dest/demos" || return 1
  {
    printf '%s\n' '<!doctype html><title>Toolcraft demos</title><h1>demos</h1><ol>' || return 1
    for name in "${PUBLISH_DEMOS[@]}"; do
      mkdir -p "$dest/demos/$name" || return 1
      cp -a "$root/examples/$name/dist/." "$dest/demos/$name/" || return 1
      printf '<li><a href="/demos/%s/">/demos/%s/</a></li>\n' "$name" "$name" || return 1
    done
    printf '%s\n' '</ol>' || return 1
  } >"$dest/demos/index.html"
}

remove_staging() {
  local staging="${PUBLISH_STAGING:-}"
  [[ -n "$staging" && -n "${SITE_ROOT:-}" ]] || return 0
  [[ "$staging" == "$SITE_ROOT/.staging."* ]] || return 0
  rm -rf -- "$staging"
}

restore_parked_site() {
  local live
  live="$(live_demos)"
  if [[ ! -e "$live" && -d "$PUBLISH_PREVIOUS" ]]; then
    command mv "$PUBLISH_PREVIOUS" "$live" || true
  fi
  if [[ -e "$live" ]]; then
    remove_staging
  fi
}

rollback_swapped_site() {
  local live failed
  live="$(live_demos)"
  failed="$SITE_ROOT/.failed.$$"
  if [[ -e "$live" ]]; then
    command mv "$live" "$failed" || true
  fi
  if [[ -d "$PUBLISH_PREVIOUS" ]]; then
    if ! command mv "$PUBLISH_PREVIOUS" "$live"; then
      if [[ ! -e "$live" && -d "$failed" ]]; then
        command mv "$failed" "$live" || true
      fi
      return
    fi
  fi
  if [[ -e "$live" || ! -d "$PUBLISH_PREVIOUS" ]]; then
    rm -rf -- "$failed"
    remove_staging
  fi
}

publish_on_exit() {
  local status=$?
  trap - EXIT
  set +e
  case "${PUBLISH_PHASE:-}" in
    demos_aside) restore_parked_site ;;
    swapped) rollback_swapped_site ;;
    staging) remove_staging ;;
  esac
  exit "$status"
}

remove_snapshot_globs() {
  local item
  local -a leftovers=()
  shopt -s nullglob
  leftovers=("$SITE_ROOT/.previous."* "$SITE_ROOT/.staging."* "$SITE_ROOT/.failed."*)
  shopt -u nullglob
  for item in "${leftovers[@]}"; do
    rm -rf -- "$item"
  done
}

recover_orphaned_previous() {
  local live failed item
  local -a leftovers=()
  live="$(live_demos)"
  shopt -s nullglob
  leftovers=("$SITE_ROOT/.previous."*)
  shopt -u nullglob

  if [[ -d "$live" && -f "$live/$PUBLISH_OK_NAME" ]]; then
    remove_snapshot_globs
    return 0
  fi
  if [[ -e "$live" && ! -d "$live" ]]; then
    echo "error: $live exists and is not a directory" >&2
    return 1
  fi
  if [[ ${#leftovers[@]} -gt 1 ]]; then
    echo "error: $live has no committed publish marker and more than one previous snapshot exists" >&2
    return 1
  fi
  if [[ ${#leftovers[@]} -eq 1 ]]; then
    if [[ ! -d "${leftovers[0]}" ]]; then
      echo "error: previous snapshot is not a directory: ${leftovers[0]}" >&2
      return 1
    fi
    failed="$SITE_ROOT/.failed.$$"
    if [[ -e "$live" ]]; then
      command mv "$live" "$failed" || return 1
    fi
    if ! command mv "${leftovers[0]}" "$live"; then
      if [[ ! -e "$live" && -d "$failed" ]]; then
        command mv "$failed" "$live" || true
      fi
      return 1
    fi
    rm -rf -- "$failed"
    echo "restored demos from ${leftovers[0]}" >&2
  fi
  shopt -s nullglob
  leftovers=("$SITE_ROOT/.staging."*)
  shopt -u nullglob
  for item in "${leftovers[@]}"; do
    rm -rf -- "$item"
  done
}

move_into_place() {
  command mv "$@"
}

stage_dist() {
  local dist="$1"
  PUBLISH_STAGING="$SITE_ROOT/.staging.$$"
  PUBLISH_PREVIOUS="$SITE_ROOT/.previous.$$"
  PUBLISH_PHASE=staging
  trap publish_on_exit EXIT
  remove_staging
  mkdir -p "$PUBLISH_STAGING" || return 1
  cp -a "$dist/demos/." "$PUBLISH_STAGING/" || return 1
  chmod -R a+rX "$PUBLISH_STAGING" || return 1
}

activate_staged_tree() {
  local live
  live="$(live_demos)"
  if [[ -e "$live" ]]; then
    command mv "$live" "$PUBLISH_PREVIOUS" || return 1
    PUBLISH_PHASE=demos_aside
    if declare -F publish_after_park >/dev/null; then
      publish_after_park || return 1
    fi
  fi
  move_into_place "$PUBLISH_STAGING" "$live" || return 1
  PUBLISH_PHASE=swapped
}

commit_publish() {
  local live item
  live="$(live_demos)"
  printf '%s\n' "ok" >"$live/$PUBLISH_OK_NAME" || return 1
  chmod a+r "$live/$PUBLISH_OK_NAME" || return 1
  PUBLISH_PHASE=committed
  trap - EXIT
  shopt -s nullglob
  local -a leftovers=("$SITE_ROOT/.previous."*)
  shopt -u nullglob
  for item in "${leftovers[@]}"; do
    rm -rf -- "$item" || return 1
  done
  PUBLISH_STAGING=""
}

location_path() {
  local loc="$1"
  loc="${loc%%$'\r'*}"
  loc="${loc%%\?*}"
  loc="${loc%%#*}"
  if [[ "$loc" == http://* || "$loc" == https://* ]]; then
    loc="${loc#*://}"
    loc="/${loc#*/}"
  fi
  if [[ "$loc" != /* ]]; then
    printf '\n'
    return 0
  fi
  [[ "$loc" == */ ]] || loc="${loc}/"
  printf '%s\n' "$loc"
}

redirect_host() {
  local url="$1"
  url="${url#*://}"
  url="${url%%/*}"
  url="${url##*@}"
  printf '%s\n' "${url,,}"
}

assert_redirect_location() {
  local loc="$1"
  local path origin_host loc_host
  loc="${loc%%$'\r'*}"
  if [[ -z "$loc" ]]; then
    echo "error: ${SITE_URL}/ redirected to '<empty>', expected /demos/ on ${SITE_URL}" >&2
    return 1
  fi
  if [[ "$loc" == //* ]]; then
    echo "error: ${SITE_URL}/ redirected to '$loc', expected /demos/ on ${SITE_URL}" >&2
    return 1
  fi
  if [[ "$loc" == http://* || "$loc" == https://* ]]; then
    origin_host="$(redirect_host "$SITE_URL")"
    loc_host="$(redirect_host "$loc")"
    if [[ "$loc_host" != "$origin_host" ]]; then
      echo "error: ${SITE_URL}/ redirected to '$loc', expected /demos/ on ${SITE_URL}" >&2
      return 1
    fi
  elif [[ "$loc" != /* ]]; then
    echo "error: ${SITE_URL}/ redirected to '$loc', expected /demos/ on ${SITE_URL}" >&2
    return 1
  fi
  path="$(location_path "$loc")"
  if [[ "$path" != "/demos/" ]]; then
    echo "error: ${SITE_URL}/ redirected to '$loc', expected /demos/" >&2
    return 1
  fi
}

assert_root_redirect() {
  local headers status location
  headers="$(mktemp)"
  status="$(curl -sS --retry 2 --retry-delay 1 -D "$headers" -o /dev/null -w '%{http_code}' "${SITE_URL}/")" || {
    rm -f -- "$headers"
    echo "error: failed to request ${SITE_URL}/" >&2
    return 1
  }
  location="$(tr -d '\r' <"$headers" | awk 'tolower($1) == "location:" { print $2 }' | tail -n 1)"
  rm -f -- "$headers"
  if [[ "$status" != 301 && "$status" != 302 && "$status" != 307 && "$status" != 308 ]]; then
    echo "error: ${SITE_URL}/ expected an HTTP redirect, got ${status}" >&2
    return 1
  fi
  assert_redirect_location "$location"
}

fetch_url() {
  local url="$1"
  local dest="$2"
  local meta status
  meta="$(curl -sS --retry 2 --retry-delay 1 -L -o "$dest" -w '%{http_code} %{content_type}' "$url")" || {
    echo "error: failed to fetch $url" >&2
    return 1
  }
  status="${meta%% *}"
  if [[ "$meta" == *" "* ]]; then
    FETCH_CONTENT_TYPE="${meta#* }"
  else
    FETCH_CONTENT_TYPE=""
  fi
  if [[ "$status" != 200 ]]; then
    echo "error: $url returned HTTP $status" >&2
    return 1
  fi
  if [[ ! -s "$dest" ]]; then
    echo "error: $url returned an empty body" >&2
    return 1
  fi
}

absolute_url() {
  local base="$1"
  local ref="$2"
  if [[ "$ref" == http://* || "$ref" == https://* ]]; then
    printf '%s\n' "$ref"
    return 0
  fi
  printf '%s%s\n' "${base%/}" "$ref"
}

asset_response_ok() {
  local dest="$1"
  local html="$2"
  local url="$3"
  local ctype sample
  ctype="${FETCH_CONTENT_TYPE,,}"
  if [[ "$ctype" == *html* ]]; then
    echo "error: $url returned HTML (${FETCH_CONTENT_TYPE:-<empty>}); the asset URL is serving the demo shell" >&2
    return 1
  fi
  if cmp -s "$dest" "$html"; then
    echo "error: $url body matches the demo HTML shell" >&2
    return 1
  fi
  sample="$(head -c 64 "$dest" | tr '[:upper:]' '[:lower:]' | tr -d '\r')"
  if [[ "$sample" == "<!doctype html"* || "$sample" == "<html"* ]]; then
    echo "error: $url body looks like HTML" >&2
    return 1
  fi
}

smoke_site_checks() {
  local work="$1"
  local name asset asset_url
  local -a assets=()
  assert_root_redirect || return 1
  fetch_url "${SITE_URL}/demos/" "$work/catalog.html" || return 1
  for name in "${PUBLISH_DEMOS[@]}"; do
    if ! grep -Fq "href=\"/demos/${name}/\"" "$work/catalog.html"; then
      echo "error: ${SITE_URL}/demos/ is missing href=\"/demos/${name}/\"" >&2
      return 1
    fi
    fetch_url "${SITE_URL}/demos/${name}/" "$work/${name}.html" || return 1
    if ! demo_html_has_asset "$work/${name}.html" "$name"; then
      echo "error: ${SITE_URL}/demos/${name}/ has no script or link asset under /demos/${name}/" >&2
      return 1
    fi
    mapfile -t assets < <(collect_asset_urls "$work/${name}.html" "$name")
    if [[ ${#assets[@]} -eq 0 ]]; then
      echo "error: ${SITE_URL}/demos/${name}/ has no asset URLs under /demos/${name}/" >&2
      return 1
    fi
    for asset in "${assets[@]}"; do
      asset_url="$(absolute_url "$SITE_URL" "$asset")"
      fetch_url "$asset_url" "$work/${name}.asset" || return 1
      asset_response_ok "$work/${name}.asset" "$work/${name}.html" "$asset_url" || return 1
    done
  done
}

smoke_site() {
  local work status
  work="$(mktemp -d)"
  set +e
  smoke_site_checks "$work"
  status=$?
  set -e
  rm -rf -- "$work"
  if [[ "$status" -ne 0 ]]; then
    echo "error: smoke checks failed; restoring the previous site" >&2
  fi
  return "$status"
}

publish_site_main() {
  local root dist
  root="$(publish_root)"
  validate_site_root "${SITE_ROOT:-}" || return 1
  validate_site_url "${SITE_URL:-}" || return 1
  assert_publish_target || return 1
  recover_orphaned_previous || return 1
  read_example_names "$root" || return 1
  assert_example_dist "$root" || return 1
  dist="${DIST_SITE:-$root/dist-site}"
  write_dist_site "$root" "$dist" || return 1
  stage_dist "$dist" || return 1
  activate_staged_tree || return 1
  smoke_site || return 1
  commit_publish || return 1
  echo "published ${#PUBLISH_DEMOS[@]} demos to $SITE_ROOT/demos"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  publish_site_main
fi
