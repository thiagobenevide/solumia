#!/bin/sh
set -eu
# Chave do servidor num volume: o PC não vê "host key mudou" quando o contêiner é recriado.
mkdir -p /etc/ssh/chaves
[ -f /etc/ssh/chaves/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/chaves/ssh_host_ed25519_key
# Copiada do bind mount para ter dono e permissões que o StrictModes do sshd aceita.
install -d -o tunel -g tunel -m 700 /home/tunel/.ssh
install -o tunel -g tunel -m 600 /config/authorized_keys /home/tunel/.ssh/authorized_keys
exec /usr/sbin/sshd -D -e
