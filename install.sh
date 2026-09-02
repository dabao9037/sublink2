#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="SubLink2"
APP_SLUG="sublink2"
SERVICE_NAME="sublink2.service"
SERVICE_USER="sublink2"
INSTALL_ROOT="${SUBLINK2_INSTALL_ROOT:-/opt/sublink2}"
RELEASES_DIR="$INSTALL_ROOT/releases"
CURRENT_LINK="$INSTALL_ROOT/current"
DATA_DIR="${SUBLINK2_DATA_DIR:-/var/lib/sublink2}"
CONFIG_DIR="${SUBLINK2_CONFIG_DIR:-/etc/sublink2}"
CONFIG_FILE="$CONFIG_DIR/config.env"
UNIT_FILE="${SUBLINK2_UNIT_FILE:-/etc/systemd/system/sublink2.service}"
COMMAND_PATH="${SUBLINK2_COMMAND_PATH:-/usr/local/bin/sub}"
REPO_SLUG="dabao9037/sublink2"
REPO_URL="${SUBLINK2_REPO_URL:-https://github.com/${REPO_SLUG}.git}"
TARBALL_URL="${SUBLINK2_TARBALL_URL:-https://github.com/${REPO_SLUG}/archive/refs/heads/main.tar.gz}"
DEFAULT_PORT="${SUBLINK2_DEFAULT_PORT:-8096}"
DEFAULT_HOST="${SUBLINK2_DEFAULT_HOST:-127.0.0.1}"
WHEEL_CACHE="${SUBLINK2_WHEEL_CACHE:-/var/cache/sublink2/wheels}"
ACTION="${1:-menu}"
ARG2="${2:-}"
ARG3="${3:-}"

