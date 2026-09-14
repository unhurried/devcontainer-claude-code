#!/bin/sh
# squid runs as the `squid` user and cannot write to the container's stdout, so it
# logs to a file that root tails into `docker logs`.
set -e

install -d -o squid -g squid /var/log/squid
: > /var/log/squid/access.log
chown squid:squid /var/log/squid/access.log
tail -F /var/log/squid/access.log &

# PROXY_MODE=open replaces the allowlist rule with `allow all`.
# Port limits and the raw-address deny stay in both modes.
if [ "${PROXY_MODE:-allowlist}" = open ]; then
    sed -i 's/^http_access allow allowed_domains$/http_access allow all/' /etc/squid/squid.conf
fi

# A stale pid file from a previous run makes squid exit FATAL.
rm -f /run/squid.pid

exec squid -N -f /etc/squid/squid.conf
