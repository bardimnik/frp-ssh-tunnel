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

# --- функции PKI (mTLS): ECDSA P-256, 365 дней ---
gen_pki_ca() {
  mkdir -p pki
  openssl ecparam -name prime256v1 -genkey -noout -out pki/ca.key 2>/dev/null
  openssl req -x509 -new -key pki/ca.key -sha256 -days 365 \
    -subj "/CN=frp-ssh-tunnel CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out pki/ca.crt 2>/dev/null
  chmod 600 pki/ca.key; chmod 644 pki/ca.crt
}
issue_cert() { # $1=имя (server|client|visitor), $2=SAN или ""
  local name=$1
  local san="${2:-}"
  local eku ext
  case $name in server) eku=serverAuth ;; *) eku=clientAuth ;; esac
  openssl ecparam -name prime256v1 -genkey -noout -out "pki/$name.key" 2>/dev/null
  openssl req -new -key "pki/$name.key" -subj "/CN=frp-$name" -out "pki/$name.csr" 2>/dev/null
  {
    printf 'extendedKeyUsage=%s\n' "$eku"
    if [ -n "$san" ]; then printf 'subjectAltName=%s\n' "$san"; fi
  } > "pki/$name.ext"
  openssl x509 -req -in "pki/$name.csr" -CA pki/ca.crt -CAkey pki/ca.key \
    -CAcreateserial -days 365 -sha256 -extfile "pki/$name.ext" \
    -out "pki/$name.crt" 2>/dev/null
  rm -f "pki/$name.csr" "pki/$name.ext"
  chmod 600 "pki/$name.key"; chmod 644 "pki/$name.crt"
}
# SAN из адреса: домен -> DNS:..., IP -> IP:...
compute_san() {
  if [ "$SERVER_ADDR" = "$PLACEHOLDER" ]; then
    printf 'DNS:placeholder.invalid'
  elif printf '%s' "$SERVER_ADDR" | grep -qE '^[0-9.]+$'; then
    printf 'IP:%s' "$SERVER_ADDR"
  else
    printf 'DNS:%s' "$SERVER_ADDR"
  fi
}

# --- разбор аргументов ---
cmd=render; addr=""
case "${1:-}" in
  --rotate) cmd=rotate; addr="${2:-}" ;;
  --init)   cmd=init;   addr="${2:-}" ;;
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
  echo "PKI_ADDR=${PKI_ADDR:-<не выпущен>}"
  exit 0
fi

# --- адрес VPS: аргумент > сохранённый > плейсхолдер ---
: "${SERVER_ADDR:=$PLACEHOLDER}"
if [ -n "$addr" ]; then SERVER_ADDR="$addr"; fi

# --- генерация: rotate — все заново; иначе — только отсутствующие ---
printed=0
pki_existed=0; [ -f pki/ca.key ] && pki_existed=1
secrets_existed=0; [ -f "$SECRETS" ] && secrets_existed=1

if [ "$cmd" = rotate ]; then
  need_openssl
  if [ "$pki_existed" = 0 ]; then
    echo "Ошибка: pki/ca.key не найден — ротация PKI выполняется на машине-первоисточнике (VPS),"
    echo "  где хранится CA. Скопируйте pki/ сюда или выполните ротацию там."
    exit 1
  fi
  AUTH_TOKEN=$(gen); SECRET_STCP=$(gen); SECRET_XTCP=$(gen)
  pki_action=rotate
  printed=1
  reason="Перевыпущены секреты и PKI"
elif [ "$cmd" = init ]; then
  need_openssl
  AUTH_TOKEN=$(gen); SECRET_STCP=$(gen); SECRET_XTCP=$(gen)
  pki_action=rotate   # полная регенерация PKI: CA + все серты
  printed=1
  reason="Инициализация: эта машина — первоисточник (новые секреты + PKI)"
else
  new=0
  if [ -z "${AUTH_TOKEN:-}" ];   then need_openssl; AUTH_TOKEN=$(gen);   new=1; fi
  if [ -z "${SECRET_STCP:-}" ];  then need_openssl; SECRET_STCP=$(gen);  new=1; fi
  if [ -z "${SECRET_XTCP:-}" ];  then need_openssl; SECRET_XTCP=$(gen);  new=1; fi
  printed=$new
  if [ "$new" = 1 ]; then reason="Сгенерированы новые секреты"; fi
  # Клон-деплой (клиент/visitor-роли): PKI не рождаем — готовые tls/ копируются с первоисточника
  if [ "$pki_existed" = 0 ]; then
    if [ "$secrets_existed" = 1 ]; then
      if { [ -f client/tls/ca.crt ] && [ -f client/tls/client.crt ] && [ -f client/tls/client.key ]; } \
         || { [ -f visitor/tls/ca.crt ] && [ -f visitor/tls/visitor.crt ] && [ -f visitor/tls/visitor.key ]; }; then
        pki_action=skip          # клиент/visitor-режим: рендерим конфиги, tls/ уже скопирован
      else
        echo "Ошибка: найден .secrets, но нет PKI-материалов — они рождаются на машине-первоисточнике (VPS)."
        echo "  Для клиентской роли:  scp -r root@<VPS>:/opt/frp-ssh-tunnel/client/tls ./client/"
        echo "  Для роли visitor:     scp -r root@<VPS>:/opt/frp-ssh-tunnel/visitor/tls ./visitor/"
        echo "  либо сделайте эту машину первоисточником: ./setup.sh --init \"$SERVER_ADDR\""
        exit 1
      fi
    else
      need_openssl; pki_action=generate   # самый первый запуск где-либо
    fi
  elif [ "${PKI_ADDR:-}" != "$SERVER_ADDR" ]; then
    need_openssl; pki_action=server   # адрес сменился — переиздаём только серверный серт
  fi
