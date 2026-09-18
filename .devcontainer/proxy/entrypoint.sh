#!/bin/sh
# squid drops to its own user and cannot write to the container's stdout, so root
# tails its log file into `docker logs`.
set -e

install -d -o squid -g squid /var/log/squid
: > /var/log/squid/access.log
chown squid:squid /var/log/squid/access.log
tail -F /var/log/squid/access.log &

# squid.conf includes this file; an unknown PROXY_MODE makes squid fail to start.
ln -sf "/etc/squid/access-mode.${PROXY_MODE}.conf" /etc/squid/access-mode.conf

# A stale pid file makes squid exit FATAL.
rm -f /run/squid.pid

exec squid -N -f /etc/squid/squid.conf
