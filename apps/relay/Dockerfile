FROM debian:bookworm-slim

ARG IROH_RELAY_URL
ARG IROH_RELAY_SHA256
ARG CERTBOT_VERSION

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl tini python3 python3-venv \
 && rm -rf /var/lib/apt/lists/* \
 && python3 -m venv /opt/certbot \
 && /opt/certbot/bin/pip install --no-cache-dir "certbot==$CERTBOT_VERSION" \
 && ln -s /opt/certbot/bin/certbot /usr/local/bin/certbot \
 && curl -fsSL -o /tmp/iroh-relay.tar.gz "$IROH_RELAY_URL" \
 && echo "$IROH_RELAY_SHA256  /tmp/iroh-relay.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/iroh-relay.tar.gz -C /usr/local/bin ./iroh-relay \
 && rm /tmp/iroh-relay.tar.gz

COPY render-config.sh entrypoint.sh port80-router.py /app/
RUN chmod +x /app/render-config.sh /app/entrypoint.sh
EXPOSE 80 443 7842/udp 9090
ENTRYPOINT ["tini", "--", "/app/entrypoint.sh"]
