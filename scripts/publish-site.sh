#!/usr/bin/env bash
# Assemble examples/*/dist into dist-site/<name>/ plus a root catalog index.html,
# then publish that tree into $SITE_ROOT. The site directory itself stays in
# place, so the deploy user only needs write access inside SITE_ROOT.
# Origin nginx serves `/` as the catalog and `/{name}/` as each demo SPA;
# `/demos/...` is redirected away from the old prefix.
set -euo pipefail

PUBLISH_PHASE=""
PUBLISH_STAGING=""
PUBLISH_PREVIOUS=""
PUBLISH_DEMOS=()
FETCH_CONTENT_TYPE=""
PUBLISH_OK_NAME=".publish-ok"
PUBLISH_DEMOS_NAME=".publish-demos"
PUBLISH_INCOMING_NAME=".publish-incoming"
PUBLISH_PARKED_NAME=".publish-parked"
PUBLISH_MANAGED=()

publish_root() {
  local dir
  if [[ -n "${PUBLISH_ROOT:-}" ]]; then
    dir="$PUBLISH_ROOT"
  else
    dir="$(dirname "${BASH_SOURCE[0]}")/.."
  fi
  (cd "$dir" && pwd)
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
}

demo_re() {
  local name="$1"
  name="${name//./\\.}"
  printf '%s' "$name"
}

demo_asset_grep_pattern() {
  local name_re
  name_re="$(demo_re "$1")"
  printf '%s\n' "<(script|link)[^>]*(src|href)=[\"']/${name_re}/[^\"']+[\"']"
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
  regex="(src|href)=[\"'](/${name_re}/[^\"']+)[\"']"
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
      echo "error: examples/$name/dist/index.html has no script/link URL under /$name/ (build without --base /$name/?)" >&2
      return 1
    fi
  done
}

write_dist_site() {
  local root="$1"
  local dest="$2"
  local name
  rm -rf -- "$dest" || return 1
  mkdir -p "$dest" || return 1
  {
    printf '%s\n' '<!doctype html><title>Toolcraft demos</title><h1>demos</h1><ol>' || return 1
    for name in "${PUBLISH_DEMOS[@]}"; do
      mkdir -p "$dest/$name" || return 1
      cp -a "$root/examples/$name/dist/." "$dest/$name/" || return 1
      printf '<li><a href="/%s/">/%s/</a></li>\n' "$name" "$name" || return 1
    done
    printf '%s\n' '</ol>' || return 1
  } >"$dest/index.html"
}

remove_staging() {
  local staging="${PUBLISH_STAGING:-}"
  [[ -n "$staging" && -n "${SITE_ROOT:-}" ]] || return 0
  case "$staging" in
    "$SITE_ROOT"/.staging.*|"$SITE_ROOT"/.activating.*) ;;
    *) return 0 ;;
  esac
  rm -rf -- "$staging"
}

is_entry_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$name" != "." && "$name" != ".." ]] || return 1
  [[ "$name" != "$PUBLISH_INCOMING_NAME" && "$name" != "$PUBLISH_PARKED_NAME" ]] || return 1
}

list_previous_demo_names() {
  local manifest="$SITE_ROOT/$PUBLISH_DEMOS_NAME"
  local name
  [[ -f "$manifest" ]] || return 0
  while IFS= read -r name || [[ -n "$name" ]]; do
    name="${name%$'\r'}"
    [[ -n "$name" ]] || continue
    if ! is_entry_name "$name"; then
      echo "error: $PUBLISH_DEMOS_NAME contains an unsafe name: $name" >&2
      return 1
    fi
    printf '%s\n' "$name"
  done <"$manifest"
}

list_managed_entry_names() {
  local name
  printf '%s\n' "index.html" "$PUBLISH_OK_NAME" "$PUBLISH_DEMOS_NAME" "demos"
  for name in "${PUBLISH_DEMOS[@]}"; do
    printf '%s\n' "$name"
  done
  list_previous_demo_names
}

collect_managed_names() {
  local tmp line
  local -A seen=()
  tmp="$(mktemp)"
  if ! list_managed_entry_names >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  PUBLISH_MANAGED=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    [[ -n "${seen[$line]+x}" ]] && continue
    if ! is_entry_name "$line"; then
      echo "error: refusing to publish unsafe path entry: $line" >&2
      rm -f -- "$tmp"
      return 1
    fi
    seen["$line"]=1
    PUBLISH_MANAGED+=("$line")
  done <"$tmp"
  rm -f -- "$tmp"
}

