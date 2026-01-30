#!/usr/bin/env bash
set -e

PROXY_PORT=8080
PROXY_USER="proxyuser"
PROXY_PASS="$(openssl rand -base64 12 | tr -d /=+ | cut -c1-12)"
SERVER_IP="$(curl -s ifconfig.me)"

echo "▶ Установка Squid и зависимостей..."
apt update -y
apt install -y squid apache2-utils curl

echo "▶ Создание пользователя прокси..."
htpasswd -bc /etc/squid/passwd "$PROXY_USER" "$PROXY_PASS"

echo "▶ Конфигурация Squid..."
cat > /etc/squid/squid.conf <<EOF
http_port ${PROXY_PORT}

auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwd
auth_param basic realm Proxy
acl authenticated proxy_auth REQUIRED
http_access allow authenticated
http_access deny all

access_log none
cache deny all
EOF

echo "▶ Перезапуск Squid..."
systemctl restart squid
systemctl enable squid

echo ""
echo "✅ ПРОКСИ ГОТОВ"
echo "----------------------------------------"
echo "HTTP Proxy:"
echo "http://${PROXY_USER}:${PROXY_PASS}@${SERVER_IP}:${PROXY_PORT}"
echo "----------------------------------------"
