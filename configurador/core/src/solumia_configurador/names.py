"""Nomes, portas e caminhos de tudo que o Solumia instala.

Fonte única: nenhum outro arquivo escreve "solumia-…" ou uma porta à mão. Tudo é diferente da
instalação atual (`agent-*`, 48080, 2222, 8765, 9980, 8081, /opt/agent), para as duas poderem
rodar na mesma máquina sem uma derrubar a outra.
"""

from __future__ import annotations

PREFIXO = "solumia"
NOME_EXIBICAO = "Solumia"

# --- Serviços no host (systemd --user no Linux, serviço do usuário no Windows) ---------------
UNIDADE_WORKER = f"{PREFIXO}-worker"
UNIDADE_ESTEIRA = f"{PREFIXO}-esteira"
UNIDADE_TUNEL = f"{PREFIXO}-tunel"
UNIDADE_BACKUP = f"{PREFIXO}-backup"
UNIDADE_LLAMA = f"{PREFIXO}-llama"

# --- VPS ------------------------------------------------------------------------------------
PROJETO_COMPOSE = PREFIXO  # docker compose -p solumia: contêineres, redes e volumes com prefixo
DIR_VPS = f"/opt/{PREFIXO}"
DIR_DADOS_VPS = f"/var/lib/{PREFIXO}"
IMAGEM_GATEWAY = f"{PREFIXO}/gateway"
IMAGEM_TUNEL = f"{PREFIXO}/tunel"
VOLUME_DADOS = f"{PREFIXO}-dados"
SITE_NGINX = f"{PREFIXO}-{{dominio}}.conf"  # nginx do host (modo "host")
CONF_SEGURANCA_NGINX = f"{PREFIXO}-seguranca.conf"
ZONA_LOGIN_NGINX = f"{PREFIXO}_login"
SSHD_DROPIN = f"/etc/ssh/sshd_config.d/00-{PREFIXO}.conf"
FAIL2BAN_JAIL = f"/etc/fail2ban/jail.d/{PREFIXO}.local"
UNIDADE_DESFAZER = f"{PREFIXO}-desfazer"
SCRIPT_DESFAZER = f"/root/{PREFIXO}-desfazer.sh"
COMENTARIO_CHAVE_SSH = f"{PREFIXO}-configurador"

# --- Portas -----------------------------------------------------------------------------------
# Dentro dos contêineres as portas originais continuam (o código não muda); só o lado publicado
# no host é do Solumia.
PORTA_GATEWAY_HOST = 48180  # 127.0.0.1 na VPS; o nginx encaminha
PORTA_GATEWAY_CONTEINER = 48080
PORTA_TUNEL_SSH = 2223  # única porta extra aberta no firewall
PORTA_TUNEL_ESTEIRA_HOST = 18865  # 127.0.0.1, para o nginx do host
PORTA_COLLABORA_HOST = 9981  # 127.0.0.1
PORTA_ESTEIRA_LOCAL = 8865  # esteira no PC
PORTA_LLAMA_LOCAL = 8181  # llama-server no PC
PORTA_CORE_PADRAO = 0  # 0 = porta livre escolhida pelo sistema a cada sessão

# --- Arquivos do configurador -------------------------------------------------------------------
ARQUIVO_MANIFESTO = f"{PREFIXO}.toml"
ARQUIVO_COFRE = f"{PREFIXO}.cofre"
SERVICO_CHAVEIRO = f"{PREFIXO}-configurador"  # Secret Service / Credential Manager
CONTA_CHAVEIRO = "chave-do-cofre"
USER_AGENT = f"{PREFIXO}-configurador"

# Releases dos apps do próprio Solumia (celular, relógio, PC/notebook)
REPOSITORIO = "thiagobenevide/solumia"