C_RESET='\033[0m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RED='\033[31m'; C_CYAN='\033[36m'; C_BOLD='\033[1m'
info(){ echo -e "${C_CYAN}[信息]${C_RESET} $*"; }
success(){ echo -e "${C_GREEN}[成功]${C_RESET} $*"; }
warn(){ echo -e "${C_YELLOW}[提示]${C_RESET} $*"; }
die(){ echo -e "${C_RED}[错误]${C_RESET} $*" >&2; exit 1; }
command_exists(){ command -v "$1" >/dev/null 2>&1; }
require_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || die "请使用 root 用户运行：sudo sub ${ACTION}"; }
random_string(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-18}" || true; }
fernet_key(){ python3 - <<'PY'
import base64, os
print(base64.urlsafe_b64encode(os.urandom(32)).decode())
PY
}

validate_port(){
  [[ "${1:-}" =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535)) || die "端口必须为 1-65535。"
}
port_in_use(){
  local port="$1"
  command_exists ss || return 1
  ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
}
find_free_port(){
  local port="$DEFAULT_PORT"
  validate_port "$port"
  while port_in_use "$port"; do
    port=$((port + 1))
    [ "$port" -le 65535 ] || die "没有找到空闲端口。"
  done
  printf '%s' "$port"
}

install_packages(){
  command_exists apt-get || die "目前仅支持使用 apt 的 Ubuntu / Debian。"
  local packages=(ca-certificates curl git openssl python3 python3-pip python3-venv)
  info "检查原生运行依赖……"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
}

check_python(){
  python3 - <<'PY' || die "需要 Python 3.9-3.13。"
import sys
if not ((3, 9) <= sys.version_info[:2] < (3, 14)):
    raise SystemExit(f"unsupported Python: {sys.version.split()[0]}")
print(f"Python {sys.version.split()[0]}")
PY
  python3 -m venv --help >/dev/null 2>&1 || die "python3-venv 不可用。"
}

ensure_service_user(){
  if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin --user-group "$SERVICE_USER"
  fi
  install -d -o root -g root -m 0755 "$INSTALL_ROOT" "$RELEASES_DIR"
  install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$DATA_DIR"
  install -d -o root -g "$SERVICE_USER" -m 0750 "$CONFIG_DIR"
  install -d -o root -g root -m 0755 "$(dirname "$WHEEL_CACHE")" "$WHEEL_CACHE"
}

load_config(){
  [ -f "$CONFIG_FILE" ] || die "尚未安装 $APP_NAME，请先运行：sub install"
  SUBLINK_HOST="${SUBLINK_HOST-$DEFAULT_HOST}"
  SUBLINK_PORT="${SUBLINK_PORT-$DEFAULT_PORT}"
  ADMIN_USER="${ADMIN_USER-}"
  ADMIN_PASSWORD="${ADMIN_PASSWORD-}"
  APP_SECRET="${APP_SECRET-}"
  PUBLIC_BASE_URL="${PUBLIC_BASE_URL-}"
  DOMAIN="${DOMAIN-}"
  DOMAIN_HTTPS="${DOMAIN_HTTPS-0}"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  : "${SUBLINK_HOST:=$DEFAULT_HOST}" "${PUBLIC_BASE_URL:=}" "${DOMAIN:=}" "${DOMAIN_HTTPS:=0}"
}

write_config(){
  local target="${1:-$CONFIG_FILE}"
  umask 077
  cat >"$target" <<EOF
SUBLINK_HOST=${SUBLINK_HOST}
SUBLINK_PORT=${SUBLINK_PORT}
ADMIN_USER=${ADMIN_USER}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
APP_SECRET=${APP_SECRET}
PUBLIC_BASE_URL=${PUBLIC_BASE_URL:-}
DOMAIN=${DOMAIN:-}
DOMAIN_HTTPS=${DOMAIN_HTTPS:-0}
DB_PATH=${DATA_DIR}/subscriptions.db
EOF
  chown root:"$SERVICE_USER" "$target" 2>/dev/null || true
  chmod 0640 "$target"
}

write_systemd_unit(){
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=SubLink2 native subscription service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${CURRENT_LINK}
EnvironmentFile=${CONFIG_FILE}
ExecStart=${CURRENT_LINK}/venv/bin/uvicorn app.main:app --host \${SUBLINK_HOST} --port \${SUBLINK_PORT} --proxy-headers --forwarded-allow-ips=127.0.0.1
Restart=on-failure
RestartSec=3
TimeoutStartSec=45
TimeoutStopSec=20
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${DATA_DIR}
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$UNIT_FILE"
}

systemd_enable_active(){
  local service="$1" label="${2:-$1}"
  command_exists systemctl || die "缺少 systemctl，无法管理 ${label}。"
  systemctl enable --now "$service" >/dev/null || die "${label} 启动或开机自启失败。"
  systemctl is-enabled --quiet "$service" || die "${label} 未启用开机自启。"
  systemctl is-active --quiet "$service" || die "${label} 当前未运行。"
}

health_check(){
  local host="${SUBLINK_HOST:-$DEFAULT_HOST}" port="${SUBLINK_PORT:-$DEFAULT_PORT}" i
  [ "$host" = "0.0.0.0" ] && host="127.0.0.1"
  [ "$host" = "::" ] && host="::1"
  for i in {1..30}; do
    curl -fsS --connect-timeout 2 --max-time 4 "http://${host}:${port}/healthz" 2>/dev/null | grep -q '"status":"ok"' && return 0
    sleep 1
  done
  return 1
}

fetch_source(){
  local destination="$1" source_dir="${SUBLINK2_SOURCE_DIR:-}"
  mkdir -p "$destination"
  if [ -n "$source_dir" ]; then
    [ -f "$source_dir/requirements.txt" ] && [ -d "$source_dir/app" ] || die "SUBLINK2_SOURCE_DIR 不是有效源码目录。"
    cp -a "$source_dir/." "$destination/"
  else
    info "从 ${REPO_SLUG} main 下载最新源码……"
    curl -fL --retry 3 --connect-timeout 10 "$TARBALL_URL" | tar -xz --strip-components=1 -C "$destination"
  fi
  [ -f "$destination/install.sh" ] || die "源码缺少 install.sh。"
  [ -f "$destination/requirements.txt" ] || die "源码缺少 requirements.txt。"
  [ -f "$destination/app/main.py" ] || die "源码缺少 app/main.py。"
  rm -rf "$destination/.git" "$destination/.github" "$destination/tests" "$destination/.pytest_cache" "$destination/.venv" 2>/dev/null || true
}

build_release(){
  local release_dir="$1" smoke_db
  python3 -m venv "$release_dir/venv"
  "$release_dir/venv/bin/python" -m pip install --disable-pip-version-check --upgrade 'pip==25.2' 'setuptools==80.9.0' 'wheel==0.45.1'
  info "下载并缓存固定版本 Python wheels……"
  "$release_dir/venv/bin/pip" download --disable-pip-version-check --dest "$WHEEL_CACHE" -r "$release_dir/requirements.txt"
  "$release_dir/venv/bin/pip" install --disable-pip-version-check --no-index --find-links "$WHEEL_CACHE" -r "$release_dir/requirements.txt"
  smoke_db="$(mktemp)"
  (
    cd "$release_dir"
    APP_SECRET="$(fernet_key)" ADMIN_USER="buildcheck" ADMIN_PASSWORD="$(random_string 20)" DB_PATH="$smoke_db" \
      "$release_dir/venv/bin/python" -c 'from app.main import init_db; init_db(); print("native import ok")' \
      </dev/null
  )
  rm -f "$smoke_db"
  find "$release_dir" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
  chown -R root:root "$release_dir"
  chmod -R o-w "$release_dir"
}

install_command(){
  local source="$1"
  install -o root -g root -m 0755 "$source/install.sh" "$COMMAND_PATH"
}

atomic_activate(){
  local release_dir="$1" old_target="" next_link="${CURRENT_LINK}.next"
  [ ! -L "$CURRENT_LINK" ] || old_target="$(readlink -f "$CURRENT_LINK")"
  ln -sfn "$release_dir" "$next_link"
  mv -Tf "$next_link" "$CURRENT_LINK"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null
  if systemctl restart "$SERVICE_NAME" && health_check; then
    return 0
  fi
  warn "新版本启动失败，正在恢复上一版本。"
  journalctl -u "$SERVICE_NAME" --no-pager -n 80 2>/dev/null || true
  if [ -n "$old_target" ] && [ -d "$old_target" ]; then
    ln -sfn "$old_target" "$next_link"
    mv -Tf "$next_link" "$CURRENT_LINK"
    systemctl restart "$SERVICE_NAME" || true
    health_check || warn "上一版本恢复后健康检查仍未通过，请立即查看：sub logs"
  else
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$CURRENT_LINK"
  fi
  return 1
}

prune_releases(){
  local keep_current
  keep_current="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
  mapfile -t old_releases < <(find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | awk 'NR>3 {$1=""; sub(/^ /,""); print}')
  local release
  for release in "${old_releases[@]:-}"; do
    [ -n "$release" ] && [ "$release" != "$keep_current" ] && rm -rf "$release"
  done
}

listener_summary(){ ss -H -ltnp "sport = :$1" 2>/dev/null || true; }
port_is_listening(){ listener_summary "$1" | grep -q .; }
port_owned_only_by(){
  local port="$1" pattern="$2" listeners
  listeners="$(listener_summary "$port")"
  [ -n "$listeners" ] || return 1
  grep -Eq "$pattern" <<<"$listeners" && ! grep -Eqv "$pattern" <<<"$listeners"
}
require_active_listener(){
  local service="$1" label="$2"
  systemctl is-active --quiet "$service" || die "检测到 ${label} 占用 Web 端口，但 ${service} 不是活动的 systemd 服务；为避免抢占端口，已停止操作。"
}

public_ipv4(){
  local ip
  ip="$(curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '%s' "$ip"
}
dns_preflight(){
  local domain="$1" public addresses
  public="$(public_ipv4)"
  addresses="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  [ -n "$public" ] || die "无法确定本机公网 IPv4，请稍后重试。"
  [ -n "$addresses" ] || die "域名尚无可用 IPv4 解析。"
  grep -Fxq "$public" <<<"$addresses" || {
    warn "域名解析：$(tr '\n' ' ' <<<"$addresses")"
    warn "本机公网 IPv4：$public"
    die "域名未直连本机。首次签发证书请关闭 Cloudflare 代理（灰云），证书成功后可再开启。"
  }
}

caddy_config_file(){
  if [ -f /etc/caddy/Caddyfile ] && grep -Eq '^[[:space:]]*import[[:space:]]+conf\.d/\*' /etc/caddy/Caddyfile; then
    install -d -m 0755 /etc/caddy/conf.d
    printf '%s' /etc/caddy/conf.d/sublink2.caddy
  else
    printf '%s' /etc/caddy/Caddyfile
  fi
}
caddy_apply(){
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
  if caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile; then return 0; fi
  warn "Caddy 管理接口不可用，改用 systemd 重启加载配置。"
  systemctl restart caddy && systemctl is-active --quiet caddy
}
write_caddy_proxy(){
  local domain="$1" https="$2" config temporary begin='# BEGIN SUBLINK2 MANAGED' end='# END SUBLINK2 MANAGED'
  config="$(caddy_config_file)"
  require_active_listener caddy.service Caddy
  systemd_enable_active caddy.service Caddy
  temporary="$(mktemp)"
  if [ -f "$config" ]; then
    awk -v begin="$begin" -v end="$end" '$0==begin{skip=1;next} $0==end{skip=0;next} !skip{print}' "$config" >"$temporary"
  fi
  if [ "$https" = "1" ]; then
    cat >>"$temporary" <<EOF

$begin
${domain} {
    encode zstd gzip
    reverse_proxy 127.0.0.1:${SUBLINK_PORT}
}
$end
EOF
  else
    cat >>"$temporary" <<EOF

$begin
http://${domain} {
    encode zstd gzip
    reverse_proxy 127.0.0.1:${SUBLINK_PORT}
}
$end
EOF
  fi
  install -m 0644 "$temporary" "$config"
  rm -f "$temporary"
  caddy_apply || die "Caddy 配置加载失败。"
}

ensure_certbot_plugin(){
  local server="$1"
  apt-get update -y
  if [ "$server" = apache ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-apache
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx nginx
  fi
}
write_apache_proxy(){
  local domain="$1" https="$2"
  require_active_listener apache2.service Apache
  systemd_enable_active apache2.service Apache
  ensure_certbot_plugin apache
  a2enmod proxy proxy_http headers ssl rewrite >/dev/null
  cat >/etc/apache2/sites-available/sublink2.conf <<EOF
<VirtualHost *:80>
    ServerName ${domain}
    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:${SUBLINK_PORT}/
    ProxyPassReverse / http://127.0.0.1:${SUBLINK_PORT}/
    RequestHeader set X-Forwarded-Proto "http"
    ErrorLog \${APACHE_LOG_DIR}/sublink2-error.log
    CustomLog \${APACHE_LOG_DIR}/sublink2-access.log combined
</VirtualHost>
EOF
  a2ensite sublink2.conf >/dev/null
  apache2ctl configtest
  systemctl reload apache2
  if [ "$https" = "1" ]; then
    certbot --apache -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email --redirect
  fi
  systemd_enable_active apache2.service Apache
}
write_nginx_proxy(){
  local domain="$1" https="$2"
  ensure_certbot_plugin nginx
  if port_is_listening 80; then require_active_listener nginx.service Nginx; fi
  install -d -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled
  cat >/etc/nginx/sites-available/sublink2.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    client_max_body_size 300k;
    location / {
        proxy_pass http://127.0.0.1:${SUBLINK_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  ln -sfn /etc/nginx/sites-available/sublink2.conf /etc/nginx/sites-enabled/sublink2.conf
  nginx -t
  systemd_enable_active nginx.service Nginx
  systemctl reload nginx
  if [ "$https" = "1" ]; then
    certbot --nginx -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email --redirect
  fi
  systemd_enable_active nginx.service Nginx
}

managed_proxy_kind(){
  if { [ -f /etc/caddy/Caddyfile ] && grep -Fq '# BEGIN SUBLINK2 MANAGED' /etc/caddy/Caddyfile; } || [ -f /etc/caddy/conf.d/sublink2.caddy ]; then
    printf caddy; return
  fi
  if compgen -G '/etc/apache2/sites-available/sublink2*.conf' >/dev/null; then printf apache; return; fi
  if [ -f /etc/nginx/sites-available/sublink2.conf ]; then printf nginx; return; fi
}

refresh_proxy_port(){
  local old_port="$1" new_port="$2" kind file
  kind="$(managed_proxy_kind)"
  [ -n "$kind" ] || return 0
  case "$kind" in
    caddy)
      file="$(caddy_config_file)"
      sed -i "s#127.0.0.1:${old_port}#127.0.0.1:${new_port}#g" "$file"
      caddy_apply
      systemd_enable_active caddy.service Caddy
      ;;
    apache)
      while IFS= read -r file; do sed -i "s#127.0.0.1:${old_port}#127.0.0.1:${new_port}#g" "$file"; done < <(find /etc/apache2/sites-available -maxdepth 1 -type f -name 'sublink2*.conf')
      apache2ctl configtest
      systemctl reload apache2
      systemd_enable_active apache2.service Apache
      ;;
    nginx)
      sed -i "s#127.0.0.1:${old_port}#127.0.0.1:${new_port}#g" /etc/nginx/sites-available/sublink2.conf
      nginx -t
      systemctl reload nginx
      systemd_enable_active nginx.service Nginx
      ;;
  esac
}

