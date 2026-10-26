# Ollama behind a Caddy bearer-token proxy. Ollama has no native auth and its
# API also exposes pull/delete/create/generate, so it listens on loopback only
# and Caddy publishes just the health probe and POST /api/embed.
FROM caddy:2.11.7 AS caddy

FROM ollama/ollama:0.40.11

COPY --from=caddy /usr/bin/caddy /usr/bin/caddy
COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
