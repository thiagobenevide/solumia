# VPS end of the reverse SSH tunnel: the PC connects (infra/scripts/conectar_vps) and publishes the esteira
# (its :8765) as tunel:8765 on the compose network. Key only, reverse forwarding only.
FROM alpine:3.20

RUN apk add --no-cache openssh-server \
    && adduser -D -s /bin/sh tunel \
    && echo 'tunel:*' | chpasswd -e

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh

EXPOSE 2222 8765
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
