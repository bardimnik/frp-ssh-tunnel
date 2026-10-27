#!/usr/bin/env bash
# Тесты setup.sh. Запуск из любой точки: bash tests/run-tests.sh
# Каждая проверка выполняется в изолированной песочнице (mktemp) —
# реальные конфиги проекта не затрагиваются. Последняя секция — проверки
# уровня репозитория (gitignore, шаблоны), они выполняются в REPO_ROOT
# и не зависят от состояния рабочего дерева.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
cp "$REPO_ROOT/setup.sh" "$SANDBOX/"
mkdir -p "$SANDBOX/vps" "$SANDBOX/client"
cd "$SANDBOX"

pass=0; fail=0
t() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }
val() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }
tomlval() { sed -n "s/^$2 = \"//p" "$1" 2>/dev/null | head -1 | sed 's/"$//'; }
# Семантика TOML: transport.tls.* обязаны быть на верхнем уровне,
# а не внутри таблиц proxies/visitors (иначе frp: "unknown field tls")
toml_top_ok() { # $1=файл, $2=имя таблицы (proxies|visitors)
  python3 - "$1" "$2" <<'PYEOF'
import sys, tomllib
d = tomllib.load(open(sys.argv[1], 'rb'))
assert 'transport' in d and 'tls' in d['transport'], f'transport.tls не на верхнем уровне: {list(d)}'
for p in d.get(sys.argv[2], []):
    assert 'transport' not in p, f'tls внутри {sys.argv[2]}: {p.get("name")}'
PYEOF
}

# --- первый запуск без адреса: генерация секретов, PKI и рендер ---
t "T1 первый запуск отрабатывает"        './setup.sh >/dev/null 2>&1'
t "T2 .secrets создан (600)"             '[ -f .secrets ] && [ "$(stat -c %a .secrets)" = 600 ]'
t "T3 плейсхолдер адреса сохранён"       'grep -q "serverAddr = \"<IP или домен VPS>\"" client/frpc.toml'
t "T4 vps/frps.toml отрендерен"          '[ -f vps/frps.toml ]'
t "T5 vps/frps.toml валиден (bindPort)"  'grep -q "^bindPort = 7000$" vps/frps.toml && ! grep -q "allowPorts" vps/frps.toml'
TOKEN=$(val .secrets AUTH_TOKEN); SSTCP=$(val .secrets SECRET_STCP); SXTCP=$(val .secrets SECRET_XTCP)
t "T6 токен 64 hex"                      '[ ${#TOKEN} = 64 ]'
t "T7 секреты 64 hex и разные"           '[ ${#SSTCP} = 64 ] && [ ${#SXTCP} = 64 ] && [ "$SSTCP" != "$SXTCP" ]'
t "T8 vps/.env: токен совпадает"         '[ -n "$TOKEN" ] && [ "$(val vps/.env FRP_AUTH_TOKEN)" = "$TOKEN" ]'
t "T9 client: токен совпадает"           '[ -n "$TOKEN" ] && [ "$(tomlval client/frpc.toml auth.token)" = "$TOKEN" ]'
SK1=$(sed -n 's/^secretKey = "//p' client/frpc.toml | head -1 | sed 's/"$//'); SK2=$(sed -n 's/^secretKey = "//p' client/frpc.toml | sed -n 2p | sed 's/"$//')
t "T10 stcp-секрет согласован"           '[ -n "$SK1" ] && [ "$SK1" = "$SSTCP" ]'
t "T11 xtcp-секрет согласован"           '[ -n "$SK2" ] && [ "$SK2" = "$SXTCP" ]'
t "T12 права конфигов 600"               '[ "$(stat -c %a client/frpc.toml)" = 600 ] && [ "$(stat -c %a vps/.env)" = 600 ] && [ "$(stat -c %a vps/frps.toml)" = 600 ]'
t "T13 client/.env создан с uid/gid"     '[ -f client/.env ] && [ "$(stat -c %a client/.env)" = 600 ] && FRP_UID=$(val client/.env FRP_UID) && [ "$FRP_UID" = "$(id -u)" ] && FRP_GID=$(val client/.env FRP_GID) && [ "$FRP_GID" = "$(id -g)" ]'
t "T14 vps/.env содержит uid/gid"        '[ "$(val vps/.env FRP_UID)" = "$(id -u)" ] && [ "$(val vps/.env FRP_GID)" = "$(id -g)" ]'
t "T15 скрипт не создаёт каталог pc"     '[ ! -d pc ]'