ensure_saved_proxy(){
  [ -n "${DOMAIN:-}" ] || return 0
  local kind
  kind="$(managed_proxy_kind)"
  case "$kind" in
    caddy) systemd_enable_active caddy.service Caddy ;;
    apache) systemd_enable_active apache2.service Apache ;;
    nginx) systemd_enable_active nginx.service Nginx ;;
    '') warn "配置中保存了域名 ${DOMAIN}，但未找到 SubLink2 托管的反向代理配置。" ;;
  esac
}

show_access(){
  local url
  if [ -n "${DOMAIN:-}" ]; then
    if [ "${DOMAIN_HTTPS:-0}" = "1" ]; then url="https://${DOMAIN}"; else url="http://${DOMAIN}"; fi
  elif [ "$SUBLINK_HOST" = "127.0.0.1" ]; then
    url="http://127.0.0.1:${SUBLINK_PORT}（仅本机；可绑定域名或使用 SSH 隧道）"
  else
    url="http://$(public_ipv4):${SUBLINK_PORT}"
  fi
  echo
  echo -e "${C_GREEN}${C_BOLD}══════════ ${APP_NAME} 已就绪 ══════════${C_RESET}"
  echo -e "后台地址：${C_BOLD}${url}${C_RESET}"
  echo -e "用户名：  ${C_BOLD}${ADMIN_USER}${C_RESET}"
  echo -e "密码：    ${C_BOLD}${ADMIN_PASSWORD}${C_RESET}"
  echo -e "管理命令：${C_BOLD}sub${C_RESET}"
  echo -e "数据目录：${C_BOLD}${DATA_DIR}${C_RESET}"
  echo -e "配置文件：${C_BOLD}${CONFIG_FILE}${C_RESET}"
  echo -e "${C_GREEN}${C_BOLD}════════════════════════════════════${C_RESET}"
  echo
}