assert_managed_filesystem() {
  local root_id path_id name src
  root_id="$(filesystem_id "$SITE_ROOT")"
  for name in "${PUBLISH_MANAGED[@]}"; do
    src="$SITE_ROOT/$name"
    [[ -e "$src" && ! -L "$src" ]] || continue
    path_id="$(filesystem_id "$src")"
    if [[ -n "$root_id" && -n "$path_id" && "$root_id" != "$path_id" ]]; then
      echo "error: $src is on a different filesystem from SITE_ROOT; refusing a non-atomic replace" >&2
      return 1
    fi
  done
}

write_lines_file() {
  local dest="$1"
  local tmp="$dest.tmp.$$"
  shift
  local name
  : >"$tmp" || return 1
  for name in "$@"; do
    printf '%s\n' "$name" >>"$tmp" || {
      rm -f -- "$tmp"
      return 1
    }
  done
  chmod a+r "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  command mv -- "$tmp" "$dest" || {
    rm -f -- "$tmp"
    return 1
  }
}

write_incoming_plan() {
  write_lines_file "$SITE_ROOT/$PUBLISH_INCOMING_NAME" "${PUBLISH_MANAGED[@]}"
}

write_parked_marker() {
  write_lines_file "$SITE_ROOT/$PUBLISH_PARKED_NAME" "parked"
}

relocate_entry() {
  command mv "$@"
}

