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
  local -a staging=() previous=() failed=() activating=()
  shopt -s nullglob
  staging=("$site"/.staging.*)
  previous=("$site"/.previous.*)
  failed=("$site"/.failed.*)
  activating=("$site"/.activating.*)
  shopt -u nullglob
  [[ ${#staging[@]} -eq 0 && ${#previous[@]} -eq 0 && ${#failed[@]} -eq 0 && ${#activating[@]} -eq 0 ]]
}

seed_site() {
  local site="$1"
  mkdir -p "$site"
  printf '%s\n' old >"$site/index.html"
  printf '%s\n' keep >"$site/keep"
}

expect_previous_site() {
  local site="$1"
  [[ "$(cat "$site/index.html")" == "old" ]]
  [[ "$(cat "$site/keep")" == "keep" ]]
  [[ ! -f "$site/.publish-ok" ]]
  [[ ! -e "$site/.publish-incoming" ]]
  [[ ! -e "$site/.publish-parked" ]]
  [[ ! -e "$site/glass" ]]
  [[ ! -e "$site/a.b" ]]
  [[ ! -d "$site/glass/glass" ]]
  no_snapshots "$site"
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
    "<!doctype html><link rel=\"stylesheet\" href=\"/${name}/assets/app.css\"><script type=\"module\" crossorigin src=\"/${name}/assets/app.js\"></script>"
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

asset_dir="$(mktemp -d)"
printf '%s\n' '<p>See /glass/assets/app.js</p>' >"$asset_dir/loose.html"
printf '%s\n' '<p>See /axb/assets/app.js</p>' >"$asset_dir/wrong-dot.html"
vite_html "glass" >"$asset_dir/glass.html"
vite_html "a.b" >"$asset_dir/dotted.html"
expect_fail "plain-text base path" demo_html_has_asset "$asset_dir/loose.html" "glass"
expect_fail "dotted name does not match another slug" demo_html_has_asset "$asset_dir/wrong-dot.html" "a.b"
demo_html_has_asset "$asset_dir/glass.html" "glass"
demo_html_has_asset "$asset_dir/dotted.html" "a.b"
[[ "$(demo_asset_path "$asset_dir/glass.html" "glass")" == "/glass/assets/app.js" ]] || fail "glass asset path"
[[ "$(demo_asset_path "$asset_dir/dotted.html" "a.b")" == "/a.b/assets/app.js" ]] || fail "dotted asset path"
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
seed_site "$bad_base_site"
make_example "$bad_base_root" "glass" "<p>/glass/assets/app.js</p>"
(
  PUBLISH_ROOT="$bad_base_root"
  DIST_SITE="$bad_base_root/dist-site"
  SITE_ROOT="$bad_base_site"
  SITE_URL="http://127.0.0.1:9"
  publish_site_main
) && fail "text mention of the base path should fail"
expect_previous_site "$bad_base_site"
ok "Vite base must be a script or stylesheet URL"

second_mv_root="$(mktemp -d)"
second_mv_parent="$(mktemp -d)"
second_mv_site="$second_mv_parent/site"
seed_site "$second_mv_site"
prepare_repo "$second_mv_root" "glass"
(
  PUBLISH_ROOT="$second_mv_root"
  DIST_SITE="$second_mv_root/dist-site"
  SITE_ROOT="$second_mv_site"
  move_into_place() {
    case "${2:-}" in
      "$SITE_ROOT"/.activating.*)
        echo "injected failure to move staging into place" >&2
        return 1
        ;;
    esac
    command mv "$@"
  }
  read_example_names "$second_mv_root"
  assert_example_dist "$second_mv_root"
  write_dist_site "$second_mv_root" "$DIST_SITE"
  assert_publish_target
  stage_dist "$DIST_SITE"
  activate_staged_tree
) && fail "second mv should fail"
expect_previous_site "$second_mv_site"
ok "failed second mv restores the live site tree"

park_fail_root="$(mktemp -d)"
park_fail_parent="$(mktemp -d)"
park_fail_site="$park_fail_parent/site"
seed_site "$park_fail_site"
mkdir -p "$park_fail_site/glass"
printf '%s\n' stay >"$park_fail_site/glass/marker"
prepare_repo "$park_fail_root" "glass"
(
  PUBLISH_ROOT="$park_fail_root"
  DIST_SITE="$park_fail_root/dist-site"
  SITE_ROOT="$park_fail_site"
  relocate_entry() {
    case "${2:-}" in
      */glass)
        echo "injected park failure" >&2
        return 1
        ;;
    esac
    command mv "$@"
  }
  read_example_names "$park_fail_root"
  assert_example_dist "$park_fail_root"
  write_dist_site "$park_fail_root" "$DIST_SITE"
  assert_publish_target
  stage_dist "$DIST_SITE"
  activate_staged_tree
) && fail "park should fail when a managed mv fails"
[[ "$(cat "$park_fail_site/index.html")" == "old" ]]
[[ "$(cat "$park_fail_site/glass/marker")" == "stay" ]]
[[ "$(cat "$park_fail_site/keep")" == "keep" ]]
[[ ! -e "$park_fail_site/.publish-incoming" ]]
[[ ! -e "$park_fail_site/.publish-parked" ]]
no_snapshots "$park_fail_site"
ok "failed park restores entries already moved aside"

promote_fail_root="$(mktemp -d)"
promote_fail_parent="$(mktemp -d)"
promote_fail_site="$promote_fail_parent/site"
seed_site "$promote_fail_site"
mkdir -p "$promote_fail_site/glass"
printf '%s\n' oldglass >"$promote_fail_site/glass/marker"
prepare_repo "$promote_fail_root" "glass" "a.b"
(
  PUBLISH_ROOT="$promote_fail_root"
  DIST_SITE="$promote_fail_root/dist-site"
  SITE_ROOT="$promote_fail_site"
  relocate_entry() {
    case "${2:-}" in
      "$SITE_ROOT"/glass|"$SITE_ROOT"/a.b)
        echo "injected promote failure" >&2
        return 1
        ;;
    esac
    command mv "$@"
  }
  read_example_names "$promote_fail_root"
  assert_example_dist "$promote_fail_root"
  write_dist_site "$promote_fail_root" "$DIST_SITE"
  assert_publish_target
  stage_dist "$DIST_SITE"
  activate_staged_tree
) && fail "promote should fail when a staged mv fails"
[[ "$(cat "$promote_fail_site/index.html")" == "old" ]]
[[ "$(cat "$promote_fail_site/glass/marker")" == "oldglass" ]]
[[ ! -e "$promote_fail_site/glass/glass" ]]
[[ ! -e "$promote_fail_site/a.b" ]]
[[ "$(cat "$promote_fail_site/keep")" == "keep" ]]
[[ ! -e "$promote_fail_site/.publish-incoming" ]]
[[ ! -e "$promote_fail_site/.publish-parked" ]]
no_snapshots "$promote_fail_site"
ok "failed promote replaces partial new entries with the previous tree"

