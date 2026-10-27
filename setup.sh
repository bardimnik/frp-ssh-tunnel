#!/usr/bin/env bash
# setup.sh — генерация секретов/PKI и рендеринг конфигов frp.
#
# Использование:
#   MACHINE=<имя> ./setup.sh [адрес_VPS]      # первая настройка / идемпотентный рендер
#   MACHINE=<имя> ./setup.sh --init [адрес]   # сделать машину первоисточником (полная регенерация)
#   ./setup.sh --rotate [адрес]               # ротация ВСЕХ секретов и сертов (на первоисточнике)
#   ./setup.sh show                           # показать текущие значения
#
# Машины: каждая клиентская машина имеет имя (MACHINE, по умолчанию "private" —
# обратная совместимость одиночной установки). Имена прокси: <machine>_ssh_*.
# Реестр машин: MACHINES в .secrets (пополняется автоматически при запуске).
# Секреты: SECRET_<ИМЯ>_STCP/XTCP на машину (для private — legacy SECRET_STCP/XTCP).
# PKI: pki/ рождается на первоисточнике; клиентские серты client-<machine>.*
# рендерятся в client/tls/ под именами client.crt/key.
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
issue_cert() { # $1=имя (server|client|client-<m>|visitor), $2=SAN или ""
  local name=$1
  local san="${2:-}"
  local eku
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

# --- машины: имя, переменные секретов, реестр ---
MACHINE=$(printf '%s' "${MACHINE:-private}" | tr '[:upper:]' '[:lower:]')
if [[ "$MACHINE" =~ [^a-z0-9-] ]]; then
  echo "Ошибка: некорректное имя машины: \"$MACHINE\" (строчные буквы, цифры, дефис)"
  exit 1
fi
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr '-' '_'; }
stcp_var() { if [ "$1" = private ]; then echo SECRET_STCP; else echo "SECRET_$(upper "$1")_STCP"; fi; }
xtcp_var() { if [ "$1" = private ]; then echo SECRET_XTCP; else echo "SECRET_$(upper "$1")_XTCP"; fi; }
get_var() { local v=$1; printf '%s' "${!v:-}"; }
register_machine() {
  case " ${MACHINES:-} " in *" $1 "*) ;; *) MACHINES="${MACHINES:+$MACHINES }$1" ;; esac
}
machine_port() { local i=0 m; for m in $MACHINES; do [ "$m" = "$1" ] && { echo $((6000+i)); return; }; i=$((i+1)); done; }
client_cert_name() { if [ "$1" = private ]; then echo client; else echo "client-$1"; fi; }

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

# --- реестр машин: записи валидируются при загрузке ---
for m in ${MACHINES:-}; do
  if [[ "$m" =~ [^a-z0-9-] ]]; then
    echo "Ошибка: некорректная запись '$m' в MACHINES (.secrets) — исправьте или удалите её."
    exit 1
  fi
done

# Легаси-апгрейд: .secrets без реестра = одиночная установка "private"
if [ -z "${MACHINES:-}" ] && [ -n "${AUTH_TOKEN:-}" ]; then MACHINES=private; fi

if [ "$cmd" = show ]; then
  echo "AUTH_TOKEN=${AUTH_TOKEN:-<не сгенерирован>}"
  echo "MACHINES=${MACHINES:-<нет>}"
  for m in ${MACHINES:-}; do
    echo "[$m] $(stcp_var "$m")=$(get_var "$(stcp_var "$m")")"
    echo "[$m] $(xtcp_var "$m")=$(get_var "$(xtcp_var "$m")")"
  done
  echo "SERVER_ADDR=${SERVER_ADDR:-<не задан>}"
  echo "PKI_ADDR=${PKI_ADDR:-<не выпущен>}"
  exit 0
fi

# --- адрес VPS: аргумент > сохранённый > плейсхолдер ---
: "${SERVER_ADDR:=$PLACEHOLDER}"
if [ -n "$addr" ]; then SERVER_ADDR="$addr"; fi