snapshot_entry_names() {
  local src="$1"
  local item base
  local -a items=()
  shopt -s nullglob
  items=("$src"/* "$src"/.[!.]* "$src"/..?*)
  shopt -u nullglob
  for item in "${items[@]}"; do
    [[ -e "$item" || -L "$item" ]] || continue
    base="$(basename "$item")"
    [[ "$base" == "." || "$base" == ".." ]] && continue
    printf '%s\n' "$base"
  done
}

undo_snapshot_apply() {
  local src="$1"
  local trash="$2"
  shift 2
  local name
  for name in "$@"; do
    if [[ -e "$SITE_ROOT/$name" || -L "$SITE_ROOT/$name" ]]; then
      command mv -- "$SITE_ROOT/$name" "$src/$name" || true
    fi
    if [[ -e "$trash/$name" || -L "$trash/$name" ]]; then
      command mv -- "$trash/$name" "$SITE_ROOT/$name" || true
    fi
  done
  rmdir -- "$trash" 2>/dev/null || true
}

apply_snapshot() {
  local src="$1"
  local drop_extra="$2"
  local trash="$SITE_ROOT/.failed.$$"
  local -a names=()
  local -a applied=()
  local -a extras=()
  local -A in_snapshot=()
  local name dest extra

  while IFS= read -r name || [[ -n "$name" ]]; do
    [[ -n "$name" ]] || continue
    if ! is_entry_name "$name"; then
      echo "error: snapshot entry is not a safe name: $name" >&2
      return 1
    fi
    names+=("$name")
    in_snapshot["$name"]=1
  done < <(snapshot_entry_names "$src")

  if [[ "$drop_extra" == "true" && -f "$SITE_ROOT/$PUBLISH_INCOMING_NAME" ]]; then
    while IFS= read -r name || [[ -n "$name" ]]; do
      name="${name%$'\r'}"
      [[ -n "$name" ]] || continue
      if ! is_entry_name "$name"; then
        echo "error: $PUBLISH_INCOMING_NAME contains an unsafe name: $name" >&2
        return 1
      fi
    done <"$SITE_ROOT/$PUBLISH_INCOMING_NAME"
  fi

  mkdir -p "$trash" || return 1
  for name in "${names[@]+"${names[@]}"}"; do
    dest="$SITE_ROOT/$name"
    if [[ -e "$dest" || -L "$dest" ]]; then
      command mv -- "$dest" "$trash/$name" || {
        undo_snapshot_apply "$src" "$trash" "${applied[@]+"${applied[@]}"}"
        return 1
      }
    fi
    if ! command mv -- "$src/$name" "$dest"; then
      if [[ -e "$trash/$name" || -L "$trash/$name" ]]; then
        command mv -- "$trash/$name" "$dest" || true
      fi
      undo_snapshot_apply "$src" "$trash" "${applied[@]+"${applied[@]}"}"
      return 1
    fi
    applied+=("$name")
  done

  if [[ "$drop_extra" == "true" && -f "$SITE_ROOT/$PUBLISH_INCOMING_NAME" ]]; then
    while IFS= read -r extra || [[ -n "$extra" ]]; do
      extra="${extra%$'\r'}"
      [[ -n "$extra" ]] || continue
      [[ -n "${in_snapshot[$extra]+x}" ]] && continue
      dest="$SITE_ROOT/$extra"
      [[ -e "$dest" || -L "$dest" ]] || continue
      if ! command mv -- "$dest" "$trash/$extra"; then
        undo_snapshot_apply "$src" "$trash" "${applied[@]+"${applied[@]}"}" "${extras[@]+"${extras[@]}"}"
        return 1
      fi
      extras+=("$extra")
    done <"$SITE_ROOT/$PUBLISH_INCOMING_NAME"
  fi

  if ! rmdir -- "$src"; then
    echo "error: snapshot $src was not empty after restore" >&2
    return 1
  fi
  rm -rf -- "$trash" || return 1
  rm -f -- "$SITE_ROOT/$PUBLISH_INCOMING_NAME" "$SITE_ROOT/$PUBLISH_PARKED_NAME" || return 1
  remove_staging
  remove_work_globs
  remove_failed_globs
}

restore_previous_snapshot() {
  local src="$1"
  local drop="false"
  [[ -d "$src" ]] || return 0
  if [[ -f "$SITE_ROOT/$PUBLISH_PARKED_NAME" ]]; then
    drop="true"
  fi
  apply_snapshot "$src" "$drop"
}

park_managed_entries() {
  local dest="$1"
  local name src
  for name in "${PUBLISH_MANAGED[@]}"; do
    src="$SITE_ROOT/$name"
    [[ -e "$src" || -L "$src" ]] || continue
    relocate_entry -- "$src" "$dest/$name" || return 1
  done
}

promote_staging_entries() {
  local item base
  local -a items=()
  shopt -s nullglob
  items=("$PUBLISH_STAGING"/* "$PUBLISH_STAGING"/.[!.]* "$PUBLISH_STAGING"/..?*)
  shopt -u nullglob
  for item in "${items[@]}"; do
    [[ -e "$item" || -L "$item" ]] || continue
    base="$(basename "$item")"
    if ! is_entry_name "$base"; then
      echo "error: staged entry is not a safe name: $base" >&2
      return 1
    fi
    relocate_entry -- "$item" "$SITE_ROOT/$base" || return 1
  done
  rmdir -- "$PUBLISH_STAGING" || return 1
  PUBLISH_STAGING=""
}

remove_work_globs() {
  local item
  local -a leftovers=()
  shopt -s nullglob
  leftovers=("$SITE_ROOT"/.staging.* "$SITE_ROOT"/.activating.*)
  shopt -u nullglob
  for item in "${leftovers[@]+"${leftovers[@]}"}"; do
    rm -rf -- "$item"
  done
  PUBLISH_STAGING=""
}

remove_failed_globs() {
  local item
  local -a leftovers=()
  shopt -s nullglob
  leftovers=("$SITE_ROOT"/.failed.*)
  shopt -u nullglob
  for item in "${leftovers[@]+"${leftovers[@]}"}"; do
    rm -rf -- "$item"
  done
}

publish_on_exit() {
  local status=$?
  trap - EXIT
  set +e
  case "${PUBLISH_PHASE:-}" in
    parking|demos_aside|swapped)
      if [[ -n "${PUBLISH_PREVIOUS:-}" ]]; then
        restore_previous_snapshot "$PUBLISH_PREVIOUS"
      fi
      ;;
    staging) remove_staging ;;
  esac
  exit "$status"
}

remove_snapshot_globs() {
  local item
  local -a leftovers=()
  shopt -s nullglob
  leftovers=("$SITE_ROOT/.previous."* "$SITE_ROOT/.staging."* "$SITE_ROOT/.activating."* "$SITE_ROOT/.failed."*)
  shopt -u nullglob
  for item in "${leftovers[@]}"; do
    rm -rf -- "$item"
  done
}

recover_orphaned_previous() {
  local item
  local -a leftovers=()
  shopt -s nullglob
  leftovers=("$SITE_ROOT"/.previous.*)
  shopt -u nullglob

  if [[ -f "$SITE_ROOT/$PUBLISH_OK_NAME" ]]; then
    remove_snapshot_globs
    rm -f -- "$SITE_ROOT/$PUBLISH_INCOMING_NAME" "$SITE_ROOT/$PUBLISH_PARKED_NAME"
    return 0
  fi
  if [[ -f "$SITE_ROOT/demos/$PUBLISH_OK_NAME" && ! -f "$SITE_ROOT/$PUBLISH_INCOMING_NAME" && ! -f "$SITE_ROOT/$PUBLISH_PARKED_NAME" ]]; then
    remove_snapshot_globs
    return 0
  fi
  if [[ ${#leftovers[@]} -gt 1 ]]; then
    echo "error: SITE_ROOT has no committed publish marker and more than one previous snapshot exists" >&2
    return 1
  fi
  if [[ ${#leftovers[@]} -eq 1 ]]; then
    if [[ ! -d "${leftovers[0]}" ]]; then
      echo "error: previous snapshot is not a directory: ${leftovers[0]}" >&2
      return 1
    fi
    restore_previous_snapshot "${leftovers[0]}" || return 1
    echo "restored site from ${leftovers[0]}" >&2
  fi
  shopt -s nullglob
  leftovers=("$SITE_ROOT"/.staging.* "$SITE_ROOT"/.activating.*)
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
  cp -a "$dist"/. "$PUBLISH_STAGING/" || return 1
  chmod -R a+rX "$PUBLISH_STAGING" || return 1
}

activate_staged_tree() {
  local activating="$SITE_ROOT/.activating.$$"
  collect_managed_names || return 1
  assert_managed_filesystem || return 1
  rm -rf -- "$PUBLISH_PREVIOUS" "$activating"
  mkdir -p "$PUBLISH_PREVIOUS" || return 1
  if ! write_incoming_plan; then
    rmdir -- "$PUBLISH_PREVIOUS" 2>/dev/null || rm -rf -- "$PUBLISH_PREVIOUS"
    return 1
  fi
  PUBLISH_PHASE=parking
  if ! park_managed_entries "$PUBLISH_PREVIOUS"; then
    return 1
  fi
  if ! write_parked_marker; then
    return 1
  fi
  PUBLISH_PHASE=demos_aside
  if declare -F publish_after_park >/dev/null; then
    publish_after_park || return 1
  fi
  move_into_place "$PUBLISH_STAGING" "$activating" || return 1
  PUBLISH_STAGING="$activating"
  promote_staging_entries || return 1
  PUBLISH_PHASE=swapped
}

commit_publish() {
  local item
  local -a leftovers=()
  write_lines_file "$SITE_ROOT/$PUBLISH_DEMOS_NAME" "${PUBLISH_DEMOS[@]}" || return 1
  write_lines_file "$SITE_ROOT/$PUBLISH_OK_NAME" "ok" || return 1
  rm -f -- "$SITE_ROOT/$PUBLISH_INCOMING_NAME" "$SITE_ROOT/$PUBLISH_PARKED_NAME" || return 1
  PUBLISH_PHASE=committed
  trap - EXIT
  shopt -s nullglob
  leftovers=("$SITE_ROOT"/.previous.*)
  shopt -u nullglob
  for item in "${leftovers[@]+"${leftovers[@]}"}"; do
    rm -rf -- "$item" || return 1
  done
  PUBLISH_STAGING=""
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
  fetch_url "${SITE_URL}/" "$work/catalog.html" || return 1
  for name in "${PUBLISH_DEMOS[@]}"; do
    if ! grep -Fq "href=\"/${name}/\"" "$work/catalog.html"; then
      echo "error: ${SITE_URL}/ is missing href=\"/${name}/\"" >&2
      return 1
    fi
    fetch_url "${SITE_URL}/${name}/" "$work/${name}.html" || return 1
    if ! demo_html_has_asset "$work/${name}.html" "$name"; then
      echo "error: ${SITE_URL}/${name}/ has no script or link asset under /${name}/" >&2
      return 1
    fi
    mapfile -t assets < <(collect_asset_urls "$work/${name}.html" "$name")
    if [[ ${#assets[@]} -eq 0 ]]; then
      echo "error: ${SITE_URL}/${name}/ has no asset URLs under /${name}/" >&2
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
  echo "published ${#PUBLISH_DEMOS[@]} demos to $SITE_ROOT"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  publish_site_main
fi
