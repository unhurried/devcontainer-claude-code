#!/bin/sh
# squid drops privileges to the `squid` user, which cannot open the container's
# stdout pipe, so it logs to a file and root tails it into `docker logs`.
set -e

install -d -o squid -g squid /var/log/squid
: > /var/log/squid/access.log
chown squid:squid /var/log/squid/access.log
tail -F /var/log/squid/access.log &

exec squid -N -f /etc/squid/squid.conf