signal_root="$(mktemp -d)"
signal_parent="$(mktemp -d)"
signal_site="$signal_parent/site"
seed_site "$signal_site"
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
expect_previous_site "$signal_site"
ok "SIGTERM between renames restores the live site tree"

orphan_parent="$(mktemp -d)"
orphan_site="$orphan_parent/site"
mkdir -p "$orphan_site/.previous.999"
echo old >"$orphan_site/.previous.999/index.html"
(
  SITE_ROOT="$orphan_site"
  recover_orphaned_previous
)
[[ "$(cat "$orphan_site/index.html")" == "old" ]]
[[ ! -e "$orphan_site/.previous.999" ]]
ok "orphaned previous snapshot is restored"

live_parent="$(mktemp -d)"
live_site="$live_parent/site"
mkdir -p "$live_site" "$live_site/.previous.999"
printf '%s\n' ok >"$live_site/.publish-ok"
echo live >"$live_site/index.html"
echo stale >"$live_site/.previous.999/index.html"
(
  SITE_ROOT="$live_site"
  recover_orphaned_previous
)
[[ "$(cat "$live_site/index.html")" == "live" ]]
[[ ! -e "$live_site/.previous.999" ]]
ok "leftover previous snapshot is removed when the live site is committed"

uncommitted_parent="$(mktemp -d)"
uncommitted_site="$uncommitted_parent/site"
mkdir -p "$uncommitted_site" "$uncommitted_site/.previous.7"
echo bad >"$uncommitted_site/index.html"
echo good >"$uncommitted_site/.previous.7/index.html"
printf '%s\n' ok >"$uncommitted_site/.previous.7/.publish-ok"
(
  SITE_ROOT="$uncommitted_site"
  recover_orphaned_previous
)
[[ "$(cat "$uncommitted_site/index.html")" == "good" ]]
[[ -f "$uncommitted_site/.publish-ok" ]]
[[ ! -e "$uncommitted_site/.previous.7" ]]
ok "uncommitted site tree is replaced by the previous snapshot"

