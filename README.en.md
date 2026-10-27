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

Two **independent** compose projects — for three roles. Copy the whole
folder; each machine only uses its own subfolder:

```
.
├── README.md            # Russian docs
├── README.en.md         # this file
├── LICENSE              # MIT
├── .gitignore           # rendered configs, secrets and PKI never enter git
├── setup.sh             # generates secrets + PKI + renders configs: ./setup.sh <VPS_IP>
├── .secrets             # secret store (created by the script, chmod 600, gitignored)
├── pki/                 # CA + certificates (gitignored; private keys 600)
├── tests/               # run-tests.sh — setup.sh test suite (isolated sandbox)
├── examples/            # visitor.example.toml — visitor config template
├── client/              # → to the client machine (the one you connect TO)
│   ├── build/           #   Dockerfile
│   ├── docker-compose.yml  #    image frp-local:frpc
│   ├── tls/             #   ca.crt + client.crt/key (rendered by setup.sh)
│   ├── frpc.toml.example   #    config template (rendered file is gitignored)
│   ├── .env             #   FRP_UID/FRP_GID (rendered by setup.sh)
│   └── frpc.toml        #   rendered by setup.sh (stcp + xtcp proxies)
├── visitor/             # → to the machine you connect FROM (frpc-visitor)
│   ├── build/
│   ├── docker-compose.yml  # image frp-local:frpc
│   ├── tls/             #   ca.crt + visitor.crt/key (rendered by setup.sh)
│   ├── visitor.toml     #   rendered by setup.sh (visitors: xtcp + stcp fallback)
│   └── .env             #   FRP_UID/FRP_GID
└── vps/                 # → to the VPS
    ├── build/
    ├── docker-compose.yml  # image frp-local:frps
    ├── tls/             #   ca.crt + server.crt/key (rendered by setup.sh)
    ├── frps.toml.example
    ├── frps.toml        # rendered by setup.sh
    ├── .env.example
    └── .env             # token + FRP_UID/FRP_GID (rendered by setup.sh)
```

Transfer the folder any way you like (USB stick, SCP, zip). The build verifies
the frp source integrity itself: the sha256-pinned `ADD --checksum` fails the
build on any tampering.

## Quick start

Requirements: Docker with the compose plugin, `openssl`. Building needs
outbound access to github.com — the source tarball is downloaded and
checksum-verified (`ADD --checksum`) at build time.

### 1. VPS

```bash
cd <folder>
./setup.sh <VPS IP or hostname>     # secrets (once) + config rendering
cd vps
docker compose up -d --build
# firewall: allow inbound 7000/tcp ONLY
docker compose restart
docker logs frps                    # "frps started successfully"
```

### 2. Client (the machine you connect TO)

```bash
cd <folder>
./setup.sh <VPS IP or hostname>     # same secrets (reused from .secrets)
cd client
docker compose up -d --build
docker compose restart
docker logs frpc                    # both proxies: "start proxy success"
```

### 3. Visitor (the machine you connect FROM)

```bash
cd <folder>
./setup.sh <VPS IP or hostname>     # renders visitor.toml + visitor/tls
cd visitor
docker compose up -d --build
docker logs frpc-visitor            # "start visitor success"; on P2P — "nat hole connection successful"
```

The artifacts (`.secrets` + `pki/` — from which `visitor/visitor.toml` and
`visitor/tls/` are rendered) travel from the source machine (the VPS), same
as for the client.

Connect:

```bash
ssh -p 6000 root@127.0.0.1          # account ON THE CLIENT (port 6000 is served by the visitor)
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
RUN … go get golang.org/x/net@v0.61.0 && go get golang.org/x/crypto@v0.58.0 \
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
./setup.sh --init <VPS_IP>       # make this machine the source of truth (full secrets + PKI regen)
./setup.sh --rotate <VPS_IP>     # rotate ALL secrets and certs (on the source machine)
./setup.sh show                  # print current values
```

`.secrets` (chmod 600) stores `AUTH_TOKEN`, `SECRET_STCP`, `SECRET_XTCP`,
`SERVER_ADDR`, `PKI_ADDR`. Values are printed to the terminal only at
generation/rotation time — **never to docker logs** (logs are persistent and
readable by everyone with docker access). After `--rotate`, sync `.secrets`
and `pki/` across machines and restart the containers.

`--init` makes a machine the **source of truth** (full regeneration of
secrets and PKI) — run it once; other machines receive the artifacts
(`.secrets` + `pki/`) by copying.

## Certificates (PKI — mutual TLS)

All frp TLS traffic is protected by **mutual certificates** of our own CA
(ECDSA P-256, 365 days): frps presents the server cert, clients present
client certs; both directions verify the chain up to `ca.crt`. This makes
MITM on the frpc↔frps channel impossible, and the token is no longer the
single line of defense: only holders of a certificate signed by our CA can
connect.

- **Server cert SAN** is derived from `SERVER_ADDR` (domain → `DNS:…`,
  IP → `IP:…`) — connect with the same address you passed to `setup.sh`;
  on address change only the server cert is re-issued, the CA and client
  certs stay untouched.
