"""Names, ports and paths of everything Solumia installs.

Single source: no other file writes "solumia-…" or a port by hand. Everything differs from the
current installation (`agent-*`, 48080, 2222, 8765, 9980, 8081, /opt/agent), so both can run on
the same machine without one taking the other down.
"""

from __future__ import annotations

PREFIX = "solumia"
DISPLAY_NAME = "Solumia"

# --- Host services (systemd --user on Linux, user service on Windows) -----------------------
WORKER_UNIT = f"{PREFIX}-worker"
PIPELINE_UNIT = f"{PREFIX}-esteira"
TUNNEL_UNIT = f"{PREFIX}-tunel"
BACKUP_UNIT = f"{PREFIX}-backup"
LLAMA_UNIT = f"{PREFIX}-llama"

# --- VPS ------------------------------------------------------------------------------------
COMPOSE_PROJECT = PREFIX  # docker compose -p solumia: prefixed containers, networks and volumes
DIR_VPS = f"/opt/{PREFIX}"
VPS_DATA_DIR = f"/var/lib/{PREFIX}"
GATEWAY_IMAGE = f"{PREFIX}/gateway"
TUNNEL_IMAGE = f"{PREFIX}/tunel"
DATA_VOLUME = f"{PREFIX}-dados"
SITE_NGINX = f"{PREFIX}-{{dominio}}.conf"  # host nginx ("host" mode)
NGINX_SECURITY_CONF = f"{PREFIX}-seguranca.conf"
ZONA_LOGIN_NGINX = f"{PREFIX}_login"
SSHD_DROPIN = f"/etc/ssh/sshd_config.d/00-{PREFIX}.conf"
FAIL2BAN_JAIL = f"/etc/fail2ban/jail.d/{PREFIX}.local"
UNDO_UNIT = f"{PREFIX}-desfazer"
UNDO_SCRIPT = f"/root/{PREFIX}-desfazer.sh"
SSH_KEY_COMMENT = f"{PREFIX}-configurador"

# --- Portas -----------------------------------------------------------------------------------
# Inside the containers the original ports stay (the code does not change); only the side
# published on the host belongs to Solumia.
GATEWAY_HOST_PORT = 48180  # 127.0.0.1 on the VPS; nginx forwards
GATEWAY_CONTAINER_PORT = 48080
SSH_TUNNEL_PORT = 2223  # the only extra port open in the firewall
PIPELINE_TUNNEL_HOST_PORT = 18865  # 127.0.0.1, for the host nginx
COLLABORA_HOST_PORT = 9981  # 127.0.0.1
PIPELINE_LOCAL_PORT = 8865  # pipeline on the PC
LLAMA_LOCAL_PORT = 8181  # llama-server on the PC
DEFAULT_CORE_PORT = 0  # 0 = free port picked by the system on each session

# --- Configurator files -------------------------------------------------------------------------
MANIFEST_FILE = f"{PREFIX}.toml"
VAULT_FILE = f"{PREFIX}.cofre"
SERVICO_CHAVEIRO = f"{PREFIX}-configurador"  # Secret Service / Credential Manager
KEYRING_ACCOUNT = "chave-do-cofre"
USER_AGENT = f"{PREFIX}-configurador"

# Releases of Solumia's own apps (phone, watch, PC/laptop)
REPOSITORY = "thiagobenevide/solumia"
