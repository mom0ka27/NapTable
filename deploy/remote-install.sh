#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: remote-install.sh ARCHIVE RELEASE_ID DOMAIN" >&2
    exit 2
fi

archive=$1
release_id=$2
domain=$3

if [[ ! $release_id =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "invalid release id: $release_id" >&2
    exit 2
fi
if [[ ! $domain =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "invalid domain: $domain" >&2
    exit 2
fi
if [[ $(id -u) -ne 0 ]]; then
    echo "remote installer must run as root" >&2
    exit 1
fi

exec 9>/run/lock/naptable-deploy.lock
if ! flock -n 9; then
    echo "another NapTable deployment is running" >&2
    exit 1
fi

release_root=/opt/naptable/releases
release_path=$release_root/$release_id
current_link=/opt/naptable/current
cleanup() {
    rm -f "$archive" "$0"
}
trap cleanup EXIT

missing_packages=()
command -v python3.11 >/dev/null || missing_packages+=(python3.11)
command -v nginx >/dev/null || missing_packages+=(nginx)
command -v certbot >/dev/null || missing_packages+=(certbot)
if (( ${#missing_packages[@]} )); then
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
fi
chown root:root /etc/naptable/naptable.env
chmod 0600 /etc/naptable/naptable.env

if [[ -e $release_path ]]; then
    echo "release already exists: $release_path" >&2
    exit 1
fi
install -d -o root -g root -m 0755 "$release_path"
tar -xzf "$archive" -C "$release_path" --no-same-owner

required_files=(
    server/apns.py
    server/live_activity.py
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
        echo "release is missing $relative_path" >&2
        exit 1
    fi
done
if find "$release_path" -type l -print -quit | grep -q .; then
    echo "release archives may not contain symbolic links" >&2
    exit 1
fi
chown -R root:root "$release_path"
find "$release_path" -type d -exec chmod 0755 {} +
find "$release_path" -type f -exec chmod 0644 {} +
chmod 0755 "$release_path/deploy/backup.py" "$release_path/deploy/reload-nginx-after-renewal.sh"
/usr/bin/python3.11 -m py_compile \
    "$release_path/server/apns.py" \
    "$release_path/server/live_activity.py" \
    "$release_path/server/naptable_server.py"

install -o root -g root -m 0644 "$release_path/deploy/naptable.service" /etc/systemd/system/naptable.service
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
    render_nginx "$release_path/deploy/nginx-bootstrap.conf" /etc/nginx/conf.d/naptable.conf
    nginx -t
    systemctl enable --now nginx.service
    certbot certonly --webroot --webroot-path /var/www/letsencrypt \
        --domain "$domain" --non-interactive --agree-tos --register-unsafely-without-email
fi
render_nginx "$release_path/deploy/nginx.conf" /etc/nginx/conf.d/naptable.conf
nginx -t

if [[ -f /var/lib/naptable/naptable.sqlite3 ]]; then
    runuser -u naptable -- /usr/bin/python3.11 "$release_path/deploy/backup.py"
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
rollback_on_error() {
    local status=$?
    trap - ERR
    if [[ $activated == true && -n $previous_release && -d $previous_release ]]; then
        echo "deployment failed; rolling back to $previous_release" >&2
        activate_release "$previous_release"
        systemctl restart naptable.service || true
    fi
    exit "$status"
}
trap rollback_on_error ERR

activate_release "$release_path"
activated=true
systemctl daemon-reload
systemctl enable naptable.service
systemctl enable --now nginx.service naptable-backup.timer certbot-renew.timer
systemctl restart naptable.service
systemctl reload nginx.service

healthy=false
for _ in {1..20}; do
    if curl --fail --silent http://127.0.0.1:8787/health >/dev/null; then
        healthy=true
        break
    fi
    sleep 1
done

if [[ $healthy != true ]]; then
    journalctl -u naptable.service -n 80 --no-pager >&2 || true
    false
fi

public_healthy=false
for _ in {1..10}; do
    if curl --fail --silent "https://$domain/health" >/dev/null; then
        public_healthy=true
        break
    fi
    sleep 2
done
if [[ $public_healthy != true ]]; then
    echo "public health check failed: https://$domain/health" >&2
    false
fi
systemctl start naptable-backup.service

mapfile -t old_releases < <(
    find "$release_root" -mindepth 1 -maxdepth 1 -type d -name '20*' -printf '%f\n' | sort -r | tail -n +6
)
for old_release in "${old_releases[@]}"; do
    old_path=$release_root/$old_release
    if [[ $old_path != "$(readlink -f "$current_link")" && $old_path != "$previous_release" ]]; then
        rm -rf "$old_path"
    fi
done

echo "deployed $release_id"
echo "current release: $(readlink -f "$current_link")"
echo "health: https://$domain/health"