initial_parent="$(mktemp -d)"
initial_site="$initial_parent/site"
mkdir -p "$initial_site"
echo hand >"$initial_site/index.html"
(
  SITE_ROOT="$initial_site"
  recover_orphaned_previous
)
[[ "$(cat "$initial_site/index.html")" == "hand" ]]
ok "initial site tree without a snapshot is left in place"

many_parent="$(mktemp -d)"
many_site="$many_parent/site"
mkdir -p "$many_site/.previous.1" "$many_site/.previous.2"
if (
  SITE_ROOT="$many_site"
  recover_orphaned_previous
); then
  fail "multiple orphaned snapshots should fail"
fi
[[ -d "$many_site/.previous.1" && -d "$many_site/.previous.2" && ! -f "$many_site/.publish-ok" ]]
ok "multiple orphaned snapshots stay untouched"

legacy_parent="$(mktemp -d)"
legacy_site="$legacy_parent/site"
mkdir -p "$legacy_site/demos" "$legacy_site/.previous.3"
printf '%s\n' ok >"$legacy_site/demos/.publish-ok"
printf '%s\n' live >"$legacy_site/demos/marker"
printf '%s\n' stale >"$legacy_site/.previous.3/index.html"
(
  SITE_ROOT="$legacy_site"
  recover_orphaned_previous
)
[[ "$(cat "$legacy_site/demos/marker")" == "live" ]]
[[ -f "$legacy_site/demos/.publish-ok" ]]
[[ ! -e "$legacy_site/.previous.3" ]]
[[ ! -e "$legacy_site/index.html" ]]
ok "committed legacy demos tree is kept and leftover snapshots are removed"

nest_parent="$(mktemp -d)"
nest_site="$nest_parent/site"
mkdir -p "$nest_site/glass" "$nest_site/ascii" "$nest_site/.previous.5/glass"
printf '%s\n' NEW >"$nest_site/glass/index.html"
printf '%s\n' OLD >"$nest_site/.previous.5/glass/index.html"
printf '%s\n' NEWCAT >"$nest_site/index.html"
printf '%s\n' OLDCAT >"$nest_site/.previous.5/index.html"
printf '%s\n' ok >"$nest_site/.previous.5/.publish-ok"
printf '%s\n' glass >"$nest_site/.previous.5/.publish-demos"
printf '%s\n' index.html .publish-ok .publish-demos demos glass ascii >"$nest_site/.publish-incoming"
printf '%s\n' parked >"$nest_site/.publish-parked"
printf '%s\n' keep >"$nest_site/keep"
(
  SITE_ROOT="$nest_site"
  recover_orphaned_previous
)
[[ "$(cat "$nest_site/index.html")" == "OLDCAT" ]]
[[ "$(cat "$nest_site/glass/index.html")" == "OLD" ]]
[[ ! -e "$nest_site/glass/glass" ]]
[[ ! -e "$nest_site/ascii" ]]
[[ -f "$nest_site/.publish-ok" ]]
[[ "$(cat "$nest_site/keep")" == "keep" ]]
[[ ! -e "$nest_site/.previous.5" ]]
[[ ! -e "$nest_site/.publish-incoming" ]]
[[ ! -e "$nest_site/.publish-parked" ]]
no_snapshots "$nest_site"
ok "uncommitted swap restores previous directories without nesting"

midpark_parent="$(mktemp -d)"
midpark_site="$midpark_parent/site"
mkdir -p "$midpark_site/glass" "$midpark_site/.previous.4"
printf '%s\n' stay >"$midpark_site/glass/marker"
printf '%s\n' oldindex >"$midpark_site/.previous.4/index.html"
printf '%s\n' index.html glass >"$midpark_site/.publish-incoming"
(
  SITE_ROOT="$midpark_site"
  recover_orphaned_previous
)
[[ "$(cat "$midpark_site/index.html")" == "oldindex" ]]
[[ "$(cat "$midpark_site/glass/marker")" == "stay" ]]
[[ ! -e "$midpark_site/.previous.4" ]]
[[ ! -e "$midpark_site/.publish-incoming" ]]
[[ ! -e "$midpark_site/.publish-parked" ]]
no_snapshots "$midpark_site"
ok "interrupted park puts moved entries back and leaves the rest"

