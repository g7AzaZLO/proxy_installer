#!/usr/bin/env bash
set -euo pipefail

HTTP_PROXY_PORT=8080
HTTP_PROXY_USER="proxyuser"
SQUID_CONF="/etc/squid/squid.conf"
SQUID_PASSWD="/etc/squid/passwd"
SQUID_SERVICE="squid"
MIN_PROXY_PORT=1024
MAX_PROXY_PORT=65535
MIN_PASSWORD_LEN=12
MAX_PASSWORD_LEN=128

DANTE_APP="socks5-manager"
DANTE_CONF="/etc/danted.conf"
DANTE_SERVICE="danted"
DANTE_USERS_FILE="/etc/proxy-installer/dante-users.list"
SCRIPT_RUNNING=1

http_log() { echo "[http-manager] $*"; }
dante_log() { echo "[$DANTE_APP] $*"; }
is_sourced() { [[ "${BASH_SOURCE[0]}" != "$0" ]]; }
terminate_script() {
  local code="$1"
  if is_sourced; then
    return "$code"
  fi
  exit "$code"
}
err() {
  echo "[proxy-installer] ERROR: $*" >&2
  terminate_script 1
}
stop_script() {
  SCRIPT_RUNNING=0
}


require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Запусти через sudo."
  fi
  return 0
}

read_nonempty() {
  local prompt="$1"
  local value=""

  while true; do
    read -r -p "$prompt" value
    [[ -n "$value" ]] && {
      echo "$value"
      return
    }
    echo "Пустое значение, попробуй ещё раз."
  done
}

read_secret() {
  local prompt="$1"
  local value=""

  while true; do
    echo -n "$prompt"
    read -r -s value
    echo
    [[ -n "$value" ]] && {
      echo "$value"
      return
    }
    echo "Пароль не может быть пустым."
  done
}

menu_choose_option() {
  local title="$1"
  shift
  local options=("$@")
  local selected=0
  local key=""
  local total="${#options[@]}"

  (( total > 0 )) || err "Меню пустое."

  if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    echo >&2
    echo "$title" >&2
    local i=0
    for i in "${!options[@]}"; do
      printf "%d) %s\n" "$((i + 1))" "${options[$i]}" >&2
    done
    local fallback
    fallback="$(read_nonempty "Выбор [1-${total}]: ")"
    [[ "$fallback" =~ ^[0-9]+$ ]] || err "Неверный выбор."
    [[ "$fallback" -ge 1 && "$fallback" -le "$total" ]] || err "Неверный выбор."
    echo "${options[$((fallback - 1))]}"
    return
  fi

  while true; do
    echo >&2
    echo "$title" >&2
    local i=0
    for i in "${!options[@]}"; do
      if [[ "$i" -eq "$selected" ]]; then
        printf "  \033[7m> %s\033[0m\n" "${options[$i]}" >&2
      else
        printf "    %s\n" "${options[$i]}" >&2
      fi
    done
    echo "Используй ↑/↓ и Enter." >&2

    IFS= read -rsn1 key < /dev/tty
    if [[ "$key" == $'\x1b' ]]; then
      IFS= read -rsn2 -t 0.1 key < /dev/tty || true
      case "$key" in
        "[A") selected=$(( (selected - 1 + total) % total )) ;;
        "[B") selected=$(( (selected + 1) % total )) ;;
      esac
    elif [[ -z "$key" || "$key" == $'\n' ]]; then
      printf "\033[%dA" "$((total + 3))" >&2
      printf "\033[J" >&2
      echo "${options[$selected]}"
      return
    fi

    printf "\033[%dA" "$((total + 3))" >&2
    printf "\033[J" >&2
  done
}

read_port() {
  local prompt="$1"
  local port=""

  port="$(read_nonempty "${prompt} [${MIN_PROXY_PORT}-${MAX_PROXY_PORT}]: ")"
  [[ "$port" =~ ^[0-9]+$ ]] || err "Порт должен быть числом в диапазоне ${MIN_PROXY_PORT}-${MAX_PROXY_PORT}."
  [[ "$port" -ge "$MIN_PROXY_PORT" && "$port" -le "$MAX_PROXY_PORT" ]] || err "Порт должен быть в диапазоне ${MIN_PROXY_PORT}-${MAX_PROXY_PORT}."
  echo "$port"
}

