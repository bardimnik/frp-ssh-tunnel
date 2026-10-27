[Русский](README.md) | **English**

# frp-ssh-tunnel — private SSH access to a machine behind NAT via a VPS

## What it is

A "client" machine behind NAT/firewall connects out to a VPS with a public IP;
the owner connects to the client through the VPS. Built on
[frp](https://github.com/fatedier/frp): `frps` (server) on the VPS, `frpc`
on the target machine, and a visitor wherever you connect from.

**Private by design**: the client's SSH port is never exposed anywhere. Access
is gated by `secretKey`s; the frp control channel is authenticated with a
token. The VPS has **exactly one inbound port open: 7000**.

**Your own images, not someone else's**: frp is built from source (the tag
tarball, sha256-pinned in the Dockerfile) in a multi-stage Dockerfile. The
final image is `scratch` (no shell, no busybox), non-root, with no web
dashboard embedded (`-tags noweb` — no npm supply chain in the build).
Dependencies with known CVEs are bumped at build time (`go get`, pinned
versions).

## Architecture

```
                                        ┌─ CALL: ssh -p 6000 user@127.0.0.1
                                        ▼
        ┌────────── primary: XTCP (P2P) ───────────┐
Connec- ┤                                          ▼
tion    direct: visitor ◄──────► CLIENT:22        VPS can't see the traffic
machine (VPS only helps punch through NAT)
(visitor,└─ fallback: STCP ──► relay via VPS:7000 ──► CLIENT:22
outside
the repo)   Only inbound on the VPS: 7000/tcp (frpc↔frps control channel)
```

- **Primary XTCP (P2P)**: NAT hole punching via STUN; when it succeeds,
  traffic flows directly between the connecting machine and the client —
  the VPS never sees it.
- **STCP fallback**: if punching fails (e.g., symmetric NATs), the connection
  automatically relays through the VPS — the channel doesn't break.

## Repository layout

Two **independent** compose projects — for two machines. Copy the whole
folder; each machine only uses its own subfolder:

```
.
├── README.md            # Russian docs
├── README.en.md         # this file
├── setup.sh             # generates secrets + renders configs: ./setup.sh <VPS_IP>
├── .secrets             # secret store (created by the script, chmod 600, gitignored)
├── client/              # → to the client machine (the one you connect TO)
│   ├── build/           #   Dockerfile
│   ├── docker-compose.yml  #    image frp-local:frpc
│   ├── frpc.toml.example   #    config template (rendered file is gitignored)
│   └── frpc.toml        #   rendered by setup.sh (stcp + xtcp proxies)
└── vps/                 # → to the VPS
    ├── build/
    ├── docker-compose.yml  # image frp-local:frps
    ├── frps.toml.example
    ├── frps.toml        # rendered by setup.sh
    └── .env.example     # → .env (rendered by setup.sh)
```

Transfer the folder any way you like (USB stick, SCP, zip). The build verifies
the frp source integrity itself: the sha256-pinned `ADD --checksum` fails the
build on any tampering.

## Quick start

Requirements: Docker + compose plugin, `openssl`.

### 1. VPS

```bash
cd <folder>
./setup.sh <VPS IP or hostname>     # secrets (once) + config rendering
cd vps
docker compose up -d --build
# firewall: allow inbound 7000/tcp ONLY
chown 10000:10000 frps.toml         # the config must be readable by the non-root container
docker compose restart
docker logs frps                    # "frps started successfully"
```

### 2. Client (the machine you connect TO)

```bash
cd <folder>
./setup.sh <VPS IP or hostname>     # same secrets (reused from .secrets)
cd client
docker compose up -d --build
chown 10000:10000 frpc.toml         # the config must be readable by the non-root container
docker compose restart
docker logs frpc                    # both proxies: "start proxy success"
```

### 3. Connecting (visitor — from any machine, outside this repo)

A visitor is an frpc with a `[[visitors]]` config (template:
`examples/visitor.example.toml`). It connects to the VPS and opens local port
6000 on "its" machine, wired to the tunnel leading to the client. The visitor
must be running when you connect:

