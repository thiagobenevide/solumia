# Ponta do túnel SSH reverso na VPS: o PC conecta (infra/scripts/conectar_vps) e publica a esteira
# (:8765 dele) como tunel:8765 na rede do compose. Só aceita chave e só encaminhamento reverso.
FROM alpine:3.20

RUN apk add --no-cache openssh-server \
    && adduser -D -s /bin/sh tunel \
    && echo 'tunel:*' | chpasswd -e

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh

EXPOSE 2222 8765
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