read_proxy_login() {
  local username=""
  while true; do
    username="$(read_nonempty "Логин [3-32, латиница/цифры/._-]: ")"
    if [[ "$username" =~ ^[a-zA-Z0-9._-]{3,32}$ ]]; then
      echo "$username"
      return
    fi
    echo "Неверный логин. Разрешено: латиница, цифры, '.', '_', '-'. Длина: 3-32."
  done
}

validate_password_length() {
  local password="$1"
  local pass_len=0
  pass_len="${#password}"
  [[ "$pass_len" -ge "$MIN_PASSWORD_LEN" && "$pass_len" -le "$MAX_PASSWORD_LEN" ]] || err "Длина пароля должна быть ${MIN_PASSWORD_LEN}-${MAX_PASSWORD_LEN} символов."
}

install_http_pkgs() {
  http_log "Установка Squid и зависимостей..."
  apt-get update -y
  apt-get install -y squid apache2-utils curl
}

render_squid_conf() {
  local port="$1"

  cat > "$SQUID_CONF" <<EOF
http_port ${port}

auth_param basic program /usr/lib/squid/basic_ncsa_auth ${SQUID_PASSWD}
auth_param basic realm Proxy
acl authenticated proxy_auth REQUIRED
http_access allow authenticated
http_access deny all

access_log none
cache deny all
EOF
}

ensure_squid_service() {
  http_log "Перезапуск Squid..."
  systemctl restart "$SQUID_SERVICE"
  systemctl enable "$SQUID_SERVICE"
}

restart_http_service() {
  ensure_squid_service
  show_http_status
}

create_or_update_http_user() {
  local username password
  username="$(read_proxy_login)"
  password="$(choose_password)"

  touch "$SQUID_PASSWD"
  chmod 640 "$SQUID_PASSWD"

  htpasswd -b "$SQUID_PASSWD" "$username" "$password"

  echo
  echo "======= ДАННЫЕ ДОСТУПА ======="
  echo "Логин:   $username"
  echo "Пароль:  $password"
  echo "=============================="
  echo
}

delete_http_user() {
  local username
  username="$(read_nonempty "Логин для удаления: ")"
  htpasswd -D "$SQUID_PASSWD" "$username" || true
  http_log "Удалён (если существовал)."
}

install_http_squid() {
  local proxy_pass server_ip port
  port="$(read_port "Порт HTTP-прокси (например 8080)")"
  proxy_pass="$(openssl rand -base64 12 | tr -d '/=+' | cut -c1-12)"
  server_ip="$(curl -s ifconfig.me)"

  install_http_pkgs
  render_squid_conf "$port"

  touch "$SQUID_PASSWD"
  chmod 640 "$SQUID_PASSWD"
  htpasswd -bc "$SQUID_PASSWD" "$HTTP_PROXY_USER" "$proxy_pass"
  ensure_squid_service

  echo
  echo "✅ HTTP ПРОКСИ ГОТОВ"
  echo "----------------------------------------"
  echo "http://${HTTP_PROXY_USER}:${proxy_pass}@${server_ip}:${port}"
  echo "----------------------------------------"
  echo
}

change_http_port() {
  local port
  port="$(read_port "Новый порт для Squid")"
  render_squid_conf "$port"
  ensure_squid_service
  http_log "Порт обновлён, сервис перезапущен."
}

show_http_status() {
  systemctl status "$SQUID_SERVICE" --no-pager || true
}

list_http_users() {
  if [[ ! -r "$SQUID_PASSWD" ]]; then
    echo "Файл пользователей Squid не найден: $SQUID_PASSWD"
    return
  fi
  echo "Пользователи Squid:"
  awk -F: '{print "- " $1}' "$SQUID_PASSWD"
}

