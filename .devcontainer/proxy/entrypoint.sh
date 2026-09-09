#!/bin/sh
# squid drops privileges to the `squid` user, which cannot open the container's
# stdout pipe, so it logs to a file and root tails it into `docker logs`.
set -e

install -d -o squid -g squid /var/log/squid
: > /var/log/squid/access.log
chown squid:squid /var/log/squid/access.log
tail -F /var/log/squid/access.log &

# PROXY_MODE is set (via ../.env, interpolated by docker-compose.yml) on this
# container's environment. "open" swaps in the config with no domain allowlist; any
# other value, including unset, keeps the default allowlist config.
case "${PROXY_MODE:-allowlist}" in
    open) CONF=/etc/squid/squid-open.conf ;;
    *)    CONF=/etc/squid/squid.conf ;;
esac

# The pid file survives a container restart (the writable layer is not reset), and
# `exec` below makes squid PID 1, so the stale file always names PID 1 -- a pid that is
# alive by definition, being squid itself. squid reads that as "another instance is
# already running" and exits FATAL, forever, since every restart re-reads the same file.
rm -f /run/squid.pid

exec squid -N -f "$CONF"