# --- валидация адреса: допустимы ТОЛЬКО буквы/цифры/точки/дефисы по всей строке
# (негативный класс ловит и переводы строк; плейсхолдер пропускается) ---
if [ "$SERVER_ADDR" != "$PLACEHOLDER" ] && [[ "$SERVER_ADDR" =~ [^A-Za-z0-9.-] ]]; then
  echo "Ошибка: некорректный адрес VPS: \"$SERVER_ADDR\""
  echo "  Ожидаются только буквы, цифры, точки и дефисы (домен или IP)."
  exit 1
fi

# --- машина регистрируется в реестре автоматически ---
register_machine "$MACHINE"

# --- генерация секретов: rotate/init — все заново; иначе — только отсутствующие ---
printed=0
pki_existed=0; [ -f pki/ca.key ] && pki_existed=1
secrets_existed=0; [ -f "$SECRETS" ] && secrets_existed=1

rotate_all_secrets() {
  AUTH_TOKEN=$(gen)
  local m
  for m in $MACHINES; do
    set_var "$(stcp_var "$m")" "$(gen)"
    set_var "$(xtcp_var "$m")" "$(gen)"
  done
}
set_var() { printf -v "$1" '%s' "$2"; }

if [ "$cmd" = rotate ]; then
  need_openssl
  if [ "$pki_existed" = 0 ]; then
    echo "Ошибка: pki/ca.key не найден — ротация PKI выполняется на машине-первоисточнике (VPS),"
    echo "  где хранится CA. Скопируйте pki/ сюда или выполните ротацию там."
    exit 1
  fi
  rotate_all_secrets
  pki_action=rotate
  printed=1
  reason="Перевыпущены секреты и PKI"
elif [ "$cmd" = init ]; then
  need_openssl
  rotate_all_secrets
  pki_action=rotate   # полная регенерация PKI: CA + все серты
  printed=1
  reason="Инициализация: эта машина — первоисточник (новые секреты + PKI)"
else
  new=0
  if [ -z "${AUTH_TOKEN:-}" ]; then need_openssl; AUTH_TOKEN=$(gen); new=1; fi
  for m in $MACHINES; do
    v1=$(stcp_var "$m"); v2=$(xtcp_var "$m")
    if [ -z "$(get_var "$v1")" ] || [ -z "$(get_var "$v2")" ]; then
      if [ "$m" = "$MACHINE" ]; then
        # своей машине секреты разрешено рождать здесь
        need_openssl; set_var "$v1" "$(gen)"; set_var "$v2" "$(gen)"; new=1
      else
        # чужой машине — НЕЛЬЗЯ: получились бы неверные секреты и тихо сломанная связность
        echo "Ошибка: в .secrets нет секретов машины '$m' — копия устарела."
        echo "  Скопируйте актуальный .secrets с первоисточника (VPS) и повторите."
        exit 1
      fi
    fi
  done
  printed=$new
  if [ "$new" = 1 ]; then reason="Сгенерированы новые секреты"; fi
  if [ "${MACHINE:-private}" = private ] && [ "$(set -- $MACHINES; echo $#)" -gt 1 ]; then
    echo "ВНИМАНИЕ: в реестре несколько машин ($MACHINES), а MACHINE не задан —"
    echo "  рендер client/ выполняется для машины 'private'."
    echo "  Для visitor-машины это норма (visitor.toml рендерится по всем машинам реестра)."
    echo "  Для другой клиентской машины: MACHINE=<имя> ./setup.sh ..."
  fi
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

# --- выпуск клиентского серта этой машины, если его ещё нет (только на первоисточнике) ---
if [ -f pki/ca.key ] && [ ! -f "pki/$(client_cert_name "$MACHINE").crt" ]; then
  need_openssl
  issue_cert "$(client_cert_name "$MACHINE")"