squid_menu() {
  while true; do
    local choice
    choice="$(menu_choose_option "HTTP (Squid):" \
      "Установить/настроить HTTP-прокси" \
      "Добавить/обновить пользователя (с автогенерацией пароля)" \
      "Удалить пользователя" \
      "Сменить порт" \
      "Статус" \
      "Рестарт сервиса" \
      "Список пользователей" \
      "Назад")"

    case "$choice" in
      "Установить/настроить HTTP-прокси") install_http_squid ;;
      "Добавить/обновить пользователя (с автогенерацией пароля)") create_or_update_http_user ;;
      "Удалить пользователя") delete_http_user ;;
      "Сменить порт") change_http_port ;;
      "Статус") show_http_status ;;
      "Рестарт сервиса") restart_http_service ;;
      "Список пользователей") list_http_users ;;
      "Назад") return ;;
      *) echo "Неверный выбор." ;;
    esac
  done
}

install_dante_pkgs() {
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y dante-server ufw fail2ban python3-systemd
}

get_iface() {
  local iface=""
  iface="$(ip route | awk '/default/ {print $5; exit}' || true)"
  echo "${iface:-eth0}"
}

get_primary_ip() {
  local ip=""
  ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -fsS ifconfig.me 2>/dev/null || true)"
  fi
  echo "${ip:-N/A}"
}

get_dante_port() {
  local port=""
  if [[ -r "$DANTE_CONF" ]]; then
    port="$(awk '/^internal:/ {for (i = 1; i <= NF; i++) if ($i == "=") {print $(i + 1); exit}}' "$DANTE_CONF" || true)"
  fi
  echo "${port:-N/A}"
}

resolve_dante_service() {
  if systemctl cat danted.service >/dev/null 2>&1; then
    echo "danted"
    return
  fi
  if systemctl cat sockd.service >/dev/null 2>&1; then
    echo "sockd"
    return
  fi
  echo "$DANTE_SERVICE"
}

ensure_dante_users_store() {
  mkdir -p "$(dirname "$DANTE_USERS_FILE")"
  touch "$DANTE_USERS_FILE"
  chmod 600 "$DANTE_USERS_FILE"
}

register_dante_user() {
  local username="$1"
  ensure_dante_users_store
  if ! grep -Fxq "$username" "$DANTE_USERS_FILE"; then
    echo "$username" >> "$DANTE_USERS_FILE"
  fi
}

unregister_dante_user() {
  local username="$1"
  ensure_dante_users_store
  local temp_file
  temp_file="$(mktemp)"
  grep -Fxv "$username" "$DANTE_USERS_FILE" > "$temp_file" || true
  mv "$temp_file" "$DANTE_USERS_FILE"
}

gen_password() {
  local length="$1"

  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -d '\n' | tr -d '/+=' | head -c "$length"
    return
  fi

  tr -dc 'A-Za-z0-9!@#%^_-+=' < /dev/urandom | head -c "$length"
}

choose_password() {
  local mode=""

  mode="$(menu_choose_option "Пароль:" \
    "Ввести вручную" \
    "Автосгенерировать (рекомендую)")"

  case "$mode" in
    "Ввести вручную")
      local manual_password
      manual_password="$(read_secret "Пароль (ввод скрыт, ${MIN_PASSWORD_LEN}-${MAX_PASSWORD_LEN} символов): ")"
      validate_password_length "$manual_password"
      echo "$manual_password"
      ;;
    "Автосгенерировать (рекомендую)")
      local len
      len="$(read_nonempty "Длина пароля [${MIN_PASSWORD_LEN}-${MAX_PASSWORD_LEN}] (рекомендую 18): ")"
      [[ "$len" =~ ^[0-9]+$ ]] || err "Длина должна быть числом в диапазоне ${MIN_PASSWORD_LEN}-${MAX_PASSWORD_LEN}."
      [[ "$len" -ge "$MIN_PASSWORD_LEN" && "$len" -le "$MAX_PASSWORD_LEN" ]] || err "Длина должна быть в диапазоне ${MIN_PASSWORD_LEN}-${MAX_PASSWORD_LEN}."
      gen_password "$len"
      ;;
    *)
      err "Неверный выбор."
      ;;
  esac
}

