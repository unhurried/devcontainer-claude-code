#!/bin/sh
# squid drops to the `squid` user and cannot open the container's stdout pipe, so it
# logs to a file and root tails it into `docker logs`.
set -e

install -d -o squid -g squid /var/log/squid
: > /var/log/squid/access.log
chown squid:squid /var/log/squid/access.log
tail -F /var/log/squid/access.log &

# "open" (see ../.env.example) lifts the domain allowlist by rewriting its one allow
# rule; any other value, including unset, keeps the allowlist. Everything else in
# squid.conf -- port limits, the raw-address deny -- applies in both modes.
if [ "${PROXY_MODE:-allowlist}" = open ]; then
    sed -i 's/^http_access allow allowed_domains$/http_access allow all/' /etc/squid/squid.conf
fi

# The pid file survives a restart, and `exec` makes squid PID 1, so a stale file always
# names a live pid -- squid reads that as "already running" and exits FATAL, forever.
rm -f /run/squid.pid

exec squid -N -f /etc/squid/squid.conf