fi

# --- сохранение хранилища ---
umask 077
# В клиентском режиме (skip) PKI_ADDR сохраняется из .secrets — адрес выдачи не менялся
if [ "${pki_action:-skip}" != skip ]; then PKI_ADDR="${SERVER_ADDR}"; fi
{
  echo "AUTH_TOKEN=$AUTH_TOKEN"
  echo "MACHINES=\"$MACHINES\""
  for m in $MACHINES; do
    echo "$(stcp_var "$m")=$(get_var "$(stcp_var "$m")")"
    echo "$(xtcp_var "$m")=$(get_var "$(xtcp_var "$m")")"
  done
  echo "SERVER_ADDR=\"${SERVER_ADDR}\""
  echo "PKI_ADDR=\"${PKI_ADDR:-}\""
} > "$SECRETS"
chmod 600 "$SECRETS"

# --- PKI: генерация / переиздание ---
case "${pki_action:-}" in
  generate)
    if [ -d client/tls ] || [ -d visitor/tls ]; then
      echo "ВНИМАНИЕ: найдены существующие каталоги tls/ — они перезаписаны новыми сертами."
      echo "  Проверьте согласованность с остальными машинами: ./setup.sh show"
    fi
    gen_pki_ca
    issue_cert server   "$(compute_san)"
    for m in $MACHINES; do issue_cert "$(client_cert_name "$m")"; done
    issue_cert visitor
    ;;
  server)
    issue_cert server   "$(compute_san)"
    ;;
  rotate)
    gen_pki_ca
    issue_cert server   "$(compute_san)"
    for m in $MACHINES; do issue_cert "$(client_cert_name "$m")"; done
    issue_cert visitor
    ;;
esac
# Рендер tls-каталогов: каждый прогон обновляет их из pki/ (идемпотентно, самовосстановление)
if [ -f pki/ca.key ]; then
  mkdir -p vps/tls client/tls visitor/tls
  cp pki/ca.crt vps/tls/ca.crt
  cp pki/server.crt pki/server.key vps/tls/
  cur_cert=$(client_cert_name "$MACHINE")
  cp pki/ca.crt client/tls/ca.crt
  cp "pki/$cur_cert.crt" client/tls/client.crt
  cp "pki/$cur_cert.key" client/tls/client.key
  cp pki/ca.crt pki/visitor.crt pki/visitor.key visitor/tls/
  chmod 600 vps/tls/server.key client/tls/client.key visitor/tls/visitor.key
  chmod 644 vps/tls/ca.crt vps/tls/server.crt client/tls/ca.crt client/tls/client.crt \
            visitor/tls/ca.crt visitor/tls/visitor.crt
fi
if [ "${pki_action:-}" = generate ]; then
  echo "Эта машина теперь ПЕРВОИСТОЧНИК: .secrets + pki/ — перенесите их на остальные машины."
  echo "  Если первоисточник уже существует на другой машине — удалите здесь .secrets и pki/"
  echo "  и скопируйте артефакты с него (иначе клиенты не примут серты)."
fi

# --- рендеринг конфигов ---
# Контейнер запускается под deploy-пользователем (user: в compose) —
# он читает свои конфиги без chown и без sudo.
frp_uid=$(id -u)
frp_gid=$(id -g)
root_deploy=0
if [ "$frp_uid" = 0 ]; then
  # Деплой под root: контейнер оставляем non-root (uid 10000 из образа),
  # а отрендеренным файлам отдаем владение 10000 — иначе контейнер их не прочитает
  root_deploy=1
  frp_uid=10000
  frp_gid=10000
fi

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

MY_STCP=$(get_var "$(stcp_var "$MACHINE")")
MY_XTCP=$(get_var "$(xtcp_var "$MACHINE")")

cat > client/frpc.toml <<EOF
serverAddr = "${SERVER_ADDR}"
serverPort = 7000
auth.method = "token"
auth.token = "${AUTH_TOKEN}"

