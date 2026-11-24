#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=publish-site.sh
source "$REPO/scripts/publish-site.sh"

servers=()
cleanup_servers() {
  local pid
  for pid in "${servers[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
}
trap cleanup_servers EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

ok() {
  echo "ok: $*"
}

expect_fail() {
  local label="$1"
  shift
  if "$@"; then
    fail "$label unexpectedly succeeded"
  fi
  ok "$label"
}

no_snapshots() {
  local site="$1"
  local -a staging=() previous=()
  shopt -s nullglob
  staging=("$site".staging.*)
  previous=("$site".previous.*)
  shopt -u nullglob
  [[ ${#staging[@]} -eq 0 && ${#previous[@]} -eq 0 ]]
}

make_example() {
  local root="$1"
  local name="$2"
  local html="$3"
  mkdir -p "$root/examples/$name/dist/assets"
  printf '%s\n' "$html" >"$root/examples/$name/dist/index.html"
  printf '%s\n' "{\"name\":\"$name\",\"private\":true}" >"$root/examples/$name/package.json"
  printf '%s\n' 'console.log("asset")' >"$root/examples/$name/dist/assets/app.js"
  printf '%s\n' 'body{color:black}' >"$root/examples/$name/dist/assets/app.css"
}

vite_html() {
  local name="$1"
  printf '%s\n' \
    "<!doctype html><link rel=\"stylesheet\" href=\"/demos/${name}/assets/app.css\"><script type=\"module\" crossorigin src=\"/demos/${name}/assets/app.js\"></script>"
}

start_server() {
  local site="$1"
  local mode="$2"
  local out pid port="" i
  out="$(mktemp)"
  node "$REPO/scripts/publish-site-fixture.mjs" "$site" "$mode" >"$out" &
  pid=$!
  servers+=("$pid")
  for ((i = 0; i < 100; i++)); do
    if [[ -s "$out" ]]; then
      port="$(head -n 1 "$out")"
      break
    fi
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      echo "fixture server exited" >&2
      cat "$out" >&2 || true
      return 1
    fi
    sleep 0.05
  done
  [[ -n "$port" ]] || {
    echo "fixture server did not report a port" >&2
    return 1
  }
  printf '%s\n' "$port"
}

prepare_repo() {
  local root="$1"
  shift
  local name
  for name in "$@"; do
    make_example "$root" "$name" "$(vite_html "$name")"
  done
}

expect_fail "empty SITE_ROOT" validate_site_root ""
expect_fail "relative SITE_ROOT" validate_site_root "relative/site"
expect_fail "root filesystem SITE_ROOT" validate_site_root "/"
expect_fail "trailing slash SITE_ROOT" validate_site_root "/var/www/toolcraft.ermolaev.site/"
expect_fail "dotdot SITE_ROOT" validate_site_root "/var/www/../www/toolcraft.ermolaev.site"
expect_fail "empty SITE_URL" validate_site_url ""
expect_fail "SITE_URL with trailing slash" validate_site_url "https://toolcraft.ermolaev.site/"
expect_fail "SITE_URL with a path" validate_site_url "https://toolcraft.ermolaev.site/demos"
validate_site_root "/var/www/toolcraft.ermolaev.site"
validate_site_url "https://toolcraft.ermolaev.site"
ok "SITE_ROOT and SITE_URL validation"

[[ "$(location_path "https://toolcraft.ermolaev.site/demos/")" == "/demos/" ]]
[[ "$(location_path "https://toolcraft.ermolaev.site/demos")" == "/demos/" ]]
[[ "$(location_path "/demos/")" == "/demos/" ]]
[[ "$(location_path "/demos?x=1")" == "/demos/" ]]
[[ "$(location_path "/elsewhere/")" == "/elsewhere/" ]]
ok "redirect location paths"

asset_dir="$(mktemp -d)"
printf '%s\n' '<p>See /demos/glass/assets/app.js</p>' >"$asset_dir/loose.html"
printf '%s\n' '<p>See /demos/axb/assets/app.js</p>' >"$asset_dir/wrong-dot.html"
vite_html "glass" >"$asset_dir/glass.html"
vite_html "a.b" >"$asset_dir/dotted.html"
expect_fail "plain-text base path" demo_html_has_asset "$asset_dir/loose.html" "glass"
expect_fail "dotted name does not match another slug" demo_html_has_asset "$asset_dir/wrong-dot.html" "a.b"
demo_html_has_asset "$asset_dir/glass.html" "glass"
demo_html_has_asset "$asset_dir/dotted.html" "a.b"
[[ "$(demo_asset_path "$asset_dir/glass.html" "glass")" == "/demos/glass/assets/app.js" ]] || fail "glass asset path"
[[ "$(demo_asset_path "$asset_dir/dotted.html" "a.b")" == "/demos/a.b/assets/app.js" ]] || fail "dotted asset path"
ok "asset URL must be a script or link, including dotted names"

slug_root="$(mktemp -d)"
mkdir -p "$slug_root/examples/foo bar"
printf '%s\n' '{"name":"bad"}' >"$slug_root/examples/foo bar/package.json"
(
  PUBLISH_ROOT="$slug_root"
  read_example_names "$slug_root"
) && fail "unsafe example name should fail"
ok "example names must be slugs"

missing_root="$(mktemp -d)"
missing_site="$(mktemp -d)/site"
prepare_repo "$missing_root" "glass"
rm -rf -- "$missing_root/examples/glass/dist"
(
  PUBLISH_ROOT="$missing_root"
  DIST_SITE="$missing_root/dist-site"
  SITE_ROOT="$missing_site"
  SITE_URL="http://127.0.0.1:9"
  publish_site_main
) && fail "missing dist should fail"
[[ ! -e "$missing_site" ]]
ok "missing dist does not publish"

bad_base_root="$(mktemp -d)"
bad_base_parent="$(mktemp -d)"
bad_base_site="$bad_base_parent/site"
mkdir -p "$bad_base_site"
echo old >"$bad_base_site/marker"
make_example "$bad_base_root" "glass" "<p>/demos/glass/assets/app.js</p>"
(
  PUBLISH_ROOT="$bad_base_root"
  DIST_SITE="$bad_base_root/dist-site"
  SITE_ROOT="$bad_base_site"
  SITE_URL="http://127.0.0.1:9"
  publish_site_main
) && fail "text mention of the base path should fail"
[[ "$(cat "$bad_base_site/marker")" == "old" ]]
no_snapshots "$bad_base_site"
ok "Vite base must be a script or stylesheet URL"

second_mv_root="$(mktemp -d)"
second_mv_parent="$(mktemp -d)"
second_mv_site="$second_mv_parent/site"
mkdir -p "$second_mv_site"
echo old >"$second_mv_site/marker"
prepare_repo "$second_mv_root" "glass"
(
  PUBLISH_ROOT="$second_mv_root"
  DIST_SITE="$second_mv_root/dist-site"
  SITE_ROOT="$second_mv_site"
  move_into_place() {
    if [[ "${2:-}" == "$SITE_ROOT" ]]; then
      echo "injected failure to move staging into place" >&2
      return 1
    fi
    command mv "$@"
  }
  read_example_names "$second_mv_root"
  assert_example_dist "$second_mv_root"
  write_dist_site "$second_mv_root" "$DIST_SITE"
  assert_publish_target
  stage_dist "$DIST_SITE"
  activate_staged_tree
) && fail "second mv should fail"
[[ "$(cat "$second_mv_site/marker")" == "old" ]]
no_snapshots "$second_mv_site"
ok "failed second mv restores the live site"

signal_root="$(mktemp -d)"
signal_parent="$(mktemp -d)"
signal_site="$signal_parent/site"
mkdir -p "$signal_site"
echo old >"$signal_site/marker"
prepare_repo "$signal_root" "glass"
(
  PUBLISH_ROOT="$signal_root"
  DIST_SITE="$signal_root/dist-site"
  SITE_ROOT="$signal_site"
  publish_after_park() { kill -TERM "$BASHPID"; }
  read_example_names "$signal_root"
  assert_example_dist "$signal_root"
  write_dist_site "$signal_root" "$DIST_SITE"
  assert_publish_target
  stage_dist "$DIST_SITE"
  activate_staged_tree
) && fail "SIGTERM between renames should abort"
[[ "$(cat "$signal_site/marker")" == "old" ]]
no_snapshots "$signal_site"
ok "SIGTERM between renames restores the live site"

orphan_parent="$(mktemp -d)"
orphan_site="$orphan_parent/site"
mkdir -p "$orphan_site.previous.999"
echo old >"$orphan_site.previous.999/marker"
(
  SITE_ROOT="$orphan_site"
  recover_orphaned_previous
)
[[ "$(cat "$orphan_site/marker")" == "old" ]]
[[ ! -e "$orphan_site.previous.999" ]]
ok "orphaned previous snapshot is restored"

live_parent="$(mktemp -d)"
live_site="$live_parent/site"
mkdir -p "$live_site" "$live_site.previous.999"
echo live >"$live_site/marker"
echo stale >"$live_site.previous.999/marker"
(
  SITE_ROOT="$live_site"
  recover_orphaned_previous
)
[[ "$(cat "$live_site/marker")" == "live" ]]
[[ ! -e "$live_site.previous.999" ]]
ok "leftover previous snapshot is removed when the live root exists"

many_parent="$(mktemp -d)"
many_site="$many_parent/site"
mkdir -p "$many_site.previous.1" "$many_site.previous.2"
if (
  SITE_ROOT="$many_site"
  recover_orphaned_previous
); then
  fail "multiple orphaned snapshots should fail"
fi
[[ -d "$many_site.previous.1" && -d "$many_site.previous.2" && ! -e "$many_site" ]]
ok "multiple orphaned snapshots stay untouched"

if ln -s "$live_site" "$live_parent/link-site" 2>/dev/null && [[ -L "$live_parent/link-site" ]]; then
  (
    SITE_ROOT="$live_parent/link-site"
    assert_publish_target
  ) && fail "symlink SITE_ROOT should fail"
  [[ -L "$live_parent/link-site" ]]
  ok "symlink SITE_ROOT is refused"
else
  ok "symlink SITE_ROOT check skipped where the shell cannot create a symlink"
fi

success_tmp="$(mktemp -d)"
success_root="$success_tmp/repo"
success_site="$success_tmp/www/site"
mkdir -p "$success_tmp/www" "$success_site"
echo old >"$success_site/marker"
prepare_repo "$success_root" "glass" "a.b"
success_port="$(start_server "$success_site" "ok")"
(
  PUBLISH_ROOT="$success_root"
  DIST_SITE="$success_root/dist-site"
  SITE_ROOT="$success_site"
  SITE_URL="http://127.0.0.1:${success_port}"
  publish_site_main
)
[[ ! -f "$success_site/marker" ]]
[[ ! -f "$success_site/index.html" ]]
grep -Fq '<ol>' "$success_site/demos/index.html"
grep -Fq '<li><a href="/demos/glass/">/demos/glass/</a></li>' "$success_site/demos/index.html"
grep -Fq '<li><a href="/demos/a.b/">/demos/a.b/</a></li>' "$success_site/demos/index.html"
grep -Fq '/demos/glass/assets/app.js' "$success_site/demos/glass/index.html"
[[ -f "$success_site/demos/a.b/assets/app.js" ]]
no_snapshots "$success_site"
ok "successful publish keeps the new tree and drops the previous snapshot"

rollback_tmp="$(mktemp -d)"
rollback_root="$rollback_tmp/repo"
rollback_site="$rollback_tmp/www/site"
mkdir -p "$rollback_tmp/www" "$rollback_site"
echo old >"$rollback_site/marker"
prepare_repo "$rollback_root" "glass" "a.b"
rollback_port="$(start_server "$rollback_site" "bad-asset")"
(
  PUBLISH_ROOT="$rollback_root"
  DIST_SITE="$rollback_root/dist-site"
  SITE_ROOT="$rollback_site"
  SITE_URL="http://127.0.0.1:${rollback_port}"
  publish_site_main
) && fail "missing asset should fail smoke"
[[ "$(cat "$rollback_site/marker")" == "old" ]]
no_snapshots "$rollback_site"
ok "failed asset smoke restores the previous site"

noredir_tmp="$(mktemp -d)"
noredir_root="$noredir_tmp/repo"
noredir_site="$noredir_tmp/www/site"
mkdir -p "$noredir_tmp/www" "$noredir_site"
echo old >"$noredir_site/marker"
prepare_repo "$noredir_root" "glass"
noredir_port="$(start_server "$noredir_site" "no-redirect")"
(
  PUBLISH_ROOT="$noredir_root"
  DIST_SITE="$noredir_root/dist-site"
  SITE_ROOT="$noredir_site"
  SITE_URL="http://127.0.0.1:${noredir_port}"
  publish_site_main
) && fail "HTTP 200 at / should fail smoke"
[[ "$(cat "$noredir_site/marker")" == "old" ]]
no_snapshots "$noredir_site"
ok "root without an HTTP redirect restores the previous site"

badloc_tmp="$(mktemp -d)"
badloc_root="$badloc_tmp/repo"
badloc_site="$badloc_tmp/www/site"
mkdir -p "$badloc_tmp/www" "$badloc_site"
echo old >"$badloc_site/marker"
prepare_repo "$badloc_root" "glass"
badloc_port="$(start_server "$badloc_site" "bad-location")"
(
  PUBLISH_ROOT="$badloc_root"
  DIST_SITE="$badloc_root/dist-site"
  SITE_ROOT="$badloc_site"
  SITE_URL="http://127.0.0.1:${badloc_port}"
  publish_site_main
) && fail "redirect to the wrong path should fail smoke"
[[ "$(cat "$badloc_site/marker")" == "old" ]]
no_snapshots "$badloc_site"
ok "wrong redirect location restores the previous site"

echo "publish-site tests passed"
