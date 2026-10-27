# frp-ssh-tunnel — приватный SSH-доступ к машине за NAT через VPS

**Русский** | [English](README.en.md)

## Что это

Машина «клиент» (за NAT/фаерволом) сама подключается к VPS с публичным IP;
владелец подключается к клиенту через VPS. Используется
[frp](https://github.com/fatedier/frp): `frps` (сервер) на VPS, `frpc`
на целевой машине (ваш компьютер), visitor — там, откуда подключаетесь
(конфиг visitor'а — в разделе ниже, вне этой папки).

**Доступ приватный**: SSH-порт клиента наружу не торчит нигде. Канал доступа
защищён `secretKey`, соединение с VPS — токеном. Наружу на VPS открыт
**только служебный порт 7000**.

**Образы свои, не чужие**: frp собирается из исходников (тарбол тега v0.71.1,
sha256 зашит в Dockerfile) в multi-stage Dockerfile. Финальный образ —
`scratch` (без shell и busybox), non-root, без встраивания веб-дашборда
(`-tags noweb` — нет npm-цепочки поставок в сборке). Зависимости с известными
CVE поднимаются при сборке (`go get`).

## Архитектура

```
                                        ┌─ ВЫЗОВ: ssh -p 6000 user@127.0.0.1
                                        ▼
        ┌────────── основной: XTCP (P2P) ──────────┐
Машина ─┤                                          ▼
подключе-     напрямую: visitor ◄──────► КЛИЕНТ:22    VPS трафик не видит
ния (visitor, (VPS только помогает пробить NAT)
вне папки)
        └─ фолбэк: STCP ──► релей через VPS:7000 ──► КЛИЕНТ:22

Наружу на VPS: только 7000/tcp (служебный канал frpc↔frps)
```

- **Основной канал XTCP (P2P)**: hole punching через STUN; при успехе трафик
  идёт напрямую между машиной подключения и клиентом — VPS не видит его вовсе.
- **Фолбэк STCP**: если пробивание не удалось (например, симметричные NAT),
  соединение автоматически уходит через релей VPS — канал не рвётся.

## Состав папки

Два **независимых** compose-проекта — для двух машин. Вся папка переносится
целиком, на каждой машине работает только своя подпапка:

```
.
├── README.md            # этот файл
├── README.en.md         # английская версия
├── setup.sh             # генерация секретов + рендер конфигов: ./setup.sh <IP_VPS>
├── .secrets             # хранилище секретов (создаётся скриптом, chmod 600)
├── client/              # ← на ваш компьютер (к которому подключаются)
│   ├── build/           #   Dockerfile
│   ├── docker-compose.yml  #    образ frp-local:frpc
│   ├── frpc.toml.example   #    шаблон (рендеренный файл игнорируется git)
│   └── frpc.toml        #   рендерится setup.sh (stcp- и xtcp-прокси)
├── examples/            # visitor.example.toml — шаблон конфига visitor'а
└── vps/                 # ← на VPS
    ├── build/
    ├── docker-compose.yml  # образ frp-local:frps
    ├── frps.toml.example
    ├── frps.toml        # рендерится setup.sh
    └── .env.example     # → .env (рендерится setup.sh)
```

Перенос любым способом (флешка, SCP, zip) — **rsync не требуется**. Целостность
тарбола после переноса проверит сама сборка: sha256-канарейка уронит билд при
повреждении/подмене файла.

Рендеренные конфиги с секретами (`.secrets`, `vps/.env`, `client/frpc.toml`,
`vps/frps.toml`) и скачанные тарболы **игнорируются git** (`.gitignore`) — в
репозитории хранятся только `.example`-шаблоны. Справедливо и для скопированной
папки, и для клона репозитория: сначала `./setup.sh`, затем compose в своей
подпапке.

## Быстрый старт

### 1. VPS

```bash
cd <папка>
./setup.sh <IP или домен VPS>      # секреты (один раз) + рендер конфигов
cd vps
docker compose up -d --build
# фаервол: открыть входящие ТОЛЬКО 7000/tcp
chown 10000:10000 frps.toml        # конфиг должен быть читаем non-root контейнером
docker compose restart
docker logs frps                   # «frps started successfully»
```

### 2. Клиент (ваш компьютер — машина, к которой подключаются)

```bash
cd <папка>
./setup.sh <IP или домен VPS>      # тот же секрет (переиспользуется из .secrets)
cd client
docker compose up -d --build
chown 10000:10000 frpc.toml        # конфиг должен быть читаем non-root контейнером
docker compose restart
docker logs frpc                   # два прокси: «start proxy success»
```

### 3. Подключение (visitor — с любой машины, вне этой папки)

Visitor — это frpc с конфигом `[[visitors]]` (сниппет ниже). Он подключается
к VPS и открывает на «своей» машине локальный порт 6000, в который заведён
туннель к клиенту. Visitor должен быть запущен в момент подключения.
Подключение:

```bash
ssh -p 6000 user@127.0.0.1         # user — учётка НА КЛИЕНТЕ
```

Опционально в `~/.ssh/config`:

```
Host client
  HostName 127.0.0.1
  Port 6000
  User <ваш пользователь на клиенте>
```

→ подключение: `ssh client`. Аутентификация end-to-end: проверяет sshd
клиента по своим ключам; VPS видит только шифрованный релей.

## Сборка образов

`build/Dockerfile` (в `client/build/` и `vps/build/` — идентичны). Тарбол
исходников frp в репозитории не хранится — Dockerfile скачивает его при
сборке; sha256 `079f5fde…6722` зафиксирован в `ADD --checksum`:

```dockerfile
# фрагмент — полный файл в build/Dockerfile
FROM golang:1.26-alpine AS builder
ADD --checksum=sha256:079f… https://github.com/fatedier/frp/archive/refs/tags/v0.71.1.tar.gz …
RUN … go get golang.org/x/net@v0.60.0 && go get golang.org/x/crypto@v0.58.0 \
 && go mod tidy && go build -tags noweb -trimpath -ldflags="-s -w" -o /out/frpc ./cmd/frpc …

FROM alpine:3.24 AS runtime-files   # только CA + tzdata + passwd/group
FROM scratch AS frpc-image          # и frps-image — без shell и busybox
USER 10000:10000
CMD ["-c", "/etc/frp/frpc.toml"]
```

Почему scratch: busybox CVE-2025-60876 не исправлен ни в alpine 3.23/3.24
(«possibly vulnerable»), ни подтверждённо в edge (там busybox 1.38.0 — за
пределами уязвимого диапазона `<= 1.37.0`, но трекер не подтвердил). Вместо
rolling-edge устраняем сам пакет: бинарник статический (`CGO_ENABLED=0`),
shell в рантайме не используется. Следствие: `docker exec -it … sh` в
контейнере невозможен — и это плюс.

**Проверено локально (2026-10-27):** `frpc -v`/`frps -v` → `0.71.1`;
e2e-схема stcp+xtcp на собранных образах — GREEN в обеих ветках:
основной XTCP (`nat hole connection successful`, P2P) и фолбэк STCP
(при сломанном STUN: `open tunnel timeout` → ответ через релей);
grype: **High = 0**, busybox исключён. Остаточная находка (фикса нет
в апстриме, принята): `golang.org/x/crypto` GO-2026-5932 (Unknown).
Закроется при следующей пересборке, когда frp обновит зависимости.

## Конфигурация

Файлы ниже **рендерятся `setup.sh`** из `.secrets` — править их вручную можно,
но при следующем запуске скрипта они будут перезаписаны. Источник истины —
`setup.sh` + `.secrets`.

### Секреты (`setup.sh`)

```bash
./setup.sh <IP_VPS>    # генерация при отсутствии + рендер (идемпотентно)
./setup.sh --rotate <IP_VPS>   # перевыпуск всех секретов (затем перенос папки + рестарты)
./setup.sh show        # показать текущие значения
```

`.secrets` (chmod 600) хранит `AUTH_TOKEN`, `SECRET_STCP`, `SECRET_XTCP`,
`SERVER_ADDR`. Значения печатаются в терминал только при генерации/ротации —
**не в логи docker** (логи постоянны и читаемы всеми с доступом к docker).
После `--rotate` нужно обновить папку на всех машинах и перезапустить контейнеры.

### vps/docker-compose.yml

```yaml
services:
  frps:
    image: frp-local:frps
    build:
      context: ./build
      target: frps-image
    container_name: frps
    restart: unless-stopped
    ports:
      - "7000:7000"               # служебный канал frpc<->frps
    environment:
      - FRP_AUTH_TOKEN=${FRP_AUTH_TOKEN}
    volumes:
      - ./frps.toml:/etc/frp/frps.toml:ro
```

### vps/frps.toml

```toml
bindPort = 7000
auth.method = "token"
auth.token = "{{ .Envs.FRP_AUTH_TOKEN }}"
```

webServer у frps не используется — у сервера нет HTTP-интерфейса вообще.
Управление: файлы конфигурации + `docker compose`; статус — `docker logs frps`.

### vps/.env (chmod 600, рендерится setup.sh)

```
FRP_AUTH_TOKEN=<openssl rand -hex 32>
```

### client/frpc.toml (chmod 600, рендерится setup.sh)

```toml
serverAddr = "<IP или домен VPS>"     # ← плейсхолдер
serverPort = 7000
auth.method = "token"
auth.token = "<токен frps>"

[[proxies]]
name = "private_ssh_stcp"             # резервный канал
type = "stcp"
secretKey = "<секрет STCP>"
localIP = "127.0.0.1"
localPort = 22

[[proxies]]
name = "private_ssh_xtcp"             # основной P2P-канал
type = "xtcp"
secretKey = "<секрет XTCP>"
localIP = "127.0.0.1"
localPort = 22
```

### Visitor (на машине, с которой подключаетесь — вне этой папки)

Тот же образ `frp-local:frpc`, конфиг — `[[visitors]]` вместо `[[proxies]]`.
Токен и секреты те же, что в `client/frpc.toml` (берутся из `.secrets`):

```toml
serverAddr = "<IP или домен VPS>"
serverPort = 7000
auth.method = "token"
auth.token = "<токен frps>"

[[visitors]]                          # резервный канал, без своего слушателя
name = "private_ssh_stcp"
type = "stcp"
serverName = "private_ssh_stcp"
secretKey = "<секрет STCP>"
bindPort = -1                         # -1 = только как цель fallback

[[visitors]]                          # основной P2P-канал + фолбэк
name = "private_ssh_xtcp"
type = "xtcp"
serverName = "private_ssh_xtcp"
secretKey = "<секрет XTCP>"
bindAddr = "127.0.0.1"
bindPort = 6000
keepTunnelOpen = true                 # держать пробитую «дыру» открытой
fallbackTo = "private_ssh_stcp"
fallbackTimeoutMs = 1000
```

`bindPort = -1` у stcp-visitor поддержан официально (v0.71.1): слушатель не
создаётся, visitor существует только как цель фолбэка. Запуск — так же, как
`client/`: папка с `build/` + `docker-compose.yml` (образ `frp-local:frpc`,
`network_mode: host`, конфиг монтируется read-only).

## Принятые решения

| Решение | Значение |
|---|---|
| Секреты | `setup.sh`: автогенерация + рендер конфигов; хранение `.secrets` (600); ротация `--rotate`; в логи docker не печатаются |
| Схема доступа | XTCP (P2P) как основной + STCP как фолбэк; SSH наружу не торчит нигде |
| Порты на VPS | только `7000` — служебный канал frpc↔frps |
| Аутентификация к frps | `auth.method = "token"` — в frps и в frpc (клиент; visitor — из `.secrets`) |
| Секреты каналов | два разных `secretKey` (stcp / xtcp), `openssl rand -hex 32` |
| XTCP-тюнинг | `keepTunnelOpen = true`; фолбэк через 1000 мс |
| Формат конфигов | TOML (INI устарел с v0.52) |
| Образы | Свои `frp-local:frpc` / `frp-local:frps` — сборка из исходников v0.71.1, `scratch`-финал, non-root, noweb |
| Оверлей безопасности | `go get x/net@v0.60.0` + `x/crypto@latest` + `apk upgrade` — закрывает 4×High |
| Шифрование канала | TLS frp включён по умолчанию (v0.50+); ssh шифруется сам поверх |
| Сеть | `network_mode: host` у frpc клиента; visitor — так же (см. сниппет) |
| webServer у frps | не используется — у сервера нет HTTP-интерфейса |
| Деплой | перенос папки + `docker compose up -d --build` в своей подпапке на каждой машине |

## Проверка после деплоя

- `docker logs frps` (VPS) — зарегистрировался frpc клиента, proxies запущены.
- `docker logs frpc` (клиент) — «start proxy success» для stcp и xtcp.
- В логах visitor'а — «start visitor success»; при удачном P2P:
  «nathole prepare success, nat type: …» / «nat hole connection successful»;
  при неудачном: «open tunnel timeout» — и ответ всё равно приходит (фолбэк).
- `ssh -p 6000 user@127.0.0.1` (или `ssh client`) — попадаем на клиентский sshd.
- Устойчивость: обрыв сети на любой стороне — frpc переподключается сам.

## Безопасность: важное

- Дверь на клиентский sshd не торчит наружу: подключения возможны только
  со знанием `secretKey` (и после подключения к VPS по токену).
- Всё равно включите на клиенте вход **только по ключам**
  (`PasswordAuthentication no`) — аутентифицирует именно его sshd.
- VPS видит только: служебный трафик frpc. При активном XTCP — не видит
  вообще содержимое сессии (P2P). При фолбэке — релей шифрованного потока.
- Токен и два секрета хранить втайне (файлы 600; в проекте — `.secrets`,
  visitor берёт значения из него же).
- STUN-сервер по умолчанию публичный (`stun.easyvoip.com:3478`); при желании —
  `natHoleStunServer` в frpc клиента и visitor'а.
- Фолбэк добавляет ~1 с к установке соединения при неудачном P2P — это норма.
- Антивирусы иногда помечают frpc как подозрительный инструмент (reverse proxy).

## Лицензия

[MIT](LICENSE)
