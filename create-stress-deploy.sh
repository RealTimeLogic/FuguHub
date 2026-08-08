#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
deploy_dir="$root/deploy-stress"
success=false

cleanup() {
   if [ "$success" != true ]; then
      rm -rf -- "$deploy_dir"
   fi
}
trap cleanup EXIT HUP INT TERM

command -v python3 >/dev/null 2>&1 || {
   printf 'ERROR: python3 was not found in PATH.\n' >&2
   exit 1
}

sh "$root/create-core-deploy.sh"

rm -rf -- "$deploy_dir"
mkdir -p -- "$deploy_dir/themes"
cp -- "$root/deploy-core/cms.zip" "$deploy_dir/cms.zip"
cp -- "$root/deploy-core/themes/default.zip" "$deploy_dir/themes/default.zip"
cp -- "$root/deploy-core/themes/embedded-dashboard.zip" \
   "$deploy_dir/themes/embedded-dashboard.zip"

python3 "$root/stress/build_seed.py" \
   --runtime "$deploy_dir" \
   --manifest "$root/stress/urls.txt"

success=true
trap - EXIT HUP INT TERM

printf '\nStress deployment created:\n'
printf '  deploy-stress/cms.zip\n'
printf '  deploy-stress/themes/default.zip\n'
printf '  deploy-stress/themes/embedded-dashboard.zip\n'
printf '  deploy-stress/data/cms.sqlite.db\n'
printf '  deploy-stress/stress-urls.txt\n\n'
printf 'Start from deploy-stress with:\n'
printf '  mako -l::cms.zip\n'

