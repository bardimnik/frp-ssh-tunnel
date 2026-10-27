# syntax=docker/dockerfile:1
# frp v0.71.1 — сборка из исходников.
# Источник: тарбол тега v0.71.1 с github.com/fatedier/frp, скачивается при сборке;
# целостность гарантирована ADD --checksum (sha256 тарбола зафиксирован ниже) —
# подмена или повреждение источника уронит сборку.
#
# Финальный образ — scratch (без shell и busybox): бинарник статический
# (CGO_ENABLED=0), ENTRYPOINT/CMD в exec-форме. CA-сертификаты, tzdata и
# passwd/group берутся из alpine-стадии runtime-files. Минимальная поверхность
# атаки: один Go-бинарник + сертификаты.
#
# Оверлей безопасности: go get поднимает уязвимые зависимости frp
# (x/net >= 0.60.0 закрывает GO-2026-6603/6610/6611/6617). Версии закреплены
# для воспроизводимости — обновляйте осознанно, после аудита.
#
# Сборка (в каталоге рядом с этим Dockerfile):
#   docker build --target frpc-image -t frp-local:frpc .
#   docker build --target frps-image -t frp-local:frps .

FROM golang:1.26-alpine AS builder
ENV CGO_ENABLED=0
WORKDIR /src
ADD --checksum=sha256:079f5fdebfbf8b8fa42c8b03245d169a7b5298697d754d7345ea25f09e496722 \
    https://github.com/fatedier/frp/archive/refs/tags/v0.71.1.tar.gz frp-0.71.1.tar.gz
RUN tar -xzf frp-0.71.1.tar.gz --strip-components=1 \
 && go get golang.org/x/net@v0.60.0 \
 && go get golang.org/x/crypto@v0.58.0 \
 && go mod tidy \
 && go build -tags noweb -trimpath -ldflags="-s -w" -o /out/frpc ./cmd/frpc \
 && go build -tags noweb -trimpath -ldflags="-s -w" -o /out/frps ./cmd/frps

FROM alpine:3.24 AS runtime-files
RUN apk upgrade --no-cache \
 && apk add --no-cache ca-certificates tzdata \
 && addgroup -g 10000 frp \
 && adduser -D -u 10000 -G frp frp

FROM scratch AS frpc-image
COPY --from=builder /out/frpc /usr/local/bin/frpc
COPY --from=runtime-files /etc/ssl/certs /etc/ssl/certs
COPY --from=runtime-files /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=runtime-files /etc/passwd /etc/passwd
COPY --from=runtime-files /etc/group /etc/group
USER 10000:10000
ENTRYPOINT ["/usr/local/bin/frpc"]
CMD ["-c", "/etc/frp/frpc.toml"]

FROM scratch AS frps-image
COPY --from=builder /out/frps /usr/local/bin/frps
COPY --from=runtime-files /etc/ssl/certs /etc/ssl/certs
COPY --from=runtime-files /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=runtime-files /etc/passwd /etc/passwd
COPY --from=runtime-files /etc/group /etc/group
USER 10000:10000
ENTRYPOINT ["/usr/local/bin/frps"]
CMD ["-c", "/etc/frp/frps.toml"]
