#!/usr/bin/env bash
# setup.sh — генерация секретов и рендеринг конфигов frp.
#
# Использование:
#   ./setup.sh [адрес_VPS]        # первая настройка / повторный рендер (секреты сохраняются)
#   ./setup.sh --rotate [адрес]   # перевыпуск ВСЕХ секретов (токен + оба secretKey)
#   ./setup.sh show               # показать текущие секреты
#
# Хранилище секретов: .secrets (chmod 600). Источник истины для конфигов —
# этот скрипт: он перезаписывает vps/.env и client/frpc.toml.
# Секреты печатаются в терминал только при генерации — НЕ в логи docker.
set -euo pipefail
cd "$(dirname "$0")"

SECRETS=.secrets
PLACEHOLDER="<IP или домен VPS>"

gen() { openssl rand -hex 32; }
need_openssl() { command -v openssl >/dev/null || { echo "Ошибка: openssl не найден" >&2; exit 1; }; }

# --- разбор аргументов ---
cmd=render; addr=""
case "${1:-}" in
  --rotate) cmd=rotate; addr="${2:-}" ;;
  show)     cmd=show ;;
  "")       : ;;
  *)        addr="$1" ;;
esac

# --- загрузка сохранённых секретов ---
if [ -f "$SECRETS" ]; then
  # shellcheck disable=SC1090
  . "$SECRETS"
fi

if [ "$cmd" = show ]; then
  echo "AUTH_TOKEN=${AUTH_TOKEN:-<не сгенерирован>}"
  echo "SECRET_STCP=${SECRET_STCP:-<не сгенерирован>}"
  echo "SECRET_XTCP=${SECRET_XTCP:-<не сгенерирован>}"
  echo "SERVER_ADDR=${SERVER_ADDR:-<не задан>}"
  exit 0
fi

# --- адрес VPS: аргумент > сохранённый > плейсхолдер ---
: "${SERVER_ADDR:=$PLACEHOLDER}"
if [ -n "$addr" ]; then SERVER_ADDR="$addr"; fi

# --- генерация: rotate — все заново; иначе — только отсутствующие ---
printed=0
if [ "$cmd" = rotate ]; then
  need_openssl
  AUTH_TOKEN=$(gen); SECRET_STCP=$(gen); SECRET_XTCP=$(gen)
  printed=1
  reason="Перевыпущены новые секреты"
else
  new=0
  if [ -z "${AUTH_TOKEN:-}" ];   then need_openssl; AUTH_TOKEN=$(gen);   new=1; fi
  if [ -z "${SECRET_STCP:-}" ];  then need_openssl; SECRET_STCP=$(gen);  new=1; fi
  if [ -z "${SECRET_XTCP:-}" ];  then need_openssl; SECRET_XTCP=$(gen);  new=1; fi
  printed=$new
  if [ "$new" = 1 ]; then reason="Сгенерированы новые секреты"; fi
fi

# --- сохранение хранилища ---
umask 077
cat > "$SECRETS" <<EOF
AUTH_TOKEN=$AUTH_TOKEN
SECRET_STCP=$SECRET_STCP
SECRET_XTCP=$SECRET_XTCP
SERVER_ADDR="${SERVER_ADDR}"
EOF
chmod 600 "$SECRETS"

# --- рендеринг конфигов ---
cat > vps/.env <<EOF
FRP_AUTH_TOKEN=${AUTH_TOKEN}
EOF
chmod 600 vps/.env

cat > client/frpc.toml <<EOF
serverAddr = "${SERVER_ADDR}"
serverPort = 7000
auth.method = "token"
auth.token = "${AUTH_TOKEN}"

[[proxies]]
name = "private_ssh_stcp"
type = "stcp"
secretKey = "${SECRET_STCP}"
localIP = "127.0.0.1"
localPort = 22

[[proxies]]
name = "private_ssh_xtcp"
type = "xtcp"
secretKey = "${SECRET_XTCP}"
localIP = "127.0.0.1"
localPort = 22
EOF
chmod 600 client/frpc.toml

# --- вывод ---
if [ "$printed" = 1 ]; then
  echo "$reason: (хранятся в $SECRETS)"
  echo "  AUTH_TOKEN=$AUTH_TOKEN"
  echo "  SECRET_STCP=$SECRET_STCP"
  echo "  SECRET_XTCP=$SECRET_XTCP"
else
  echo "Секреты без изменений (показать: ./setup.sh show)"
fi
echo "SERVER_ADDR=$SERVER_ADDR"
if [ "$SERVER_ADDR" = "$PLACEHOLDER" ]; then
  echo "ВНИМАНИЕ: адрес VPS не задан. При деплое: ./setup.sh <IP или домен VPS>"
fi
echo "Отрендерено: vps/.env, client/frpc.toml"
