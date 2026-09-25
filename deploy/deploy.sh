#!/usr/bin/env bash
set -Eeuo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
target=${1:-nap}
domain=${NAPTABLE_DOMAIN:-naptable.mom0ka27.top}

if [[ $target == -* || ! $target =~ ^[A-Za-z0-9._@:-]+$ ]]; then
    echo "invalid SSH target: $target" >&2
    exit 2
fi
if [[ ! $domain =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "invalid domain: $domain" >&2
    exit 2
fi

if [[ ${NAPTABLE_SKIP_TESTS:-0} != 1 ]]; then
    echo "==> running server tests"
    (cd "$root_dir" && python3 -m unittest discover -s tests -p 'test_*.py')
fi

revision=$(git -C "$root_dir" rev-parse --short HEAD 2>/dev/null || printf 'workspace')
if ! git -C "$root_dir" diff --quiet --ignore-submodules HEAD 2>/dev/null || \
   [[ -n $(git -C "$root_dir" ls-files --others --exclude-standard 2>/dev/null) ]]; then
    revision="$revision-dirty"
fi
release_id="$(date -u +%Y%m%dT%H%M%SZ)-$revision-$$"
staging_dir=$(mktemp -d)
remote_archive="/tmp/naptable-$release_id.tar.gz"
remote_installer="/tmp/naptable-install-$release_id.sh"
cleanup() {
    rm -rf "$staging_dir"
}
trap cleanup EXIT

mkdir -p "$staging_dir/bundle/server" "$staging_dir/bundle/deploy"
cp "$root_dir"/server/*.py \
   "$root_dir/server/requirements.txt" \
   "$staging_dir/bundle/server/"
cp -R "$root_dir/server/static" "$staging_dir/bundle/server/static"
cp "$root_dir/deploy/backup.py" \
   "$root_dir/deploy/naptable.service" \
   "$root_dir/deploy/naptable-backup.service" \
   "$root_dir/deploy/naptable-backup.timer" \
   "$root_dir/deploy/nginx.conf" \
   "$root_dir/deploy/nginx-bootstrap.conf" \
   "$root_dir/deploy/reload-nginx-after-renewal.sh" \
   "$staging_dir/bundle/deploy/"
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$staging_dir/release.tar.gz" -C "$staging_dir/bundle" .

echo "==> uploading $release_id to $target"
scp -q "$staging_dir/release.tar.gz" "$target:$remote_archive"
scp -q "$root_dir/deploy/remote-install.sh" "$target:$remote_installer"

echo "==> activating $release_id"
remote_command="bash '$remote_installer' '$remote_archive' '$release_id' '$domain'"
ssh "$target" "if [ \"\$(id -u)\" -eq 0 ]; then $remote_command; else sudo -n $remote_command; fi"

echo "==> verifying public endpoint"
if curl --connect-timeout 5 --max-time 10 --fail --silent --show-error "https://$domain/health"; then
    printf '\n'
else
    echo "warning: local public health check failed; remote checks succeeded" >&2
fi