- `pki/ca.key` is the root of trust: it lives **only** on the source machine
  and is **never distributed**. What gets copied where:
  - client machine: the `client/tls/` folder (ca.crt + client.crt + client.key)
  - visitor: `ca.crt` + `visitor.crt/key`
  - the VPS renders its own `vps/tls/`.
- Clone deploys: `.secrets` **and** `client/tls/` travel together; with `.secrets`
  present but no PKI material, the script refuses to run (protection against
  a second CA) and tells you what to copy.
- Renewal: 365 days; re-issue with `./setup.sh --rotate <IP>` on the source
  machine + distribute `.secrets`/`pki/` + restarts.

**Important when deploying from a clone**: a clone has neither `.secrets` nor
a ready `tls/` — they travel together from the source machine (the VPS):
```bash
scp root@<VPS>:/opt/frp-ssh-tunnel/.secrets ./.secrets
scp -r root@<VPS>:/opt/frp-ssh-tunnel/client/tls ./client/
./setup.sh <IP>       # reuses the artifacts — token and certs match
```
If `.secrets` exists but PKI material is missing, the script refuses to run —
that's protection against accidentally creating a second CA. Consistency check:
`./setup.sh show` on both machines.

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
    user: "${FRP_UID:-10000}:${FRP_GID:-10000}"   # deploy user
    ports:
      - "7000:7000"               # frpc<->frps control channel (the only open port)
    environment:
      - FRP_AUTH_TOKEN=${FRP_AUTH_TOKEN}
    volumes:
      - ./frps.toml:/etc/frp/frps.toml:ro
      - ./tls:/etc/frp/tls:ro
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

No webServer on frps — the server has no HTTP interface at all.
Management: config files + `docker compose`; status via `docker logs frps`.

### vps/.env (chmod 600, rendered by setup.sh)

```
FRP_AUTH_TOKEN=<openssl rand -hex 32>
FRP_UID=<deploy user's `id -u`>
FRP_GID=<deploy user's `id -g`>
```

### client/.env (chmod 600, rendered by setup.sh)

```
FRP_UID=<deploy user's `id -u`>
FRP_GID=<deploy user's `id -g`>
```

### client/frpc.toml (chmod 600, rendered by setup.sh)

```toml
serverAddr = "<VPS IP or hostname>"     # ← placeholder
serverPort = 7000
auth.method = "token"
auth.token = "<frps token>"

transport.tls.certFile = "/etc/frp/tls/client.crt"
transport.tls.keyFile = "/etc/frp/tls/client.key"
transport.tls.trustedCaFile = "/etc/frp/tls/ca.crt"

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
    network_mode: host          # outbound connection to the VPS + access to the host's sshd
    user: "${FRP_UID:-10000}:${FRP_GID:-10000}"   # deploy user
    volumes:
      - ./frpc.toml:/etc/frp/frpc.toml:ro
      - ./tls:/etc/frp/tls:ro
```

No inbound ports needed: the connection to the VPS is outgoing. Auto-start
after reboot — `restart: unless-stopped`.

### Visitor (the machine you connect FROM)

The `visitor/visitor.toml` config is **rendered by `setup.sh`** (same
`.secrets` and `pki/`) — the listing below shows what you get:

```toml
serverAddr = "<VPS IP or hostname>"
serverPort = 7000
auth.method = "token"
auth.token = "<frps token>"

transport.tls.certFile = "/etc/frp/tls/visitor.crt"
transport.tls.keyFile = "/etc/frp/tls/visitor.key"
transport.tls.trustedCaFile = "/etc/frp/tls/ca.crt"

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
listener is created, the visitor exists only as a fallback target. Run it:
`cd visitor && docker compose up -d --build` (`frp-local:frpc` image,
`network_mode: host`, config and `tls/` mounted read-only).

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
| Security overlay | `go get x/net@v0.61.0` + `x/crypto@v0.58.0` + `apk upgrade` — fixes 4×High |
| Channel encryption | frp TLS enabled by default (v0.50+); ssh encrypts on top |
| Networking | `network_mode: host` for the client frpc; visitor — same (see snippet) |
| Config ownership | `user: ${FRP_UID}:${FRP_GID}` in compose (rendered by `setup.sh` from `id -u`/`id -g`) — no chown/sudo needed |
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

- **Mutual TLS**: the frpc↔frps channel is protected by certificates of our
  own CA in both directions — MITM is impossible; frps rejects clients without
  a signed certificate (`transport.tls.force = true`). Token + certificates —
  two independent factors.
- The door to the client's sshd is not exposed: connections are only possible
  with the `secretKey`s (and after authenticating to the VPS with the token
  and certificate).
- Still enable **key-only** login on the client (`PasswordAuthentication no`)
  — its sshd is what authenticates you.
- The VPS only sees frpc control traffic. On active XTCP it can't see session
  content at all (P2P). On fallback it relays the encrypted stream.
- Keep the token, secrets and PKI private keys private (600-permission files;
  in this project — `.secrets` and `pki/`, gitignored). `pki/ca.key` never
  leaves the source machine.
- The default STUN server is public (`stun.easyvoip.com:3478`); override with
  `natHoleStunServer` in the client's and visitor's frpc if needed.
- Fallback adds ~1 s to connection setup when P2P fails — that's normal.
- Antivirus software sometimes flags frpc as suspicious (reverse proxy).

## License

[MIT](LICENSE)