fi

# --- сохранение хранилища ---
umask 077
# В клиентском режиме (skip) PKI_ADDR сохраняется из .secrets — адрес выдачи не менялся
if [ "${pki_action:-skip}" != skip ]; then PKI_ADDR="${SERVER_ADDR}"; fi
cat > "$SECRETS" <<EOF
AUTH_TOKEN=$AUTH_TOKEN
SECRET_STCP=$SECRET_STCP
SECRET_XTCP=$SECRET_XTCP
SERVER_ADDR="${SERVER_ADDR}"
PKI_ADDR="${PKI_ADDR:-}"
EOF
chmod 600 "$SECRETS"

# --- PKI: генерация / переиздание / рендер tls-каталогов ---
case "${pki_action:-}" in
  generate)
    gen_pki_ca
    issue_cert server   "$(compute_san)"
    issue_cert client
    issue_cert visitor
    ;;
  server)
    issue_cert server   "$(compute_san)"
    ;;
  rotate)
    gen_pki_ca
    issue_cert server   "$(compute_san)"
    issue_cert client
    issue_cert visitor
    ;;
esac
# Рендер tls-каталогов: каждый прогон обновляет их из pki/ (идемпотентно, самовосстановление)
if [ -f pki/ca.key ]; then
  mkdir -p vps/tls client/tls visitor/tls
  cp pki/ca.crt vps/tls/ca.crt
  cp pki/server.crt pki/server.key vps/tls/
  cp pki/ca.crt client/tls/ca.crt
  cp pki/client.crt pki/client.key client/tls/
  cp pki/ca.crt pki/visitor.crt pki/visitor.key visitor/tls/
  chmod 600 vps/tls/server.key client/tls/client.key visitor/tls/visitor.key
  chmod 644 vps/tls/ca.crt vps/tls/server.crt client/tls/ca.crt client/tls/client.crt \
            visitor/tls/ca.crt visitor/tls/visitor.crt
fi

# --- рендеринг конфигов ---
# Контейнер запускается под deploy-пользователем (user: в compose) —
# он читает свои конфиги без chown и без sudo.
frp_uid=$(id -u)
frp_gid=$(id -g)

cat > vps/.env <<EOF
FRP_AUTH_TOKEN=${AUTH_TOKEN}
FRP_UID=${frp_uid}
FRP_GID=${frp_gid}
EOF
chmod 600 vps/.env

# Статический конфиг frps (секретов не содержит, токен подставляет сам frp из env)
cat > vps/frps.toml <<'EOF'
bindPort = 7000
auth.method = "token"
auth.token = "{{ .Envs.FRP_AUTH_TOKEN }}"

transport.tls.force = true
transport.tls.certFile = "/etc/frp/tls/server.crt"
transport.tls.keyFile = "/etc/frp/tls/server.key"
transport.tls.trustedCaFile = "/etc/frp/tls/ca.crt"
EOF
chmod 600 vps/frps.toml

cat > client/frpc.toml <<EOF
serverAddr = "${SERVER_ADDR}"
serverPort = 7000
auth.method = "token"
auth.token = "${AUTH_TOKEN}"

transport.tls.certFile = "/etc/frp/tls/client.crt"
transport.tls.keyFile = "/etc/frp/tls/client.key"
transport.tls.trustedCaFile = "/etc/frp/tls/ca.crt"

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

cat > client/.env <<EOF
FRP_UID=${frp_uid}
FRP_GID=${frp_gid}
EOF
chmod 600 client/.env

# Рендер конфига visitor (машина, С КОТОРОЙ подключаются)
mkdir -p visitor
cat > visitor/visitor.toml <<EOF
serverAddr = "${SERVER_ADDR}"
serverPort = 7000
auth.method = "token"
auth.token = "${AUTH_TOKEN}"

transport.tls.certFile = "/etc/frp/tls/visitor.crt"
transport.tls.keyFile = "/etc/frp/tls/visitor.key"
transport.tls.trustedCaFile = "/etc/frp/tls/ca.crt"

[[visitors]]
name = "private_ssh_stcp"
type = "stcp"
serverName = "private_ssh_stcp"
secretKey = "${SECRET_STCP}"
bindPort = -1

[[visitors]]
name = "private_ssh_xtcp"
type = "xtcp"
serverName = "private_ssh_xtcp"
secretKey = "${SECRET_XTCP}"
bindAddr = "127.0.0.1"
bindPort = 6000
keepTunnelOpen = true
fallbackTo = "private_ssh_stcp"
fallbackTimeoutMs = 1000
EOF
chmod 600 visitor/visitor.toml

cat > visitor/.env <<EOF
FRP_UID=${frp_uid}
FRP_GID=${frp_gid}
EOF
chmod 600 visitor/.env

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
echo "Отрендерено: vps/.env, vps/frps.toml, client/frpc.toml, client/.env, visitor/visitor.toml, visitor/.env"
