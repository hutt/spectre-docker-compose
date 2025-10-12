FROM alpine:3.20

# Systempakete in einem Layer für schnellere Rebuilds
RUN apk add --no-cache \
    bash \
    curl \
    jq \
    unzip \
    ca-certificates \
    coreutils \
    openssl \
    sqlite

# bootstrap.sh in separatem Layer, damit nur dieser Layer bei Änderungen neu gebaut wird
COPY bootstrap.sh /usr/local/bin/bootstrap.sh
RUN chmod +x /usr/local/bin/bootstrap.sh

ENTRYPOINT ["/usr/local/bin/bootstrap.sh"]
