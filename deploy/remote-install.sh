#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 3 ]]; then
    echo "用法：remote-install.sh ARCHIVE RELEASE_ID DOMAIN" >&2
    exit 2
fi

archive=$1
release_id=$2
domain=$3

if [[ ! $release_id =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "发布 ID 不合法：$release_id" >&2
    exit 2
fi
if [[ ! $domain =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "域名不合法：$domain" >&2
    exit 2
fi
if [[ $(id -u) -ne 0 ]]; then
    echo "服务器端安装脚本必须以 root 运行（请给部署账号配置免密 sudo）" >&2
    exit 1
fi

step() { printf '==> [服务器] %s\n' "$*"; }

exec 9>/run/lock/naptable-deploy.lock
if ! flock -n 9; then
    echo "另一个 NapTable 部署正在进行，请等它结束后再试" >&2
    exit 1
fi

release_root=/opt/naptable/releases
release_path=$release_root/$release_id
current_link=/opt/naptable/current
cleanup() {
    rm -f "$archive" "$0"
}
trap cleanup EXIT

step "检查运行环境"
missing_packages=()
# Managed CPython includes a modern SQLite without replacing OS libraries.
python_runtime=/opt/naptable/python/bin/python3.14
if [[ ! -x $python_runtime ]]; then
    echo "找不到 ${python_runtime}，请先按 server/README.md 安装 Python 3.14 再部署" >&2
    exit 1
fi
"$python_runtime" - <<'PYTHON'
import sqlite3, sys
assert sys.version_info[:2] == (3, 14), sys.version
assert sqlite3.sqlite_version_info >= (3, 35, 0), sqlite3.sqlite_version
print(f'Runtime: Python {sys.version.split()[0]}, SQLite {sqlite3.sqlite_version}')
PYTHON
command -v nginx >/dev/null || missing_packages+=(nginx)
command -v certbot >/dev/null || missing_packages+=(certbot)
if (( ${#missing_packages[@]} )); then
    step "安装缺少的系统软件包：${missing_packages[*]}"
    dnf install -y "${missing_packages[@]}"
fi

if ! getent passwd naptable >/dev/null; then
    useradd --system --home-dir /var/lib/naptable --shell /sbin/nologin naptable
fi

install -d -o root -g root -m 0755 "$release_root"
install -d -o naptable -g naptable -m 0700 /var/lib/naptable /var/backups/naptable
install -d -o root -g root -m 0755 /etc/naptable
install -d -o root -g naptable -m 0750 /etc/naptable/keys
install -d -o nginx -g nginx -m 0755 /var/www/letsencrypt
install -d -o root -g root -m 0755 /etc/letsencrypt/renewal-hooks/deploy

if [[ ! -f /etc/naptable/naptable.env ]]; then
    umask 077
    printf 'NAPTABLE_ADMIN_TOKEN=%s\n' "$(openssl rand -hex 32)" > /etc/naptable/naptable.env
    echo "首次部署：已生成管理员令牌，保存在 /etc/naptable/naptable.env"
fi
chown root:root /etc/naptable/naptable.env
chmod 0600 /etc/naptable/naptable.env

if [[ -e $release_path ]]; then
    echo "该版本目录已存在：$release_path" >&2
    exit 1
fi
step "解压并校验发布文件"
install -d -o root -g root -m 0755 "$release_path"
tar -xzf "$archive" -C "$release_path" --no-same-owner

required_files=(
    server/apns.py
    server/holidays.py
    server/live_activity.py
    server/live_activity_v2.py
    server/live_activity_schedule.py
    server/live_activity_timeline.py
    server/requirements.txt
    server/naptable_server.py
    server/static/admin.html
    server/static/admin.css
    server/static/admin.js
    deploy/backup.py
    deploy/naptable.service
    deploy/naptable-backup.service
    deploy/naptable-backup.timer
    deploy/nginx.conf
    deploy/nginx-bootstrap.conf
    deploy/reload-nginx-after-renewal.sh
)
for relative_path in "${required_files[@]}"; do
    if [[ ! -f $release_path/$relative_path ]]; then
        echo "发布包缺少文件：$relative_path" >&2
        exit 1
    fi
done
if find "$release_path" -type l -print -quit | grep -q .; then
    echo "发布包里不允许有符号链接" >&2
    exit 1
fi
chown -R root:root "$release_path"
find "$release_path" -type d -exec chmod 0755 {} +
find "$release_path" -type f -exec chmod 0644 {} +
chmod 0755 "$release_path/deploy/backup.py" "$release_path/deploy/reload-nginx-after-renewal.sh"
"$python_runtime" -m py_compile "$release_path"/server/*.py

# Keep dependencies tied to the release, while credentials survive releases.
umask 022
step "创建虚拟环境并安装 Python 依赖"
"$python_runtime" -m venv "$release_path/.venv"
"$release_path/.venv/bin/python" -m pip install --quiet --disable-pip-version-check -r "$release_path/server/requirements.txt"
step "校验并备份实时活动令牌加密密钥"
"$release_path/.venv/bin/python" - "$release_path" <<'PYTHON'
from pathlib import Path
import grp, os, sys, subprocess
from cryptography.fernet import Fernet
config = Path('/etc/naptable/naptable.env')
entries = config.read_text().splitlines()
setting = 'NAPTABLE_LA_TOKEN_KEY_PATH='
existing = next((line[len(setting):].strip().strip('"').strip("'") for line in entries if line.startswith(setting)), None)
key = Path(existing or '/etc/naptable/keys/live-activity-token.key')
if existing:
    # Never silently replace a configured key: existing tokens depend on it.
    Fernet(key.read_bytes().strip())
else:
    if not key.exists():
        fd = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o640)
        with os.fdopen(fd, 'wb') as target:
            target.write(Fernet.generate_key())
    Fernet(key.read_bytes().strip())
    os.chown(key, 0, grp.getgrnam('naptable').gr_gid)
    os.chmod(key, 0o640)
    with config.open('a') as target:
        target.write('\n' + setting + str(key) + '\n')
# Separate root-only key backup, outside DB backup retention and release cleanup.
backup = Path('/etc/naptable/key-backups')
backup.mkdir(mode=0o700, exist_ok=True)
destination = backup / (Path(sys.argv[1]).name + '.fernet')
fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'wb') as target:
    target.write(key.read_bytes())
subprocess.run(['runuser', '-u', 'naptable', '--', str(Path(sys.argv[1]) / '.venv/bin/python'),
    '-c', 'from cryptography.fernet import Fernet; import pathlib,sys; Fernet(pathlib.Path(sys.argv[1]).read_bytes().strip())',
    str(key)], check=True)
print('Token encryption key validated and backed up (value not logged)')
PYTHON

step "在数据库副本上预演迁移"
# Exercise migrations on a DB copy without starting workers or contacting APNs.
"$release_path/.venv/bin/python" - "$release_path" <<'PYTHON'
import pathlib, sqlite3, sys, tempfile
sys.path.insert(0, sys.argv[1])
from server.naptable_server import Store
from server.live_activity import build_service
with tempfile.TemporaryDirectory(prefix='naptable-preflight-') as folder:
    destination = pathlib.Path(folder) / 'preflight.sqlite3'
    source = pathlib.Path('/var/lib/naptable/naptable.sqlite3')
    if source.exists():
        with sqlite3.connect(f'file:{source}?mode=ro', uri=True) as live:
            with sqlite3.connect(destination) as clone:
                live.backup(clone)
    store = Store(str(destination))
    service = build_service(store.db, store.lock, config={})
    assert store.db.execute('PRAGMA quick_check').fetchone()[0] == 'ok'
    service.stop()
    store.db.close()
print('Database migration preflight passed; no APNs requests sent')
PYTHON

step "安装备份定时任务和 nginx 配置"
install -o root -g root -m 0644 "$release_path/deploy/naptable-backup.service" /etc/systemd/system/naptable-backup.service
install -o root -g root -m 0644 "$release_path/deploy/naptable-backup.timer" /etc/systemd/system/naptable-backup.timer
install -o root -g root -m 0755 "$release_path/deploy/reload-nginx-after-renewal.sh" \
    /etc/letsencrypt/renewal-hooks/deploy/reload-nginx-after-renewal.sh

render_nginx() {
    sed "s/__NAPTABLE_DOMAIN__/$domain/g" "$1" > "$2"
    chown root:root "$2"
    chmod 0644 "$2"
}

if [[ ! -f /etc/letsencrypt/live/$domain/fullchain.pem ]]; then
    step "还没有 $domain 的证书，申请 Let's Encrypt 证书"
    render_nginx "$release_path/deploy/nginx-bootstrap.conf" /etc/nginx/conf.d/naptable.conf
    nginx -t
    systemctl enable --now nginx.service
    certbot certonly --webroot --webroot-path /var/www/letsencrypt \
        --domain "$domain" --non-interactive --agree-tos --register-unsafely-without-email
fi
render_nginx "$release_path/deploy/nginx.conf" /etc/nginx/conf.d/naptable.conf
nginx -t

if [[ -f /var/lib/naptable/naptable.sqlite3 ]]; then
    step "备份数据库（服务仍在运行）"
    runuser -u naptable -- "$release_path/.venv/bin/python" "$release_path/deploy/backup.py"
fi

previous_release=
if [[ -L $current_link ]]; then
    previous_release=$(readlink -f "$current_link")
elif [[ -d $current_link ]]; then
    legacy_release=$release_root/legacy-$(date -u +%Y%m%dT%H%M%SZ)
    install -d -o root -g root -m 0755 "$legacy_release"
    mv "$current_link" "$legacy_release/server"
    cp -R "$release_path/deploy" "$legacy_release/deploy"
    previous_release=$legacy_release
fi

activate_release() {
    local target=$1
    local next_link="$current_link.next.$release_id"
    ln -s "$target" "$next_link"
    mv -Tf "$next_link" "$current_link"
}

activated=false
stopped=false
rollback_on_error() {
    local status=$?
    trap - ERR
    if [[ $stopped == true && $activated != true ]]; then
        # 已停服务但还没切换版本：旧版本原样拉起即可，否则线上会一直停着。
        echo "部署失败，尚未切换版本，正在重新启动原来的服务" >&2
        systemctl start naptable.service || echo "原服务启动失败，请手动检查：journalctl -u naptable.service" >&2
        exit "$status"
    fi
    if [[ $activated == true && -n $previous_release && ! -f $previous_release/server/live_activity_v2.py ]]; then
        echo "v2 迁移失败，服务已停止。自动回滚到 v1 可能会重复发送启动推送，请手动处理。" >&2
        systemctl stop naptable.service || true
        exit "$status"
    fi
    if [[ $activated == true && -n $previous_release && -d $previous_release ]]; then
        echo "部署失败，正在回滚到 $previous_release" >&2
        activate_release "$previous_release"
        systemctl restart naptable.service || true
    fi
    exit "$status"
}
trap rollback_on_error ERR

# Quiesce old scheduling before taking the final pre-migration backup.
step "停止服务并做迁移前的最终备份"
systemctl stop naptable.service
stopped=true
if [[ -f /var/lib/naptable/naptable.sqlite3 ]]; then
    runuser -u naptable -- "$release_path/.venv/bin/python" "$release_path/deploy/backup.py"
fi
step "切换到新版本并重启服务"
activate_release "$release_path"
activated=true
install -o root -g root -m 0644 "$release_path/deploy/naptable.service" /etc/systemd/system/naptable.service
systemctl daemon-reload
systemctl enable naptable.service
systemctl enable --now nginx.service naptable-backup.timer certbot-renew.timer
systemctl restart naptable.service
systemctl reload nginx.service

step "等待本机健康检查通过（最多 20 秒）"
healthy=false
for _ in {1..20}; do
    if curl --fail --silent http://127.0.0.1:8787/health >/dev/null; then
        healthy=true
        break
    fi
    sleep 1
done

if [[ $healthy != true ]]; then
    echo "服务 20 秒内没有通过健康检查，最近的日志如下：" >&2
    journalctl -u naptable.service -n 80 --no-pager >&2 || true
    false
fi

step "检查公网健康状态"
public_healthy=false
for _ in {1..10}; do
    if curl --fail --silent "https://$domain/health" >/dev/null; then
        public_healthy=true
        break
    fi
    sleep 2
done
if [[ $public_healthy != true ]]; then
    echo "公网健康检查失败：https://$domain/health（检查 nginx 和证书）" >&2
    false
fi
systemctl start naptable-backup.service

step "清理旧版本（保留最近 5 个）"
mapfile -t old_releases < <(
    find "$release_root" -mindepth 1 -maxdepth 1 -type d -name '20*' -printf '%f\n' | sort -r | tail -n +6
)
for old_release in "${old_releases[@]}"; do
    old_path=$release_root/$old_release
    if [[ $old_path != "$(readlink -f "$current_link")" && $old_path != "$previous_release" ]]; then
        rm -rf "$old_path"
    fi
done

echo "已部署：$release_id"
echo "当前版本目录：$(readlink -f "$current_link")"
echo "健康检查：https://$domain/health"
