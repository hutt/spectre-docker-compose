FROM ghost:latest
USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates jq sqlite3 && \
    rm -rf /var/lib/apt/lists/*

RUN cd /var/lib/ghost/current && npm install -g bcryptjs-cli
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["entrypoint.sh"]