# --- PKI: генерация, права, цепочки, SAN, TLS-строки в конфигах ---
t "T16 pki: все 8 файлов созданы"        '[ -f pki/ca.crt ] && [ -f pki/ca.key ] && [ -f pki/server.crt ] && [ -f pki/server.key ] && [ -f pki/client.crt ] && [ -f pki/client.key ] && [ -f pki/visitor.crt ] && [ -f pki/visitor.key ]'
t "T17 pki: права ключей 600"            '[ "$(stat -c %a pki/ca.key)" = 600 ] && [ "$(stat -c %a pki/server.key)" = 600 ] && [ "$(stat -c %a pki/client.key)" = 600 ] && [ "$(stat -c %a pki/visitor.key)" = 600 ]'
t "T18 vps/tls отрендерен"               '[ -f vps/tls/ca.crt ] && [ -f vps/tls/server.crt ] && [ -f vps/tls/server.key ]'
t "T19 client/tls отрендерен"            '[ -f client/tls/ca.crt ] && [ -f client/tls/client.crt ] && [ -f client/tls/client.key ]'
t "T20 цепочка server.crt валидна"       'openssl verify -CAfile pki/ca.crt pki/server.crt >/dev/null 2>&1'
t "T21 цепочка client.crt валидна"       'openssl verify -CAfile pki/ca.crt pki/client.crt >/dev/null 2>&1 && openssl verify -CAfile pki/ca.crt pki/visitor.crt >/dev/null 2>&1'
t "T22 server.crt: EKU serverAuth"       'openssl x509 -in pki/server.crt -noout -ext extendedKeyUsage 2>/dev/null | grep -q "TLS Web Server Authentication"'
t "T23 client.crt: EKU clientAuth"       'openssl x509 -in pki/client.crt -noout -ext extendedKeyUsage 2>/dev/null | grep -q "TLS Web Client Authentication"'
t "T24 frps.toml: tls.force и серты"     'grep -q "transport.tls.force = true" vps/frps.toml && grep -q "certFile = \"/etc/frp/tls/server.crt\"" vps/frps.toml && grep -q "trustedCaFile" vps/frps.toml'
t "T25 client/frpc.toml: tls-строки"     'grep -q "transport.tls.certFile" client/frpc.toml && grep -q "transport.tls.trustedCaFile" client/frpc.toml'
t "T25a семантика: tls на верхнем уровне" 'toml_top_ok client/frpc.toml proxies'

# --- повторный запуск с адресом: секреты, CA и server.crt не меняются; SAN обновляется ---
t "T26 повторный запуск с адресом"       './setup.sh 1.2.3.4 >/dev/null 2>&1'
t "T27 адрес обновлён в конфиге"         'grep -q "serverAddr = \"1.2.3.4\"" client/frpc.toml'
N_TOKEN=$(val .secrets AUTH_TOKEN); N_CA=$(md5sum pki/ca.crt | cut -d" " -f1); N_SRV=$(md5sum pki/server.crt | cut -d" " -f1)
t "T28 секреты идемпотентны"             '[ -n "$N_TOKEN" ] && [ "$N_TOKEN" = "$TOKEN" ]'
t "T29 CA идемпотентен"                  '[ -n "$N_CA" ] && [ "$N_CA" = "$(md5sum pki/ca.crt | cut -d" " -f1)" ]'
t "T30 SAN = IP Address 1.2.3.4"         'openssl x509 -in pki/server.crt -noout -ext subjectAltName 2>/dev/null | grep -q "IP Address:1.2.3.4"'
t "T31 .secrets хранит адрес"            '[ "$(sed -n "s/^SERVER_ADDR=\"//p" .secrets | sed "s/\"$//")" = "1.2.3.4" ]'
./setup.sh 1.2.3.4 >/dev/null 2>&1
t "T55 server.crt идемпотентен"          '[ "$(md5sum pki/server.crt | cut -d" " -f1)" = "$N_SRV" ]'

# --- смена адреса: переиздаётся только server.crt ---
OLD_CA=$(md5sum pki/ca.crt | cut -d" " -f1); OLD_CLI=$(md5sum pki/client.crt | cut -d" " -f1)
./setup.sh frps.example.com >/dev/null 2>&1
t "T32 смена адреса: CA не тронут"       '[ "$(md5sum pki/ca.crt | cut -d" " -f1)" = "$OLD_CA" ]'
t "T33 смена адреса: client.crt не тронут" '[ "$(md5sum pki/client.crt | cut -d" " -f1)" = "$OLD_CLI" ]'
t "T34 смена адреса: SAN домен"          'openssl x509 -in pki/server.crt -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:frps.example.com"'

# --- rotate: всё перевыпускается, согласованность сохраняется ---
./setup.sh --rotate 1.2.3.4 >/dev/null 2>&1
R_TOKEN=$(val .secrets AUTH_TOKEN); R1=$(sed -n 's/^secretKey = "//p' client/frpc.toml | head -1 | sed 's/"$//')
R_SSTCP=$(val .secrets SECRET_STCP)
t "T35 rotate: токен сменился"           '[ "$R_TOKEN" != "$TOKEN" ]'
t "T36 rotate: stcp сменился"            '[ "$R_SSTCP" != "$SSTCP" ]'
t "T37 rotate: рендер согласован"        '[ -n "$R1" ] && [ -n "$R_SSTCP" ] && [ "$R1" = "$R_SSTCP" ]'
t "T38 rotate: CA сменился"              '[ "$(md5sum pki/ca.crt | cut -d" " -f1)" != "$OLD_CA" ]'
t "T39 rotate: SAN снова IP"             'openssl x509 -in pki/server.crt -noout -ext subjectAltName 2>/dev/null | grep -q "IP Address:1.2.3.4"'

