# The relay image: a static binary on scratch, run as an unprivileged user.
#
# CI builds this for linux/amd64 and linux/arm64 and pushes it as
# `sha-<commit>`; a release only retags that digest, never rebuilds it.
#
#   docker build --build-arg VERSION=1.4.0 -t ighostvt-relay Relay

FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS build
ARG TARGETOS
ARG TARGETARCH
ARG VERSION=dev
RUN apk add --no-cache ca-certificates
WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" \
      -o /out/ighostvt-relay ./cmd/ighostvt-relay
# A named volume mounted on /data takes this directory's owner, so the relay
# can write its key and configuration there without running as root.
RUN mkdir -p /out/data && chown 65532:65532 /out/data && chmod 0700 /out/data

FROM scratch
# Only for finding the public address over HTTPS (RELAY_PUBLIC_HOST unset).
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/ighostvt-relay /usr/local/bin/ighostvt-relay
COPY --from=build --chown=65532:65532 /out/data /data
# On PATH, so `docker compose exec relay ighostvt-relay config` finds it;
# scratch has no shell to look anywhere else.
ENV PATH=/usr/local/bin
USER 65532:65532
EXPOSE 46405
VOLUME /data
ENTRYPOINT ["/usr/local/bin/ighostvt-relay"]
CMD ["serve"]
