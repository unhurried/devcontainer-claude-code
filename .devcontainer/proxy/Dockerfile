FROM alpine:3.20

RUN apk add --no-cache squid

COPY squid.conf /etc/squid/squid.conf
COPY squid-open.conf /etc/squid/squid-open.conf
COPY allowed-domains.txt /etc/squid/allowed-domains.txt
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

EXPOSE 3128
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