install_app(){
  require_root
  install_packages
  check_python
  ensure_service_user
  local release_id release_dir config_backup="" had_config=0
  release_id="$(date -u +%Y%m%d%H%M%S)-$(random_string 6)"
  release_dir="$RELEASES_DIR/$release_id"
  mkdir -p "$release_dir"
  if [ -f "$CONFIG_FILE" ]; then
    had_config=1
    load_config
    config_backup="$(mktemp)"
    cp -a "$CONFIG_FILE" "$config_backup"
    warn "检测到已有安装：数据库、账号、APP_SECRET、端口和域名设置将全部保留。"
  else
    SUBLINK_HOST="$DEFAULT_HOST"
    SUBLINK_PORT="$(find_free_port)"
    ADMIN_USER="admin_$(random_string 6)"
    ADMIN_PASSWORD="$(random_string 20)"
    APP_SECRET="$(fernet_key)"
    PUBLIC_BASE_URL=""
    DOMAIN=""
    DOMAIN_HTTPS=0
    write_config
  fi
  fetch_source "$release_dir"
  if ! build_release "$release_dir"; then
    rm -rf "$release_dir"
    [ "$had_config" = 0 ] && rm -f "$CONFIG_FILE"
    die "新版本构建失败，当前运行版本未改变。"
  fi
  write_config
  write_systemd_unit
  if ! atomic_activate "$release_dir"; then
    rm -rf "$release_dir"
    if [ -n "$config_backup" ]; then cp -a "$config_backup" "$CONFIG_FILE"; fi
    rm -f "$config_backup"
    die "更新失败，已尝试恢复上一版本。"
  fi
  rm -f "$config_backup"
  install_command "$release_dir"
  ensure_saved_proxy
  systemd_enable_active "$SERVICE_NAME" "$APP_NAME"
  prune_releases
  success "$APP_NAME 原生安装/更新完成。"
  show_access
}

