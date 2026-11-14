#!/bin/sh
set -eu
# Server key in a volume: the PC does not see "host key changed" when the container is recreated.
mkdir -p /etc/ssh/chaves
[ -f /etc/ssh/chaves/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/chaves/ssh_host_ed25519_key
# Copied from the bind mount to get an owner and permissions that sshd StrictModes accepts.
install -d -o tunel -g tunel -m 700 /home/tunel/.ssh
install -o tunel -g tunel -m 600 /config/authorized_keys /home/tunel/.ssh/authorized_keys
exec /usr/sbin/sshd -D -e
