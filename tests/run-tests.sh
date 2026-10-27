#!/usr/bin/env bash
# Тесты setup.sh. Запуск из любой точки: bash tests/run-tests.sh
# Каждая проверка выполняется в изолированной песочнице (mktemp) —
# реальные конфиги проекта не затрагиваются.
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

# --- первый запуск без адреса: генерация, рендер, плейсхолдер адреса ---
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

# --- повторный запуск с адресом: секреты НЕ меняются, адрес и uid обновляются ---
t "T16 повторный запуск с адресом"       './setup.sh 1.2.3.4 >/dev/null 2>&1'
t "T17 адрес обновлён в конфиге"         'grep -q "serverAddr = \"1.2.3.4\"" client/frpc.toml'
N_TOKEN=$(val .secrets AUTH_TOKEN)
t "T18 секреты идемпотентны"             '[ -n "$N_TOKEN" ] && [ "$N_TOKEN" = "$TOKEN" ]'
t "T19 .secrets хранит адрес"            '[ "$(sed -n "s/^SERVER_ADDR=\"//p" .secrets | sed "s/\"$//")" = "1.2.3.4" ]'

# --- rotate: все три секрета меняются, согласованность сохраняется ---
./setup.sh --rotate 1.2.3.4 >/dev/null 2>&1
R_TOKEN=$(val .secrets AUTH_TOKEN); R1=$(sed -n 's/^secretKey = "//p' client/frpc.toml | head -1 | sed 's/"$//')
R_SSTCP=$(val .secrets SECRET_STCP)
t "T20 rotate: токен сменился"           '[ "$R_TOKEN" != "$TOKEN" ]'
t "T21 rotate: stcp сменился"            '[ "$R_SSTCP" != "$SSTCP" ]'
t "T22 rotate: рендер согласован"        '[ -n "$R1" ] && [ -n "$R_SSTCP" ] && [ "$R1" = "$R_SSTCP" ]'
t "T23 rotate: адрес сохранён"           'grep -q "serverAddr = \"1.2.3.4\"" client/frpc.toml'

# --- show: печатает, ничего не меняет ---
t "T24 show печатает секреты"            './setup.sh show | grep -q "^SECRET_STCP="'
t "T25 show не меняет файлы"             'H1=$(md5sum client/frpc.toml) && ./setup.sh show >/dev/null && [ "$H1" = "$(md5sum client/frpc.toml)" ]'

echo
echo "Итог: PASS=$pass FAIL=$fail (песочница: $SANDBOX)"
[ "$fail" = 0 ]
