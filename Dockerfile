FROM ghost:latest
USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl jq sqlite3 && \
    rm -rf /var/lib/apt/lists/* && \
    npm install -g bcrypt

COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["entrypoint.sh"]