change_port(){
  require_root; load_config
  local new_port="${ARG2:-}" old_port="$SUBLINK_PORT" backup
  [ -n "$new_port" ] || read -rp "请输入新端口 [当前 ${SUBLINK_PORT}]：" new_port
  validate_port "$new_port"
  [ "$new_port" = "$old_port" ] || ! port_in_use "$new_port" || die "端口 ${new_port} 已被占用。"
  [ "$new_port" != "$old_port" ] || { warn "端口没有变化。"; return; }
  backup="$(mktemp)"; cp -a "$CONFIG_FILE" "$backup"
  SUBLINK_PORT="$new_port"; write_config
  if ! systemctl restart "$SERVICE_NAME" || ! health_check; then
    cp -a "$backup" "$CONFIG_FILE"; systemctl restart "$SERVICE_NAME" || true; rm -f "$backup"
    die "新端口启动失败，已恢复旧端口。"
  fi
  if ! refresh_proxy_port "$old_port" "$new_port"; then
    warn "反向代理更新失败，正在恢复旧端口。"
    cp -a "$backup" "$CONFIG_FILE"; systemctl restart "$SERVICE_NAME" || true
    refresh_proxy_port "$new_port" "$old_port" || true
    rm -f "$backup"; die "端口修改失败，已尝试回滚应用与代理配置。"
  fi
  rm -f "$backup"
  success "端口已改为 ${new_port}，所有受管 Caddy/Apache/Nginx 代理均已同步。"
  show_access
}

