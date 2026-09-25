#!/usr/bin/env bash
# 把 server/ 打包上传到服务器并切换到新版本。
# 用法：deploy/deploy.sh [SSH 目标，默认 nap]
# 环境变量：NAPTABLE_DOMAIN（默认 naptable.mom0ka27.top）、NAPTABLE_SKIP_TESTS=1 跳过本地测试
set -Eeuo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
target=${1:-nap}
domain=${NAPTABLE_DOMAIN:-naptable.mom0ka27.top}
started_at=$SECONDS

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\n✗ 部署失败：%s\n' "$*" >&2; exit 1; }

if [[ $target == -* || ! $target =~ ^[A-Za-z0-9._@:-]+$ ]]; then
    echo "SSH 目标不合法：$target" >&2
    exit 2
fi
if [[ ! $domain =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "域名不合法：$domain" >&2
    exit 2
fi

revision=$(git -C "$root_dir" rev-parse --short HEAD 2>/dev/null || printf 'workspace')
dirty=false
if ! git -C "$root_dir" diff --quiet --ignore-submodules HEAD 2>/dev/null || \
   [[ -n $(git -C "$root_dir" ls-files --others --exclude-standard 2>/dev/null) ]]; then
    revision="$revision-dirty"
    dirty=true
fi
release_id="$(date -u +%Y%m%dT%H%M%SZ)-$revision-$$"

echo "NapTable 部署"
echo "  服务器：$target"
echo "  域名：  $domain"
echo "  版本：  $release_id"
if [[ $dirty == true ]]; then
    echo "  注意：工作区有未提交的改动，这些改动也会一起部署。" >&2
fi

if [[ ${NAPTABLE_SKIP_TESTS:-0} != 1 ]]; then
    step "[1/5] 运行本地服务端测试"
    (cd "$root_dir" && python3 -m unittest discover -s tests -p 'test_*.py') \
        || fail "本地测试未通过，已中止，服务器没有任何改动。"
else
    step "[1/5] 已跳过本地测试（NAPTABLE_SKIP_TESTS=1）"
fi

staging_dir=$(mktemp -d)
remote_archive="/tmp/naptable-$release_id.tar.gz"
remote_installer="/tmp/naptable-install-$release_id.sh"
cleanup() {
    rm -rf "$staging_dir"
}
trap cleanup EXIT

step "[2/5] 打包发布文件"
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
echo "安装包大小：$(du -h "$staging_dir/release.tar.gz" | cut -f1)"

step "[3/5] 上传到 $target"
# 任何一个文件上传失败，都清掉已经传上去的那个，避免在服务器 /tmp 留下残留。
if ! scp -q "$staging_dir/release.tar.gz" "$target:$remote_archive" || \
   ! scp -q "$root_dir/deploy/remote-install.sh" "$target:$remote_installer"; then
    ssh "$target" "rm -f '$remote_archive' '$remote_installer'" 2>/dev/null || true
    fail "上传失败，请检查 SSH 连接（ssh ${target}）。线上服务没有受影响。"
fi

step "[4/5] 在服务器上安装并切换版本（需要 root 或免密 sudo）"
remote_command="bash '$remote_installer' '$remote_archive' '$release_id' '$domain'"
if ! ssh "$target" "if [ \"\$(id -u)\" -eq 0 ]; then $remote_command; else sudo -n $remote_command; fi"; then
    ssh "$target" "rm -f '$remote_archive' '$remote_installer'" 2>/dev/null || true
    fail "服务器端安装出错，详情看上面的日志（带 [服务器] 前缀）。如果切换版本后才出错，脚本已尝试回滚到上一个版本。"
fi

step "[5/5] 从本机检查公网健康状态"
if curl --connect-timeout 5 --max-time 10 --fail --silent --show-error "https://$domain/health"; then
    printf '\n'
else
    echo "警告：本机访问 https://$domain/health 失败，但服务器上的检查已经通过，可能是本地网络问题。" >&2
fi

printf '\n✓ 部署完成：%s（用时 %d 秒）\n' "$release_id" "$((SECONDS - started_at))"