# --- rotate без ca.key невозможен (не первоисточник) ---
mv pki/ca.key pki/ca.key.off
OUT=$(./setup.sh --rotate 1.2.3.4 2>&1); RC=$?
t "T54 rotate без ca.key — отказ"        '[ "$RC" != 0 ] && echo "$OUT" | grep -q "первоисточник"'
mv pki/ca.key.off pki/ca.key

# --- валидация адреса: мусор не проходит ---
OUT=$(./setup.sh "bad;addr" 2>&1); RC=$?
t "T53 валидация адреса: мусор отклонён" '[ "$RC" != 0 ]'

# --- visitor-артефакты (песочница) ---
t "T50 visitor/visitor.toml отрендерен"  'toml_top_ok visitor/visitor.toml visitors'
t "T51 visitor/tls отрендерен"           '[ -f visitor/tls/ca.crt ] && [ -f visitor/tls/visitor.crt ] && [ "$(stat -c %a visitor/tls/visitor.key)" = 600 ]'
t "T52 visitor/.env с uid/gid"           '[ -f visitor/.env ] && [ "$(val visitor/.env FRP_UID)" = "$(id -u)" ]'

# --- несколько клиентских машин: MACHINE=<имя> ---
MACHINE=alpha ./setup.sh 1.2.3.4 >/dev/null 2>&1
t "T56 alpha: имена прокси с префиксом"  'grep -q "alpha_ssh_stcp" client/frpc.toml && grep -q "alpha_ssh_xtcp" client/frpc.toml'
t "T57 alpha: секреты в .secrets"        'V=$(val .secrets SECRET_ALPHA_STCP); W=$(val .secrets SECRET_ALPHA_XTCP); [ ${#V} = 64 ] && [ ${#W} = 64 ]'
t "T58 реестр MACHINES пополнился"       'val .secrets MACHINES | grep -qw alpha && val .secrets MACHINES | grep -qw private'
t "T59 pki: серт client-alpha выпущен"   '[ -f pki/client-alpha.crt ] && [ -f pki/client-alpha.key ] && openssl verify -CAfile pki/ca.crt pki/client-alpha.crt >/dev/null 2>&1'
t "T60 client/tls нормализован (alpha)"  '[ "$(md5sum pki/client-alpha.crt | cut -d" " -f1)" = "$(md5sum client/tls/client.crt | cut -d" " -f1)" ]'
t "T61 visitor: блоки обеих машин"       'grep -q "serverName = \"alpha_ssh_xtcp\"" visitor/visitor.toml && grep -q "bindPort = 6001" visitor/visitor.toml && grep -q "serverName = \"private_ssh_xtcp\"" visitor/visitor.toml && grep -q "bindPort = 6000" visitor/visitor.toml'
t "T62 visitor: fallback на alpha_stcp"  'grep -q "fallbackTo = \"alpha_ssh_stcp\"" visitor/visitor.toml'
A_STCP=$(val .secrets SECRET_ALPHA_STCP)
./setup.sh --rotate 1.2.3.4 >/dev/null 2>&1
t "T63 rotate: секреты alpha сменились"  '[ "$(val .secrets SECRET_ALPHA_STCP)" != "$A_STCP" ]'
t "T64 дефолт private сохранён"          'grep -q "private_ssh_stcp" client/frpc.toml && grep -q "private_ssh_xtcp" client/frpc.toml'

# --- клон-режим (клиентская роль): pki нет, но готовый tls/ скопирован ---
rm -rf pki
OUT=$(./setup.sh 1.2.3.4 2>&1); RC=$?
t "T40 клон-режим: tls/ на месте — рендер успешен" '[ "$RC" = 0 ] && [ -f client/frpc.toml ] && grep -q "tls.certFile" client/frpc.toml'
rm -rf client/tls vps/tls visitor/tls
OUT=$(./setup.sh 1.2.3.4 2>&1); RC=$?
t "T41 клон-режим: нет tls/ — ошибка с подсказкой" '[ "$RC" != 0 ] && echo "$OUT" | grep -q "tls"'

# --- show ---
t "T42 show печатает секреты"            './setup.sh show | grep -q "SECRET_STCP="'
t "T43 show не меняет файлы"             'H1=$(md5sum client/frpc.toml) && ./setup.sh show >/dev/null && [ "$H1" = "$(md5sum client/frpc.toml)" ]'

# --- уровень репозитория: gitignore + шаблоны (не зависят от рабочего дерева) ---
cd "$REPO_ROOT"
t "T44 gitignore: pki"                   'git check-ignore -q pki/ca.key'
t "T45 gitignore: tls-каталоги"          'git check-ignore -q vps/tls/server.key && git check-ignore -q client/tls/client.key'
t "T46 gitignore: secrets и env"         'git check-ignore -q .secrets && git check-ignore -q vps/.env && git check-ignore -q client/.env'
t "T49 семантика: visitor.example.toml"  'toml_top_ok examples/visitor.example.toml visitors'

echo
echo "Итог: PASS=$pass FAIL=$fail (песочница: $SANDBOX)"
[ "$fail" = 0 ]
