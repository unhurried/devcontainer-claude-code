FROM alpine:3.22

RUN apk add --no-cache squid

COPY squid.conf access-mode.*.conf allowed-domains.txt /etc/squid/
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

# See .env.example. entrypoint.sh selects /etc/squid/access-mode.${PROXY_MODE}.conf.
ENV PROXY_MODE=allowlist

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
