#!/bin/sh
# squid drops to the `squid` user and cannot open the container's stdout pipe, so it
# logs to a file and root tails it into `docker logs`.
set -e

install -d -o squid -g squid /var/log/squid
: > /var/log/squid/access.log
chown squid:squid /var/log/squid/access.log
tail -F /var/log/squid/access.log &

# "open" (see ../.env) swaps in the config with no domain allowlist; any other value,
# including unset, keeps the allowlist.
case "${PROXY_MODE:-allowlist}" in
    open) CONF=/etc/squid/squid-open.conf ;;
    *)    CONF=/etc/squid/squid.conf ;;
esac

# The pid file survives a restart, and `exec` makes squid PID 1, so a stale file always
# names a live pid -- squid reads that as "already running" and exits FATAL, forever.
rm -f /run/squid.pid

exec squid -N -f "$CONF"