poison_parent="$(mktemp -d)"
poison_site="$poison_parent/site"
mkdir -p "$poison_site/glass" "$poison_site/.previous.8/glass"
printf '%s\n' NEW >"$poison_site/glass/index.html"
printf '%s\n' OLD >"$poison_site/.previous.8/glass/index.html"
printf '%s\n' '..' >"$poison_site/.publish-incoming"
printf '%s\n' parked >"$poison_site/.publish-parked"
(
  SITE_ROOT="$poison_site"
  recover_orphaned_previous
) && fail "unsafe incoming name should fail recovery"
[[ "$(cat "$poison_site/glass/index.html")" == "NEW" ]]
[[ "$(cat "$poison_site/.previous.8/glass/index.html")" == "OLD" ]]
[[ ! -e "$poison_site/glass/glass" ]]
[[ -d "$poison_site/.previous.8" ]]
ok "unsafe publish plan is refused before snapshot entries move"

fs_root="$(mktemp -d)"
fs_parent="$(mktemp -d)"
fs_site="$fs_parent/site"
seed_site "$fs_site"
mkdir -p "$fs_site/glass"
printf '%s\n' stay >"$fs_site/glass/marker"
prepare_repo "$fs_root" "glass"
(
  PUBLISH_ROOT="$fs_root"
  DIST_SITE="$fs_root/dist-site"
  SITE_ROOT="$fs_site"
  filesystem_id() {
    case "$1" in
      "$SITE_ROOT"/glass) printf '%s\n' 2 ;;
      *) printf '%s\n' 1 ;;
    esac
  }
  read_example_names "$fs_root"
  assert_example_dist "$fs_root"
  write_dist_site "$fs_root" "$DIST_SITE"
  assert_publish_target
  stage_dist "$DIST_SITE"
  activate_staged_tree
) && fail "cross-filesystem managed entry should fail"
[[ "$(cat "$fs_site/index.html")" == "old" ]]
[[ "$(cat "$fs_site/glass/marker")" == "stay" ]]
[[ "$(cat "$fs_site/keep")" == "keep" ]]
[[ ! -e "$fs_site/.publish-incoming" ]]
no_snapshots "$fs_site"
ok "managed entry on another filesystem is left in place"

manifest_root="$(mktemp -d)"
manifest_parent="$(mktemp -d)"
manifest_site="$manifest_parent/site"
seed_site "$manifest_site"
prepare_repo "$manifest_root" "glass"
printf '%s\n' '..' >"$manifest_site/.publish-demos"
(
  PUBLISH_ROOT="$manifest_root"
  DIST_SITE="$manifest_root/dist-site"
  SITE_ROOT="$manifest_site"
  SITE_URL="http://127.0.0.1:9"
  publish_site_main
) && fail "unsafe manifest name should fail"
[[ "$(cat "$manifest_site/index.html")" == "old" ]]
[[ "$(cat "$manifest_site/keep")" == "keep" ]]
[[ -d "$manifest_site" ]]
no_snapshots "$manifest_site"
ok "unsafe demo manifest is refused before the live tree changes"

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
mkdir -p "$success_tmp/www"
seed_site "$success_site"
prepare_repo "$success_root" "glass" "a.b"
mkdir -p "$success_root/screenshots"
node -e "require('fs').writeFileSync(process.argv[1], Buffer.from('UklGRiQAAABXRUJQVlA4IBgAAAAwAQCdASoBAAEAAwA0JaQAA3AA/vuUAAA=','base64'))" "$success_root/screenshots/glass.webp"
success_port="$(start_server "$success_site" "ok")"
(
  PUBLISH_ROOT="$success_root"
  DIST_SITE="$success_root/dist-site"
  SITE_ROOT="$success_site"
  SITE_URL="http://127.0.0.1:${success_port}"
  publish_site_main
)
[[ "$(cat "$success_site/keep")" == "keep" ]]
[[ "$(cat "$success_site/index.html")" != "old" ]]
[[ -f "$success_site/.publish-ok" ]]
[[ -f "$success_site/.publish-demos" ]]
grep -Fq '<ol>' "$success_site/index.html"
grep -Fq '<li><a class="card" href="/glass/"><img src="/screenshots/glass.webp" alt="" width="1920" height="1080"><span>/glass/</span></a></li>' "$success_site/index.html"
grep -Fq '<li><a href="/a.b/">/a.b/</a></li>' "$success_site/index.html"
cmp -s "$success_root/screenshots/glass.webp" "$success_site/screenshots/glass.webp"
grep -Fq '/glass/assets/app.js' "$success_site/glass/index.html"
[[ -f "$success_site/a.b/assets/app.js" ]]
no_snapshots "$success_site"
[[ ! -e "$success_site/.publish-incoming" ]]
[[ ! -e "$success_site/.publish-parked" ]]
ok "successful publish keeps the new site tree and drops the previous snapshot"

