#!/bin/sh
# squid runs as the `squid` user and cannot write to the container's stdout, so it
# logs to a file that root tails into `docker logs`.
set -e

install -d -o squid -g squid /var/log/squid
: > /var/log/squid/access.log
chown squid:squid /var/log/squid/access.log
tail -F /var/log/squid/access.log &

# squid.conf includes this file; an unknown PROXY_MODE makes squid fail to start.
ln -sf "/etc/squid/access-mode.${PROXY_MODE}.conf" /etc/squid/access-mode.conf

# A stale pid file from a previous run makes squid exit FATAL.
rm -f /run/squid.pid

exec squid -N -f /etc/squid/squid.conf
