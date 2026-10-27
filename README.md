# frp-ssh-tunnel — приватный SSH-доступ к машине за NAT через VPS

**Русский** | [English](README.en.md)

## Что это

Машина «клиент» (за NAT/фаерволом) сама подключается к VPS с публичным IP;
владелец подключается к клиенту через VPS. Используется
[frp](https://github.com/fatedier/frp): `frps` (сервер) на VPS, `frpc`
на целевой машине (ваш компьютер), `frpc-visitor` — там, откуда
подключаетесь (см. `visitor/`).

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
Visitor ┤                                          ▼
(frpc-        напрямую: visitor ◄──────► КЛИЕНТ:22    VPS трафик не видит
 visitor)     (VPS только помогает пробить NAT)
        └─ фолбэк: STCP ──► релей через VPS:7000 ──► КЛИЕНТ:22

Наружу на VPS: только 7000/tcp (служебный канал frpc↔frps)
```

- **Основной канал XTCP (P2P)**: hole punching через STUN; при успехе трафик
  идёт напрямую между машиной подключения и клиентом — VPS не видит его вовсе.
- **Фолбэк STCP**: если пробивание не удалось (например, симметричные NAT),
  соединение автоматически уходит через релей VPS — канал не рвётся.

## Состав папки

Три **независимых** compose-проекта — для трёх ролей. Папка переносится
целиком, **кроме `pki/`** (он остаётся на первоисточнике); на каждой машине
работает только своя подпапка:

```
.
├── README.md            # этот файл
├── README.en.md         # английская версия
├── LICENSE              # MIT
├── .gitignore           # рендеренные конфиги, секреты и PKI не попадают в git
├── setup.sh             # генерация секретов + PKI + рендер конфигов: ./setup.sh <IP_VPS>
├── .secrets             # хранилище секретов (создаётся скриптом, chmod 600)
├── pki/                 # CA + сертификаты (gitignored; ключи 600)
├── tests/               # run-tests.sh — тесты setup.sh (изолированная песочница)
├── examples/            # visitor.example.toml — шаблон конфига visitor'а
├── client/              # ← на ваш компьютер (к которому подключаются)
│   ├── build/           #   Dockerfile
│   ├── docker-compose.yml  #    образ frp-local:frpc
│   ├── tls/             #   ca.crt + client.crt/key (рендерится setup.sh)
│   ├── frpc.toml.example   #    шаблон (рендеренный файл игнорируется git)
│   ├── .env             #   FRP_UID/FRP_GID (рендерится setup.sh)
│   └── frpc.toml        #   рендерится setup.sh (stcp- и xtcp-прокси)
├── visitor/             # ← на машину, С КОТОРОЙ подключаются (frpc-visitor)
│   ├── build/
│   ├── docker-compose.yml  # образ frp-local:frpc
│   ├── tls/             #   ca.crt + visitor.crt/key (рендерится setup.sh)
│   ├── visitor.toml     #   рендерится setup.sh (visitors: xtcp + stcp-fallback)
│   └── .env             #   FRP_UID/FRP_GID
└── vps/                 # ← на VPS
    ├── build/
    ├── docker-compose.yml  # образ frp-local:frps
    ├── tls/             #   ca.crt + server.crt/key (рендерится setup.sh)
    ├── frps.toml.example
    ├── frps.toml        # рендерится setup.sh
    ├── .env.example
    └── .env             # токен + FRP_UID/FRP_GID (рендерится setup.sh)
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

Требования: Docker с compose-плагином, `openssl`. Сборке нужен доступ к
github.com — тарбол исходников скачивается и проверяется checksum'ом
(`ADD --checksum`).

### 1. VPS

```bash
cd <папка>
./setup.sh <IP или домен VPS>      # секреты (один раз) + рендер конфигов
cd vps
docker compose up -d --build
# фаервол: открыть входящие ТОЛЬКО 7000/tcp
docker compose restart
docker logs frps                   # «frps started successfully»
```

### 2. Клиент (ваш компьютер — машина, к которой подключаются)

```bash
cd <папка>
./setup.sh <IP или домен VPS>      # тот же секрет (переиспользуется из .secrets)
cd client
docker compose up -d --build
docker compose restart
docker logs frpc                   # два прокси: «start proxy success»
```

### 3. Visitor (машина, С КОТОРОЙ подключаются)

```bash
cd <папка>
./setup.sh <IP или домен VPS>      # рендер visitor.toml + visitor/tls
cd visitor
docker compose up -d --build
docker logs frpc-visitor           # «start visitor success»; при P2P — «nat hole connection successful»
```

Артефакты (`.secrets` + `pki/` — из них рендерятся `visitor/visitor.toml` и
`visitor/tls/`) переносятся с первоисточника (VPS), как и для клиента.

Подключение:

```bash
ssh -p 6000 root@127.0.0.1         # учётка — НА КЛИЕНТЕ (порт 6000 слушает visitor)
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

`build/Dockerfile` — в трёх ролях (`client/build/`, `visitor/build/`, `vps/build/`) идентичны. Тарбол
исходников frp в репозитории не хранится — Dockerfile скачивает его при
сборке; sha256 `079f5fde…6722` зафиксирован в `ADD --checksum`:

```dockerfile
# фрагмент — полный файл в build/Dockerfile
FROM golang:1.26-alpine AS builder
ADD --checksum=sha256:079f… https://github.com/fatedier/frp/archive/refs/tags/v0.71.1.tar.gz …
RUN … go get golang.org/x/net@v0.61.0 && go get golang.org/x/crypto@v0.58.0 \
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
./setup.sh --init <IP_VPS>      # сделать машину первоисточником (полная регенерация секретов + PKI)
./setup.sh --rotate <IP_VPS>    # перевыпуск всех секретов и сертов (на первоисточнике)
./setup.sh show        # показать текущие значения
```

`.secrets` (chmod 600) хранит: `AUTH_TOKEN`, реестр `MACHINES`, пары
`SECRET_<ИМЯ>_STCP/XTCP` каждой машины, `SERVER_ADDR`, `PKI_ADDR`. Значения
печатаются в терминал только при генерации/ротации — **не в логи docker**
(логи постоянны и читаемы всеми с доступом к docker).

**После `--rotate`** (выполняется на первоисточнике): для КАЖДОЙ машины
перерендерьте её сертификаты (`MACHINE=<имя> ./setup.sh <IP>`) и раздайте:
`.secrets` + `client/tls/` — клиенту, `.secrets` + `visitor/tls/` — visitor'у,
затем рестарт контейнеров на всех машинах. `pki/` (с `ca.key`) с
первоисточника не уходит.

Команда `--init` делает машину **первоисточником** (полная регенерация
секретов и PKI) — выполняется один раз; остальные машины получают
артефакты (`.secrets` + `pki/`) копированием.

## Сертификаты (PKI — взаимный TLS)

Весь TLS-трафик frp защищён **взаимными сертификатами** нашего собственного CA
(ECDSA P-256, срок 365 дней): frps предъявляет серверный серт, клиенты —
клиентские; оба направления проверяются цепочкой до `ca.crt`. Это делает
MITM на канале frpc↔frps невозможным, а токен перестаёт быть единственной
защитой: подключиться может только владелец сертификата, подписанного нашим CA.

- **SAN серверного серта** выводится из `SERVER_ADDR` (домен → `DNS:…`,
  IP → `IP:…`) — подключайтесь тем же адресом, что передали `setup.sh`;
  при смене адреса переиздаётся только серверный серт, CA и клиентские
  не трогаются.
- `pki/ca.key` — корень доверия: живёт **только** на машине-первоисточнике и
  **не распространяется**. Куда что копировать:
  - клиентской машине: каталог `client/tls/` (ca.crt + client.crt + client.key)
  - visitor'у: `ca.crt` + `visitor.crt/key`
  - VPS рендерит себе `vps/tls/` сам.
- Клон-деплой: переносятся `.secrets` **и** `client/tls/`; при наличии
  `.secrets` без PKI-материалов скрипт откажется работать (защита от рождения
  чужого CA) и подскажет, что скопировать.
- Продление: срок 365 дней; перевыпуск — `--rotate` на первоисточнике, затем
  для каждой машины: `MACHINE=<имя> ./setup.sh <IP>` (перерендер её
  `client/tls/`) + копия `.secrets` и `client/tls/` на машину + рестарт.
  Точечный перевыпуск серта одной машины (например, при компрометации):
  `rm pki/client-<имя>.* && MACHINE=<имя> ./setup.sh <IP>`.

**Важно при деплое из клона**: в клоне нет ни `.secrets`, ни готового `tls/` —
они переносятся с машины-первоисточника (VPS) **вместе**:
```bash
scp root@<VPS>:/opt/frp-ssh-tunnel/.secrets ./.secrets
scp -r root@<VPS>:/opt/frp-ssh-tunnel/client/tls ./client/
./setup.sh <IP>       # переиспользует артефакты — токен и серты совпадут
```
Без PKI-материалов при наличии `.secrets` скрипт откажется работать — это
защита от случайного рождения второго CA. Проверка согласованности:
`./setup.sh show` на обеих машинах.

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
    user: "${FRP_UID:-10000}:${FRP_GID:-10000}"   # deploy-пользователь
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

transport.tls.force = true
transport.tls.certFile = "/etc/frp/tls/server.crt"
transport.tls.keyFile = "/etc/frp/tls/server.key"
transport.tls.trustedCaFile = "/etc/frp/tls/ca.crt"
```

webServer у frps не используется — у сервера нет HTTP-интерфейса вообще.
Управление: файлы конфигурации + `docker compose`; статус — `docker logs frps`.

### vps/.env (chmod 600, рендерится setup.sh)

```
FRP_AUTH_TOKEN=<openssl rand -hex 32>
FRP_UID=<id -u deploy-пользователя>
FRP_GID=<id -g deploy-пользователя>
```

### client/frpc.toml (chmod 600, рендерится setup.sh)

```toml
serverAddr = "<IP или домен VPS>"     # ← плейсхолдер
serverPort = 7000
auth.method = "token"
auth.token = "<токен frps>"

transport.tls.certFile = "/etc/frp/tls/client.crt"
transport.tls.keyFile = "/etc/frp/tls/client.key"
transport.tls.trustedCaFile = "/etc/frp/tls/ca.crt"

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

### client/docker-compose.yml

```yaml
services:
  frpc:
    image: frp-local:frpc
    build:
      context: ./build
      target: frpc-image
    container_name: frpc
    restart: unless-stopped
    network_mode: host          # исходящее соединение к VPS + доступ к sshd хоста
    user: "${FRP_UID:-10000}:${FRP_GID:-10000}"   # deploy-пользователь
    volumes:
      - ./frpc.toml:/etc/frp/frpc.toml:ro
      - ./tls:/etc/frp/tls:ro
```

Портов наружу не нужно: соединение к VPS исходящее. Автозапуск после
перезагрузки — `restart: unless-stopped`.

### Visitor (машина, с которой подключаютесь)

Конфиг `visitor/visitor.toml` **рендерится `setup.sh`** (те же `.secrets` и
`pki/`) — листинг ниже для понимания того, что получается:

```toml
serverAddr = "<IP или домен VPS>"
serverPort = 7000
auth.method = "token"
auth.token = "<токен frps>"

transport.tls.certFile = "/etc/frp/tls/visitor.crt"
transport.tls.keyFile = "/etc/frp/tls/visitor.key"
transport.tls.trustedCaFile = "/etc/frp/tls/ca.crt"

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
создаётся, visitor существует только как цель фолбэка. Запуск — как у клиента:
`cd visitor && docker compose up -d --build` (образ `frp-local:frpc`,
`network_mode: host`, конфиг и `tls/` монтируются read-only).

## Добавление сервисов

Правило: новый блок `[[proxies]]` на клиенте + зеркальный `[[visitors]]` на
visitor-машине. VPS трогать не нужно — stcp/xtcp не просят публичных портов.

⚠️ `client/frpc.toml` и `visitor/visitor.toml` **рендерятся `setup.sh`** —
правьте шаблоны внутри `setup.sh`, а не отрендеренные файлы (их правки
затрутся при следующем запуске).

Пример — веб-панель на порту 8080 клиента:

1. В `setup.sh`, в heredoc `client/frpc.toml`:
   ```toml
   [[proxies]]
   name = "private_web_stcp"
   type = "stcp"
   secretKey = "${SECRET_WEB}"
   localIP = "127.0.0.1"
   localPort = 8080
   ```
2. В heredoc `visitor/visitor.toml`:
   ```toml
   [[visitors]]
   name = "private_web_stcp"
   type = "stcp"
   serverName = "private_web_stcp"
   secretKey = "${SECRET_WEB}"
   bindAddr = "127.0.0.1"
   bindPort = 8081        # порт на visitor-машине
   ```
3. Секрет на каждый сервис — свой (утечка ключа веб-панели ≠ утечка SSH):
   в секции генерации `setup.sh` — `SECRET_WEB=$(gen)` и строка в `.secrets`.
4. Применить: `git commit` + `git push` (в git попадёт только структура —
   секреты берутся из `.secrets`), затем на клиенте и visitor-машине:
   `git pull && ./setup.sh <IP> && docker compose up -d`.

Доступ: `http://localhost:8081` на visitor-машине.

| Путь | Когда | Цена |
|---|---|---|
| stcp | приватный сервис, доступ только вам | только правка шаблонов |
| xtcp + stcp-фолбэк | трафик-heavy сервис (P2P быстрее) | два блока + secretKey |
| tcp + `remotePort` | сервис нужен ПУБЛИЧНО | публичный порт на VPS + фаервол |

Нюансы: имена прокси уникальны на frps; `localIP = "127.0.0.1"` — сервис
должен слушать на клиенте. Если сервисов станет много — у frp есть
`includes = ["./confd/*.toml"]` (файл на сервис); механизм не подключён
(YAGNI — добавим, когда понадобится).

## Несколько клиентских машин

Каждая клиентская машина имеет **имя** (`MACHINE`, по умолчанию `private` —
обратная совместимость одиночной установки). На машину уникализируется всё:

| Артефакт | Формат |
|---|---|
| Имена прокси | `<machine>_ssh_stcp` / `<machine>_ssh_xtcp` |
| Секреты каналов | `SECRET_<ИМЯ>_STCP` / `SECRET_<ИМЯ>_XTCP` в `.secrets` |
| Клиентский серт | `pki/client-<machine>.crt/key` (рендерится в `client/tls/` как `client.crt/key`) |
| Visitor-блоки | по блоку `[[visitors]]` на машину, порт `6000 + N` (порядок регистрации) |

Реестр машин — `MACHINES` в `.secrets`; пополняется автоматически при запуске
`setup.sh` с новой `MACHINE`.

### Как добавить машину

1. **На VPS (первоисточнике)** — выпуск артефактов новой машины:
   ```bash
   MACHINE=<имя> ./setup.sh bardimnik.ru
   ```
   (секреты пары + серт `client-<имя>` + пополнение реестра; `client/tls/`
   перерендерится под эту машину)
2. **На новой машине**:
   ```bash
   git clone https://github.com/bardimnik/frp-ssh-tunnel.git
   # скопировать с VPS: .secrets и client/tls (СРАЗУ после шага 1)
   MACHINE=<имя> ./setup.sh bardimnik.ru
   cd client && docker compose up -d --build
   ```
3. **На visitor-машине** — обновить реестр и блоки:
   ```bash
   git pull
   scp root@<VPS>:/opt/frp-ssh-tunnel/.secrets ./.secrets
   ./setup.sh <IP>                     # visitor.toml дополнится блоком новой машины
   cd visitor && docker compose up -d
   ```
4. **Псевдоним** на visitor-машине:
   ```
   Host <имя>        # например: Host homeserver
     HostName 127.0.0.1
     Port 6001        # 6000 + номер машины в реестре
     User <пользователь>
   ```

Масштаб: десятки машин — без ограничений (frp держит тысячи подключений;
порты visitor'а растут от 6000 в порядке регистрации). Внимание: если машин
в реестре несколько, а `MACHINE` не задан — скрипт предупредит (рендер
выполняется для `private`).

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
| Оверлей безопасности | `go get x/net@v0.61.0` + `x/crypto@v0.58.0` + `apk upgrade` — закрывает 4×High |
| Шифрование канала | TLS frp включён по умолчанию (v0.50+); ssh шифруется сам поверх |
| Сеть | `network_mode: host` у frpc клиента; visitor — так же (см. сниппет) |
| Владение конфигами | `user: ${FRP_UID}:${FRP_GID}` в compose (рендерит `setup.sh` из `id -u`/`id -g`) — chown и sudo не нужны |
| webServer у frps | не используется — у сервера нет HTTP-интерфейса |
| Деплой | перенос папки + `docker compose up -d --build` в своей подпапке на каждой машине |

## Сеть: почему host-режим и почему не нужна отдельная сеть

| Роль | Сеть | Почему |
|---|---|---|
| client | `network_mode: host` | frpc должен доставать до sshd самого хоста (`localIP = "127.0.0.1"`) — в bridge-сети 127.0.0.1 был бы контейнер, а не хост |
| visitor | `network_mode: host` | visitor слушает `127.0.0.1:6000` — чтобы ваш `ssh -p 6000` попадал в туннель |
| vps | обычный bridge + публикация порта | frps нужно одно: принимать снаружи 7000 (`ports: ["7000:7000"]`) |

- Docker-сети не растягиваются между машинами — связь ролей и есть frp-туннель;
  внутри проекта один контейнер — кастомная сеть не добавит ничего (дефолтный
  bridge проекта уже даёт связь по имени сервиса, если контейнеров станет больше).
- `network_mode: host` — осознанный компромисс (общий сетевой стек хоста);
  компенсации: non-root под вашим uid, scratch-образ, конфиги read-only.
- Инвариант безопасности: строка `ports:` в `vps/docker-compose.yml` — полный
  список публикуемого (сейчас — только 7000). Docker публикует порты через DNAT
  **в обход** правил INPUT (ufw) — «лишний» порт в compose нельзя закрыть
  фаерволом, он открыт сразу. Следите за этим списком.

## Проверка после деплоя

- `docker logs frps` (VPS) — зарегистрировался frpc клиента, proxies запущены.
- `docker logs frpc` (клиент) — «start proxy success» для stcp и xtcp.
- В логах visitor'а — «start visitor success»; при удачном P2P:
  «nathole prepare success, nat type: …» / «nat hole connection successful»;
  при неудачном: «open tunnel timeout» — и ответ всё равно приходит (фолбэк).
- `ssh -p 6000 user@127.0.0.1` (или `ssh client`) — попадаем на клиентский sshd.
- Устойчивость: обрыв сети на любой стороне — frpc переподключается сам.

## Безопасность: важное

- **Взаимный TLS**: канал frpc↔frps защищён сертами нашего CA в обе стороны —
  MITM невозможен; frps отклоняет клиентов без подписанного серта
  (`transport.tls.force = true`). Токен и серты — два независимых фактора.
- Дверь на клиентский sshd не торчит наружу: подключения возможны только
  со знанием `secretKey` (и после подключения к VPS по токену и серту).
- Всё равно включите на клиенте вход **только по ключам**
  (`PasswordAuthentication no`) — аутентифицирует именно его sshd.
- VPS видит только: служебный трафик frpc. При активном XTCP — не видит
  вообще содержимое сессии (P2P). При фолбэке — релей шифрованного потока.
- Токен, секреты и приватные ключи PKI хранить втайне (файлы 600; в проекте —
  `.secrets` и `pki/`, gitignored). `pki/ca.key` не покидает первоисточник.
- STUN-сервер по умолчанию публичный (`stun.easyvoip.com:3478`); при желании —
  `natHoleStunServer` в frpc клиента и visitor'а.
- Фолбэк добавляет ~1 с к установке соединения при неудачном P2P — это норма.
- Антивирусы иногда помечают frpc как подозрительный инструмент (reverse proxy).

## Лицензия

[MIT](LICENSE)