```bash
ssh -p 6000 user@127.0.0.1          # user — an account ON THE CLIENT
```

Optionally, `~/.ssh/config`:

```
Host client
  HostName 127.0.0.1
  Port 6000
  User <your client-side user>
```

→ connect with: `ssh client`. Authentication is end-to-end: the client's sshd
checks you against its own keys; the VPS only sees encrypted relay traffic.

## Building the images

`build/Dockerfile` (in `client/build/` and `vps/build/` — identical):

```dockerfile
# excerpt — full file in build/Dockerfile
FROM golang:1.26-alpine AS builder
ADD --checksum=sha256:079f… https://github.com/fatedier/frp/archive/refs/tags/v0.71.1.tar.gz …
RUN … go get golang.org/x/net@v0.60.0 && go get golang.org/x/crypto@v0.58.0 \
 && go mod tidy && go build -tags noweb -trimpath -ldflags="-s -w" -o /out/frpc ./cmd/frpc …

FROM alpine:3.24 AS runtime-files   # CA + tzdata + passwd/group only
FROM scratch AS frpc-image          # and frps-image — no shell, no busybox
USER 10000:10000
CMD ["-c", "/etc/frp/frpc.toml"]
```

Why scratch: busybox CVE-2025-60876 is unfixed in alpine 3.23/3.24
("possibly vulnerable") and not confirmed fixed in edge (busybox 1.38.0 is
outside the vulnerable range `<= 1.37.0`, but the tracker hasn't confirmed).
Instead of a rolling edge base, we eliminate the package entirely: the binary
is static (`CGO_ENABLED=0`) and no shell is used at runtime. Side effect:
`docker exec -it … sh` is impossible in these containers — a plus.

**Verified locally (2026-10-27):** `frpc -v`/`frps -v` → `0.71.1`; e2e of the
stcp+xtcp scheme on the built images — GREEN on both paths: primary XTCP
(`nat hole connection successful`, P2P) and STCP fallback (with STUN broken:
`open tunnel timeout` → answer still arrives via the relay); grype:
**High = 0**, busybox eliminated. Remaining finding (no upstream fix, accepted):
`golang.org/x/crypto` GO-2026-5932 (Unknown). Will clear once frp bumps its
dependencies — just rebuild.

## Configuration

The files below are **rendered by `setup.sh`** from `.secrets` — you may edit
them by hand, but the next script run overwrites them. The source of truth is
`setup.sh` + `.secrets`.

### Secrets (`setup.sh`)

```bash
./setup.sh <VPS_IP>              # generate if missing + render (idempotent)
./setup.sh --rotate <VPS_IP>     # rotate ALL secrets (then sync the folder + restart)
./setup.sh show                  # print current values
```

`.secrets` (chmod 600) stores `AUTH_TOKEN`, `SECRET_STCP`, `SECRET_XTCP`,
`SERVER_ADDR`. Values are printed to the terminal only at generation/rotation
time — **never to docker logs** (logs are persistent and readable by everyone
with docker access). After `--rotate`, sync the folder across machines and
restart the containers.

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
      - "7000:7000"               # frpc<->frps control channel
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
allowPorts = [{ start = 6000, end = 6010 }]
```

No webServer on frps — the server has no HTTP interface at all.
Management: config files + `docker compose`; status via `docker logs frps`.

### vps/.env (chmod 600, rendered by setup.sh)

```
FRP_AUTH_TOKEN=<openssl rand -hex 32>
```

### client/frpc.toml (chmod 600, rendered by setup.sh)

```toml
serverAddr = "<VPS IP or hostname>"     # ← placeholder
serverPort = 7000
auth.method = "token"
auth.token = "<frps token>"

[[proxies]]
name = "private_ssh_stcp"             # fallback channel
type = "stcp"
secretKey = "<STCP secret>"
localIP = "127.0.0.1"
localPort = 22

[[proxies]]
name = "private_ssh_xtcp"             # primary P2P channel
type = "xtcp"
secretKey = "<XTCP secret>"
localIP = "127.0.0.1"
localPort = 22
```

### Visitor (on the machine you connect FROM — outside this repo)

Same `frp-local:frpc` image, config uses `[[visitors]]` instead of
`[[proxies]]`. Token and secrets are the same as in `client/frpc.toml`
(taken from `.secrets`):

```toml
serverAddr = "<VPS IP or hostname>"
serverPort = 7000
auth.method = "token"
auth.token = "<frps token>"

[[visitors]]                          # fallback channel, no listener of its own
name = "private_ssh_stcp"
type = "stcp"
serverName = "private_ssh_stcp"
secretKey = "<STCP secret>"
bindPort = -1                         # -1 = only a fallback target

[[visitors]]                          # primary P2P channel + fallback
name = "private_ssh_xtcp"
type = "xtcp"
serverName = "private_ssh_xtcp"
secretKey = "<XTCP secret>"
bindAddr = "127.0.0.1"
bindPort = 6000
keepTunnelOpen = true                 # keep the punched hole open
fallbackTo = "private_ssh_stcp"
fallbackTimeoutMs = 1000
```

`bindPort = -1` on an stcp visitor is officially supported (v0.71.1): no
listener is created, the visitor exists only as a fallback target. Run it the
same way as `client/`: a folder with `build/` + `docker-compose.yml`
(`frp-local:frpc` image, `network_mode: host`, config mounted read-only).

## Design decisions

| Decision | Value |
|---|---|
| Access scheme | XTCP (P2P) primary + STCP fallback; SSH is never exposed |
| VPS ports | only `7000` — the frpc↔frps control channel |
| frps authentication | `auth.method = "token"` — in frps and in frpc (client; visitor — from `.secrets`) |
| Channel secrets | two different `secretKey`s (stcp / xtcp), `openssl rand -hex 32` |
| XTCP tuning | `keepTunnelOpen = true`; fallback after 1000 ms |
| Config format | TOML (INI is deprecated since v0.52) |
| Images | Own `frp-local:frpc` / `frp-local:frps` — built from source v0.71.1, `scratch` final stage, non-root, noweb |
| Security overlay | `go get x/net@v0.60.0` + `x/crypto@v0.58.0` + `apk upgrade` — fixes 4×High |
| Channel encryption | frp TLS enabled by default (v0.50+); ssh encrypts on top |
| Networking | `network_mode: host` for the client frpc; visitor — same (see snippet) |
| frps webServer | not used — the server has no HTTP interface |
| Deployment | copy the folder + `docker compose up -d --build` in its subfolder on each machine |

## Post-deployment checks

- `docker logs frps` (VPS) — the client's frpc registered, proxies up.
- `docker logs frpc` (client) — "start proxy success" for stcp and xtcp.
- Visitor logs — "start visitor success"; on successful P2P: "nathole prepare
  success, nat type: …" / "nat hole connection successful"; on failure:
  "open tunnel timeout" — yet the answer still arrives (fallback).
- `ssh -p 6000 user@127.0.0.1` (or `ssh client`) — you land on the client's sshd.
- Resilience: kill the network on either side — frpc reconnects on its own.

## Security notes

- The door to the client's sshd is not exposed: connections are only possible
  with the `secretKey`s (and after authenticating to the VPS with the token).
- Still enable **key-only** login on the client (`PasswordAuthentication no`)
  — its sshd is what authenticates you.
- The VPS only sees frpc control traffic. On active XTCP it can't see session
  content at all (P2P). On fallback it relays the encrypted stream.
- Keep the token and both secrets private (600-permission files; in this
  project — `.secrets`, which the visitor copies values from).
- The default STUN server is public (`stun.easyvoip.com:3478`); override with
  `natHoleStunServer` in the client's and visitor's frpc if needed.
- Fallback adds ~1 s to connection setup when P2P fails — that's normal.
- Antivirus software sometimes flags frpc as suspicious (reverse proxy).

## License

[MIT](LICENSE)
