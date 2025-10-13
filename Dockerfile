FROM ghost:latest
USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl jq && \
    # Aufräumen, um das Image klein zu halten
    rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh
USER node
ENTRYPOINT ["entrypoint.sh"]