transport.tls.certFile = "/etc/frp/tls/client.crt"
transport.tls.keyFile = "/etc/frp/tls/client.key"
transport.tls.trustedCaFile = "/etc/frp/tls/ca.crt"

[[proxies]]
name = "${MACHINE}_ssh_stcp"
type = "stcp"
secretKey = "${MY_STCP}"
localIP = "127.0.0.1"
localPort = 22

[[proxies]]
name = "${MACHINE}_ssh_xtcp"
type = "xtcp"
secretKey = "${MY_XTCP}"
localIP = "127.0.0.1"
localPort = 22
EOF
chmod 600 client/frpc.toml

cat > client/.env <<EOF
FRP_UID=${frp_uid}
FRP_GID=${frp_gid}
EOF
chmod 600 client/.env

# Рендер конфига visitor: блок [[visitors]] на КАЖДУЮ машину из реестра
# (порт 6000+индекс по порядку регистрации в MACHINES)
mkdir -p visitor
{
  cat <<EOF
serverAddr = "${SERVER_ADDR}"
serverPort = 7000
auth.method = "token"
auth.token = "${AUTH_TOKEN}"

transport.tls.certFile = "/etc/frp/tls/visitor.crt"
transport.tls.keyFile = "/etc/frp/tls/visitor.key"
transport.tls.trustedCaFile = "/etc/frp/tls/ca.crt"
EOF
  for m in $MACHINES; do
    port=$(machine_port "$m")
    cat <<EOF

[[visitors]]
name = "${m}_ssh_stcp"
type = "stcp"
serverName = "${m}_ssh_stcp"
secretKey = "$(get_var "$(stcp_var "$m")")"
bindPort = -1

[[visitors]]
name = "${m}_ssh_xtcp"
type = "xtcp"
serverName = "${m}_ssh_xtcp"
secretKey = "$(get_var "$(xtcp_var "$m")")"
bindAddr = "127.0.0.1"
bindPort = ${port}
keepTunnelOpen = true
fallbackTo = "${m}_ssh_stcp"
fallbackTimeoutMs = 1000
EOF
  done
} > visitor/visitor.toml
chmod 600 visitor/visitor.toml

cat > visitor/.env <<EOF
FRP_UID=${frp_uid}
FRP_GID=${frp_gid}
EOF
chmod 600 visitor/.env

# Деплой под root: контейнер non-root (10000), файлы и каталоги tls — во владении 10000
if [ "$root_deploy" = 1 ]; then
  chown 10000:10000 vps/frps.toml vps/tls client/frpc.toml client/tls \
                    visitor/visitor.toml visitor/tls \
                    vps/tls/* client/tls/* visitor/tls/* 2>/dev/null || true
fi

# --- вывод ---
if [ "$printed" = 1 ]; then
  echo "$reason: (хранятся в $SECRETS)"
  echo "  AUTH_TOKEN=$AUTH_TOKEN"
  echo "  $(stcp_var "$MACHINE")=$MY_STCP"
  echo "  $(xtcp_var "$MACHINE")=$MY_XTCP"
  if [ "$cmd" = rotate ] || [ "$cmd" = init ]; then
    echo "  Ротированы секреты всех машин реестра: $MACHINES"
  fi
else
  echo "Секреты без изменений (показать: ./setup.sh show)"
fi
echo "MACHINE=$MACHINE · MACHINES=$MACHINES"
echo "SERVER_ADDR=$SERVER_ADDR"
if [ "$SERVER_ADDR" = "$PLACEHOLDER" ]; then
  echo "ВНИМАНИЕ: адрес VPS не задан. При деплое: ./setup.sh <IP или домен VPS>"
fi
echo "Отрендерено: vps/.env, vps/frps.toml, client/frpc.toml, client/.env, visitor/visitor.toml, visitor/.env"