render_dante_conf() {
  local iface="$1"
  local port="$2"

  cat > "$DANTE_CONF" <<EOF
logoutput: syslog

internal: $iface port = $port
external: $iface

clientmethod: none
socksmethod: username

user.privileged: root
user.notprivileged: nobody

timeout.connect: 30
timeout.io: 30

# Клиенты могут приходить откуда угодно (защита: пароль + fail2ban + нестандартный порт)
client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
}

# Разрешаем только CONNECT (без UDP)
socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  command: connect
  socksmethod: username
}
EOF

  chmod 600 "$DANTE_CONF"
}

ensure_dante_service() {
  local service
  service="$(resolve_dante_service)"
  systemctl enable "$service"
  systemctl restart "$service"
}

setup_ufw() {
  local port="$1"

  ufw --force enable
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "$port/tcp"
}

wait_for_fail2ban() {
  local attempts=10
  local i=1
  while [[ "$i" -le "$attempts" ]]; do
    if fail2ban-client ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

configure_fail2ban_defaults() {
  cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
backend = systemd
banaction = ufw
banaction_allports = ufw
EOF
}

setup_fail2ban() {
  local port="$1"
  local service_name=""
  local unit_name=""

  service_name="$(resolve_dante_service)"
  unit_name="${service_name}.service"

  cat > /etc/fail2ban/filter.d/danted.conf <<'EOF'
[Definition]
failregex = .*(sockd|danted).*(authentication failed|auth failed).*
ignoreregex =
EOF

  cat > /etc/fail2ban/jail.d/danted.local <<EOF
[danted]
enabled = true
port = $port
filter = danted
backend = systemd
journalmatch = _SYSTEMD_UNIT=$unit_name
action = ufw
maxretry = 5
findtime = 600
bantime = 3600
EOF

  configure_fail2ban_defaults
  systemctl enable fail2ban
  systemctl restart fail2ban

  if ! wait_for_fail2ban; then
    rm -f /var/run/fail2ban/fail2ban.sock || true
    configure_fail2ban_defaults
    systemctl restart fail2ban || true
  fi

  if ! wait_for_fail2ban; then
    echo "Fail2ban не запустился. Диагностика:" >&2
    systemctl status fail2ban --no-pager || true
    journalctl -u fail2ban -n 80 --no-pager || true
    fail2ban-client -d 2>&1 | sed -n '1,200p' || true
    err "Fail2ban не удалось запустить."
  fi

  fail2ban-client reload || true

  if ! fail2ban-client status danted >/dev/null 2>&1; then
    echo "Fail2ban запущен, но jail 'danted' не создан. Диагностика:" >&2
    fail2ban-client status || true
    journalctl -u fail2ban -n 80 --no-pager || true
    err "Jail 'danted' не активировался."
  fi
}

create_or_update_dante_user() {
  local username password ip port
  username="$(read_proxy_login)"
  password="$(choose_password)"

  if id "$username" &>/dev/null; then
    dante_log "Пользователь '$username' существует — обновляю пароль."
  else
    dante_log "Создаю пользователя '$username' (без shell-доступа)."
    useradd -M -s /usr/sbin/nologin "$username"
  fi

  echo "$username:$password" | chpasswd
  register_dante_user "$username"

  ip="$(get_primary_ip)"
  port="$(get_dante_port)"

  echo
  echo "======= ДАННЫЕ ДОСТУПА ======="
  echo "Логин:   $username"
  echo "Пароль:  $password"
  echo "IP:      $ip"
  echo "Порт:    $port"
  if [[ "$port" != "N/A" && "$ip" != "N/A" ]]; then
    echo "SOCKS5:  socks5://$username:$password@$ip:$port"
  else
    echo "SOCKS5:  недоступно (сначала выполни 'Установить/настроить SOCKS5')"
  fi
  echo "=============================="
  echo
}

delete_dante_user() {
  local username
  username="$(read_nonempty "Логин для удаления: ")"
  userdel "$username" || true
  unregister_dante_user "$username"
  dante_log "Удалён (если существовал)."
}

install_dante_flow() {
  local iface port ip
  install_dante_pkgs

  iface="$(get_iface)"
  port="$(read_port "Порт SOCKS5 (например 31827)")"

  render_dante_conf "$iface" "$port"
  create_or_update_dante_user
  setup_ufw "$port"
  setup_fail2ban "$port"
  ensure_dante_service

  ip="$(hostname -I | awk '{print $1}')"

  echo
  echo "====== ГОТОВО ======"
  echo "SOCKS5: $ip:$port"
  echo "Тест:"
  echo "curl --socks5 USER:PASS@$ip:$port https://ifconfig.me"
  echo "===================="
  echo
}

change_dante_port() {
  local iface port
  iface="$(get_iface)"
  port="$(read_port "Новый порт SOCKS5")"

  render_dante_conf "$iface" "$port"
  ufw allow "$port/tcp" || true
  local service
  service="$(resolve_dante_service)"
  systemctl restart "$service"
  dante_log "Порт обновлён, сервис перезапущен."
}

show_dante_status() {
  local service
  service="$(resolve_dante_service)"
  systemctl status "$service" --no-pager || true
  if ! fail2ban-client ping >/dev/null 2>&1; then
    echo "fail2ban не запущен."
    return
  fi
  if fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {print $2}' | tr ',' '\n' | awk '{$1=$1;print}' | grep -Fxq "danted"; then
    fail2ban-client status danted || true
  else
    echo "fail2ban запущен, но jail 'danted' не найден."
  fi
}

restart_dante_service() {
  local service
  service="$(resolve_dante_service)"
  systemctl restart "$service"
  show_dante_status
}

list_dante_users() {
  ensure_dante_users_store
  if [[ ! -s "$DANTE_USERS_FILE" ]]; then
    echo "Список пользователей пуст."
    return
  fi

  echo "Пользователи SOCKS5:"
  while IFS= read -r username; do
    [[ -z "$username" ]] && continue
    if id "$username" &>/dev/null; then
      echo "- $username"
    else
      echo "- $username (не существует в системе)"
    fi
  done < "$DANTE_USERS_FILE"
}

show_dante_diagnostics() {
  local service
  service="$(resolve_dante_service)"
  echo "Последние логи $service:"
  journalctl -u "$service" -n 60 --no-pager || true
}

dante_menu() {
  while true; do
    local choice
    choice="$(menu_choose_option "SOCKS5 (Dante):" \
      "Установить/настроить SOCKS5" \
      "Добавить/обновить пользователя (с автогенерацией пароля)" \
      "Удалить пользователя" \
      "Сменить порт" \
      "Статус" \
      "Рестарт сервиса" \
      "Список пользователей" \
      "Диагностика (логи)" \
      "Назад")"

    case "$choice" in
      "Установить/настроить SOCKS5") install_dante_flow ;;
      "Добавить/обновить пользователя (с автогенерацией пароля)") create_or_update_dante_user ;;
      "Удалить пользователя") delete_dante_user ;;
      "Сменить порт") change_dante_port ;;
      "Статус") show_dante_status ;;
      "Рестарт сервиса") restart_dante_service ;;
      "Список пользователей") list_dante_users ;;
      "Диагностика (логи)") show_dante_diagnostics ;;
      "Назад") return ;;
      *) echo "Неверный выбор." ;;
    esac
  done
}

main_menu() {
  local choice
  choice="$(menu_choose_option "Выбери тип прокси:" \
    "HTTP (Squid)" \
    "SOCKS5 (Dante)" \
    "Выход")"

  case "$choice" in
    "HTTP (Squid)") squid_menu ;;
    "SOCKS5 (Dante)") dante_menu ;;
    "Выход") stop_script ;;
    *) echo "Неверный выбор." ;;
  esac
}

require_root

while (( SCRIPT_RUNNING )); do
  main_menu
done