rm -rf -- "$success_root/examples/a.b"
(
  PUBLISH_ROOT="$success_root"
  DIST_SITE="$success_root/dist-site"
  SITE_ROOT="$success_site"
  SITE_URL="http://127.0.0.1:${success_port}"
  publish_site_main
)
[[ ! -e "$success_site/a.b" ]]
[[ -f "$success_site/glass/index.html" ]]
[[ "$(cat "$success_site/keep")" == "keep" ]]
grep -Fq 'src="/screenshots/glass.webp"' "$success_site/index.html"
grep -Fq '<span>/glass/</span>' "$success_site/index.html"
[[ -f "$success_site/screenshots/glass.webp" ]]
grep -qx 'glass' "$success_site/.publish-demos"
if grep -qx 'a.b' "$success_site/.publish-demos"; then
  fail "removed demo stayed in the manifest"
fi
no_snapshots "$success_site"
ok "republish removes a demo that was listed only in the previous manifest"

rollback_tmp="$(mktemp -d)"
rollback_root="$rollback_tmp/repo"
rollback_site="$rollback_tmp/www/site"
mkdir -p "$rollback_tmp/www"
seed_site "$rollback_site"
prepare_repo "$rollback_root" "glass" "a.b"
rollback_port="$(start_server "$rollback_site" "bad-asset")"
(
  PUBLISH_ROOT="$rollback_root"
  DIST_SITE="$rollback_root/dist-site"
  SITE_ROOT="$rollback_site"
  SITE_URL="http://127.0.0.1:${rollback_port}"
  publish_site_main
) && fail "missing asset should fail smoke"
expect_previous_site "$rollback_site"
ok "failed asset smoke restores the previous site tree"

fallback_tmp="$(mktemp -d)"
fallback_root="$fallback_tmp/repo"
fallback_site="$fallback_tmp/www/site"
mkdir -p "$fallback_tmp/www"
seed_site "$fallback_site"
prepare_repo "$fallback_root" "glass"
fallback_port="$(start_server "$fallback_site" "spa-fallback")"
(
  PUBLISH_ROOT="$fallback_root"
  DIST_SITE="$fallback_root/dist-site"
  SITE_ROOT="$fallback_site"
  SITE_URL="http://127.0.0.1:${fallback_port}"
  publish_site_main
) && fail "HTML asset response should fail smoke"
expect_previous_site "$fallback_site"
ok "SPA HTML served as an asset restores the previous site tree"

missing_root_tmp="$(mktemp -d)"
missing_root_root="$missing_root_tmp/repo"
missing_root_site="$missing_root_tmp/www/site"
mkdir -p "$missing_root_tmp/www"
seed_site "$missing_root_site"
prepare_repo "$missing_root_root" "glass"
missing_root_port="$(start_server "$missing_root_site" "missing-root")"
(
  PUBLISH_ROOT="$missing_root_root"
  DIST_SITE="$missing_root_root/dist-site"
  SITE_ROOT="$missing_root_site"
  SITE_URL="http://127.0.0.1:${missing_root_port}"
  publish_site_main
) && fail "HTTP 404 at / should fail smoke"
expect_previous_site "$missing_root_site"
ok "missing root catalog restores the previous site tree"

echo "publish-site tests passed"