change_credentials(){
  require_root; load_config
  local new_user="${ARG2:-}" new_pass="${ARG3:-}" backup
  [ -n "$new_user" ] || read -rp "请输入新用户名 [留空随机生成]：" new_user
  if [ -z "$new_pass" ]; then read -rsp "请输入新密码 [留空随机生成]：" new_pass; echo; fi
  new_user="${new_user:-admin_$(random_string 6)}"
  new_pass="${new_pass:-$(random_string 20)}"
  [[ "$new_user" =~ ^[A-Za-z0-9_.-]{3,64}$ ]] || die "用户名长度 3-64，仅允许字母、数字、点、下划线、短横线。"
  [[ "$new_pass" =~ ^[A-Za-z0-9_.@#%+=:-]{8,128}$ ]] || die "密码长度 8-128，仅允许常用安全字符。"
  backup="$(mktemp)"; cp -a "$CONFIG_FILE" "$backup"
  ADMIN_USER="$new_user"; ADMIN_PASSWORD="$new_pass"; write_config
  if ! systemctl restart "$SERVICE_NAME" || ! health_check; then
    cp -a "$backup" "$CONFIG_FILE"; systemctl restart "$SERVICE_NAME" || true; rm -f "$backup"
    die "新凭据应用失败，已恢复原配置。"
  fi
  rm -f "$backup"
  success "后台账号密码已更新，原登录会话已失效。"
  show_access
}

bind_domain(){
  require_root; load_config
  local domain="${ARG2:-}" answer="${ARG3:-}" https=1 old_base="$PUBLIC_BASE_URL" old_domain="$DOMAIN" old_https="$DOMAIN_HTTPS"
  [ -n "$domain" ] || read -rp "请输入已解析到本机的域名：" domain
  domain="${domain#http://}"; domain="${domain#https://}"; domain="${domain%%/*}"; domain="${domain,,}"
  [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || die "域名格式不正确。"
  [ -n "$answer" ] || read -rp "是否启用 HTTPS？[Y/n]：" answer
  [[ "$answer" =~ ^[Nn]$ ]] && https=0
  [ "$https" = 0 ] || dns_preflight "$domain"

  if port_is_listening 80 && port_owned_only_by 80 '"caddy"'; then
    if port_is_listening 443 && ! port_owned_only_by 443 '"caddy"'; then listener_summary 443 >&2; die "443 端口由非 Caddy 程序占用。"; fi
    write_caddy_proxy "$domain" "$https"
    info "已复用现有 Caddy。"
  elif port_is_listening 80 && port_owned_only_by 80 '"(apache2|httpd)"'; then
    write_apache_proxy "$domain" "$https"
    info "已复用现有 Apache。"
  elif ! port_is_listening 80 || port_owned_only_by 80 '"nginx"'; then
    write_nginx_proxy "$domain" "$https"
    info "已复用或安装 Nginx。"
  else
    warn "80 端口占用详情："; listener_summary 80 >&2
    die "80 端口由无法安全识别的程序占用；未停止现有服务。"
  fi

  DOMAIN="$domain"; DOMAIN_HTTPS="$https"
  if [ "$https" = 1 ]; then PUBLIC_BASE_URL="https://${domain}"; else PUBLIC_BASE_URL="http://${domain}"; fi
  write_config
  if ! systemctl restart "$SERVICE_NAME" || ! health_check; then
    PUBLIC_BASE_URL="$old_base"; DOMAIN="$old_domain"; DOMAIN_HTTPS="$old_https"; write_config
    systemctl restart "$SERVICE_NAME" || true
    die "域名配置已写入代理，但应用重启失败；应用配置已回滚，请检查：sub logs"
  fi
  ensure_saved_proxy
  success "域名绑定完成：${PUBLIC_BASE_URL}"
  show_access
}

remove_managed_proxies(){
  local file temporary begin='# BEGIN SUBLINK2 MANAGED' end='# END SUBLINK2 MANAGED'
  for file in /etc/caddy/Caddyfile /etc/caddy/conf.d/sublink2.caddy; do
    [ -f "$file" ] || continue
    temporary="$(mktemp)"
    awk -v begin="$begin" -v end="$end" '$0==begin{skip=1;next} $0==end{skip=0;next} !skip{print}' "$file" >"$temporary"
    install -m 0644 "$temporary" "$file"; rm -f "$temporary"
    if systemctl is-active --quiet caddy.service; then caddy_apply || warn "Caddy 清理配置后重载失败，请手工检查。"; fi
  done
  if [ -d /etc/apache2/sites-available ]; then
    a2dissite sublink2.conf >/dev/null 2>&1 || true
    rm -f /etc/apache2/sites-available/sublink2.conf /etc/apache2/sites-available/sublink2-le-ssl.conf /etc/apache2/sites-enabled/sublink2.conf /etc/apache2/sites-enabled/sublink2-le-ssl.conf
    command_exists apache2ctl && apache2ctl configtest >/dev/null 2>&1 && systemctl reload apache2 || true
  fi
  rm -f /etc/nginx/sites-enabled/sublink2.conf /etc/nginx/sites-available/sublink2.conf
  command_exists nginx && nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
}

uninstall_app(){
  require_root
  local confirm="${ARG2:-}" delete_data="${ARG3:-}"
  [ -f "$CONFIG_FILE" ] && load_config || true
  [ -n "$confirm" ] || read -rp "确定卸载 ${APP_NAME}？输入 YES 继续：" confirm
  [ "$confirm" = YES ] || { warn "已取消卸载。"; return; }
  [ -n "$delete_data" ] || read -rp "是否同时删除数据库与密钥配置？[y/N]：" delete_data
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE" "$COMMAND_PATH"
  systemctl daemon-reload
  remove_managed_proxies
  rm -rf "$INSTALL_ROOT" "$WHEEL_CACHE"
  if [[ "$delete_data" =~ ^[Yy]$ ]]; then
    rm -rf "$DATA_DIR" "$CONFIG_DIR"
    userdel "$SERVICE_USER" >/dev/null 2>&1 || true
    success "程序、数据库与配置已删除。"
  else
    warn "已保留 ${DATA_DIR} 与 ${CONFIG_FILE}；再次安装会恢复数据库、账号、APP_SECRET、端口和域名设置。"
    success "$APP_NAME 已安全卸载。"
  fi
}

show_status(){
  require_root
  [ -f "$CONFIG_FILE" ] || { warn "$APP_NAME 尚未安装。"; return; }
  load_config
  show_access
  systemctl --no-pager --full status "$SERVICE_NAME" || true
  local kind proxy_service=""; kind="$(managed_proxy_kind)"
  case "$kind" in
    caddy) proxy_service="caddy.service" ;;
    apache) proxy_service="apache2.service" ;;
    nginx) proxy_service="nginx.service" ;;
  esac
  [ -z "$proxy_service" ] || echo "反向代理：${kind}（enabled=$(systemctl is-enabled "$proxy_service" 2>/dev/null || true), active=$(systemctl is-active "$proxy_service" 2>/dev/null || true)）"
}

show_logs(){
  require_root
  local lines="${ARG2:-100}"
  [[ "$lines" =~ ^[0-9]+$ ]] || die "日志行数必须是数字。"
  journalctl -u "$SERVICE_NAME" --no-pager -n "$lines"
}

show_menu(){
  while true; do
    clear 2>/dev/null || true
    echo -e "${C_GREEN}${C_BOLD}┌──────────────────────────────────┐${C_RESET}"
    echo -e "${C_GREEN}${C_BOLD}│      SubLink2 原生管理工具        │${C_RESET}"
    echo -e "${C_GREEN}${C_BOLD}└──────────────────────────────────┘${C_RESET}"
    echo "  1. 安装 / 安全更新"
    echo "  2. 更换端口"
    echo "  3. 重设后台账号密码"
    echo "  4. 绑定域名与 HTTPS"
    echo "  5. 查看状态"
    echo "  6. 查看日志"
    echo "  7. 安全卸载"
    echo "  0. 退出"
    echo
    read -rp "请选择 [0-7]：" choice
    case "$choice" in
      1) install_app;; 2) change_port;; 3) change_credentials;; 4) bind_domain;;
      5) show_status;; 6) show_logs;; 7) uninstall_app;; 0) exit 0;; *) warn "无效选项。";;
    esac
    echo; read -rp "按回车键返回菜单……" _ || true
  done
}

case "$ACTION" in
  menu|'') show_menu;;
  install|update) install_app;;
  port) change_port;;
  credentials) change_credentials;;
  domain) bind_domain;;
  status) show_status;;
  logs) show_logs;;
  uninstall) uninstall_app;;
  *) die "未知命令：$ACTION（支持 install/update/port/credentials/domain/status/logs/uninstall）";;
esac
