#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mode=${1:-full}

case "$mode" in
   full)
      deploy_name=deploy
      include_plugins=true
      ;;
   core)
      deploy_name=deploy-core
      include_plugins=false
      ;;
   *)
      printf 'ERROR: Unsupported deployment mode: %s\n' "$mode" >&2
      exit 1
      ;;
esac

command -v zip >/dev/null 2>&1 || {
   printf 'ERROR: zip was not found in PATH.\n' >&2
   exit 1
}
command -v unzip >/dev/null 2>&1 || {
   printf 'ERROR: unzip was not found in PATH.\n' >&2
   exit 1
}

deploy_dir="$root/$deploy_name"
success=false
cleanup() {
   if [ "$success" != true ]; then
      rm -rf -- "$deploy_dir"
   fi
}
trap cleanup EXIT HUP INT TERM

rm -rf -- "$deploy_dir"
mkdir -p -- "$deploy_dir/themes"

cms_zip="$deploy_dir/cms.zip"
domains_zip="$deploy_dir/CmsDomains.zip"
default_zip="$deploy_dir/themes/default.zip"
dashboard_zip="$deploy_dir/themes/embedded-dashboard.zip"

(
   cd -- "$root/cms"
   zip -q -r "$cms_zip" .
)

if [ "$include_plugins" = true ]; then
   (
      cd -- "$root"
      zip -q -r "$cms_zip" plugins
   )
   (
      cd -- "$root/CmsDomains"
      zip -q -r "$domains_zip" .
   )
fi

fallback_stage="$deploy_dir/.fallback-stage"
mkdir -p -- "$fallback_stage/fallback-theme"
cp -R -- "$root/themes/default/." "$fallback_stage/fallback-theme/"
(
   cd -- "$fallback_stage"
   zip -q -r "$cms_zip" fallback-theme
)
rm -rf -- "$fallback_stage"

(
   cd -- "$root/themes/default"
   zip -q -r "$default_zip" .
)
(
   cd -- "$root/themes/embedded-dashboard"
   zip -q -r "$dashboard_zip" .
)

has_entry() {
   unzip -Z1 "$1" | grep -Fqx "$2"
}

has_entry "$cms_zip" .preload || {
   printf 'ERROR: cms.zip is missing .preload.\n' >&2
   exit 1
}
has_entry "$cms_zip" .appinfo || {
   printf 'ERROR: cms.zip is missing .appinfo.\n' >&2
   exit 1
}
has_entry "$cms_zip" .lua/admin.lua || {
   printf 'ERROR: cms.zip is missing .lua/admin.lua.\n' >&2
   exit 1
}
has_entry "$cms_zip" lib/.lua/fastmcp/engine.lua || {
   printf 'ERROR: cms.zip is missing FastMCP.\n' >&2
   exit 1
}
has_entry "$cms_zip" fallback-theme/theme.json || {
   printf 'ERROR: cms.zip is missing the built-in fallback theme metadata.\n' >&2
   exit 1
}
has_entry "$cms_zip" fallback-theme/templates/layout.lsp || {
   printf 'ERROR: cms.zip is missing the built-in fallback theme templates.\n' >&2
   exit 1
}

if [ "$include_plugins" = true ]; then
   for entry in \
      plugins/identity-access/.preload \
      plugins/file-services/.preload \
      plugins/large-file-mailer/.preload
   do
      has_entry "$cms_zip" "$entry" || {
         printf 'ERROR: cms.zip is missing %s.\n' "$entry" >&2
         exit 1
      }
   done
   has_entry "$domains_zip" .preload || {
      printf 'ERROR: CmsDomains.zip is missing .preload.\n' >&2
      exit 1
   }
elif unzip -Z1 "$cms_zip" | grep -q '^plugins/'; then
   printf 'ERROR: core cms.zip unexpectedly contains plugins.\n' >&2
   exit 1
fi

for archive in "$default_zip" "$dashboard_zip"
do
   has_entry "$archive" theme.json || {
      printf 'ERROR: %s is missing theme.json.\n' "$(basename "$archive")" >&2
      exit 1
   }
   has_entry "$archive" templates/layout.lsp || {
      printf 'ERROR: %s is missing templates/layout.lsp.\n' "$(basename "$archive")" >&2
      exit 1
   }
done

success=true
trap - EXIT HUP INT TERM

printf 'Deployment created:\n'
printf '  %s/cms.zip\n' "$deploy_name"
if [ "$include_plugins" = true ]; then
   printf '  %s/CmsDomains.zip\n' "$deploy_name"
fi
printf '  %s/themes/default.zip\n' "$deploy_name"
printf '  %s/themes/embedded-dashboard.zip\n' "$deploy_name"
