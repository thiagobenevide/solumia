"""VPS installation over SSH, without a terminal: gateway, tunnel, Collabora, nginx, TLS and hardening.

Replaces `infra/scripts/instalar_vps` + `endurecer_vps` and coexists with the current installation:
compose project `solumia`, ports and files prefixed with `solumia` (see `names.py`).

Safeguards against getting locked out (inherited from endurecer_vps):
1. the configurator key is installed and TESTED before any SSH change;
2. before touching SSH/firewall, an automatic undo is scheduled on the VPS for 5 min later;
3. the real SSH port is allowed in the firewall before the firewall is enabled;
4. `sshd -t` before the reload (open sessions are not dropped);
5. the undo is only cancelled after a NEW key-based connection gets in.
"""

from __future__ import annotations

import hashlib
import shlex
import time
from dataclasses import dataclass

from .. import generate, names, secret_store
from ..engine import Context, Plan, Step
from ..manifest import Manifest, Node
from ..ssh import Credentials, Session, SSHError
from ..vault import Vault

q = shlex.quote
D = names.DIR_VPS


@dataclass
class VPSOptions:
    senha: str | None = None  # first access; memory only
    senha_sudo: str | None = None
    desativar_login_por_senha: bool = True
    nginx: str = "auto"  # auto | docker | host


def _gateway_node(m: Manifest) -> tuple[str, Node]:
    found = m.node_with("gateway")
    if found is None or found[1].endereco != "ssh" or found[1].ssh is None:
        raise ValueError("o gateway não está num nó remoto (VPS)")
    return found


def plan(m: Manifest, vault: Vault, options: VPSOptions) -> Plan:
    name_node, no = _gateway_node(m)
    access = no.ssh
    assert access is not None
    if not access.impressao_host:
        raise ValueError("confirme a impressão digital da VPS na tela VPS antes de instalar")
    if not m.topologia.dominio or not m.topologia.email_tls:
        raise ValueError("defina domínio e e-mail para o certificado TLS")
    for s in (secret_store.PASSWORD_HASH, secret_store.TOTP):
        vault.require(s)  # conta criada antes (tela Conta)

    name_key = secret_store.SSH_PRIVATE_KEY.format(no=name_node)
    domain = m.topologia.dominio
    target = f"{access.usuario}@{access.host}:{access.porta}"

    def cred(with_key: bool) -> Credentials:
        return Credentials(
            usuario=access.usuario, host=access.host, porta=access.porta, impressao_host=access.impressao_host,
            chave_privada=vault.obter(name_key) if with_key else None,
            senha=options.senha, senha_sudo=options.senha_sudo,
        )

    def sessao(ctx: Context) -> Session:
        s = ctx.recursos.get("ssh")
        if s is None:
            raise SSHError("sem sessão SSH")
        return s

    def rodar(ctx: Context, cmd: str, **kw) -> str:  # noqa: ANN003
        return sessao(ctx).rodar(cmd, sudo=True, log=ctx.log, **kw)[1]

    # --- 1. conectar ----------------------------------------------------------------------------
    def conectar(ctx: Context) -> None:
        mask = ctx.recursos.get("_mascara", lambda s: s)
        ctx.recursos["_fechar"] = lambda: ctx.recursos["ssh"].fechar() if ctx.recursos.get("ssh") else None
        if vault.obter(name_key):
            try:
                ctx.recursos["ssh"] = Session(cred(True), mask).conectar()
                ctx.log(f"Conectado a {target} com a chave do configurador")
                ctx.recursos["por_chave"] = True
                return
            except SSHError as e:
                if not options.senha:
                    raise
                ctx.log(f"Chave do configurador não entrou ({e}); tentando a senha")
        if not options.senha:
            raise SSHError("informe a senha da VPS para o primeiro acesso")
        ctx.recursos["ssh"] = Session(cred(False), mask).conectar(usar_senha=True)
        ctx.recursos["por_chave"] = False
        ctx.log(f"Conectado a {target} com senha (só nesta execução; a senha não é gravada)")

    # --- 2. sistema -----------------------------------------------------------------------------
    def sistema(ctx: Context) -> None:
        output = rodar(ctx, ". /etc/os-release; echo \"$ID|$VERSION_ID|$(uname -m)|$(df -BG --output=avail / | tail -1 | tr -dc 0-9)|$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)\"")
        so, version, file, disk, mem = output.strip().splitlines()[-1].split("|")
        ctx.log(f"Sistema: {so} {version} ({file}), {disk} GB livres, {mem} MB de RAM")
        if so not in ("ubuntu", "debian"):
            raise SSHError(f"sistema {so} não suportado (use Ubuntu 22.04+/Debian 12+)")
        if file not in ("x86_64", "aarch64"):
            raise SSHError(f"arquitetura {file} não suportada")
        if int(disk or 0) < 10:
            raise SSHError("menos de 10 GB livres no disco")
        if int(mem or 0) < 1800:
            ctx.log("AVISO: menos de 2 GB de RAM; o Collabora pode ficar lento")

    # --- 3. configurator key ---------------------------------------------------------------------
    def chave(ctx: Context) -> None:
        private = vault.obter(name_key)
        if not private:
            private, public = secret_store.generate_ssh_key()
            vault.definir(name_key, private)
            ctx.log("Chave ed25519 do configurador gerada (privada só no cofre)")
        public = secret_store.public_key_of(private)
        s = sessao(ctx)
        # authorized_keys of the login user (not root's, if it is another user).
        s.rodar(
            "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; "
            f"grep -qxF {q(public)} ~/.ssh/authorized_keys || echo {q(public)} >> ~/.ssh/authorized_keys",
            log=ctx.log,
        )
        test = Session(cred(True), ctx.recursos.get("_mascara", lambda x: x)).conectar()
        test.rodar("true")
        s.fechar()
        ctx.recursos["ssh"] = test
        ctx.recursos["por_chave"] = True
        ctx.log("Acesso por chave confirmado; a partir daqui a senha não é mais usada")

    # --- 4. pacotes e Docker --------------------------------------------------------------------
    packages_list = "curl ca-certificates ufw fail2ban unattended-upgrades openssh-client"

    def pacotes_ok(ctx: Context) -> bool:
        cod, _ = sessao(ctx).rodar(f"dpkg -s {packages_list} >/dev/null 2>&1", sudo=True, checar=False)
        return cod == 0

    def pacotes(ctx: Context) -> None:
        rodar(ctx, f"export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq {packages_list}")

    def docker_ok(ctx: Context) -> bool:
        cod, _ = sessao(ctx).rodar("docker compose version >/dev/null 2>&1", sudo=True, checar=False)
        return cod == 0

    def docker(ctx: Context) -> None:
        # Official Docker repository; the script is downloaded to a file (never piped into the shell).
        rodar(ctx, "set -e; curl -fsSL https://get.docker.com -o /root/solumia-get-docker.sh; "
                   "sh /root/solumia-get-docker.sh; rm -f /root/solumia-get-docker.sh; "
                   "systemctl enable --now docker")

    # --- 5. ports and nginx mode -----------------------------------------------------------------
    def portas(ctx: Context) -> None:
        output = rodar(ctx, "ss -ltnpH 2>/dev/null || true")
        used: dict[int, str] = {}
        for line in output.splitlines():
            parts = line.split()
            if len(parts) < 4:
                continue
            try:
                port = int(parts[3].rsplit(":", 1)[1])
            except (IndexError, ValueError):
                continue
            used[port] = line
        ours = rodar(ctx, f"docker ps --filter label=com.docker.compose.project={names.COMPOSE_PROJECT} -q | wc -l")
        already_nosso = int((ours.strip().splitlines() or ["0"])[-1]) > 0
        for p in (names.GATEWAY_HOST_PORT, names.SSH_TUNNEL_PORT, names.PIPELINE_TUNNEL_HOST_PORT,
                  names.COLLABORA_HOST_PORT):
            if p in used and not already_nosso:
                raise SSHError(f"porta {p} já em uso na VPS: {used[p]}")
        nginx_host = sessao(ctx).rodar("systemctl is-active --quiet nginx", sudo=True, checar=False)[0] == 0
        web_used = 80 in used or 443 in used
        mode = options.nginx
        if mode == "auto":
            if nginx_host:
                mode = "host"
            elif not web_used or (already_nosso and "docker-proxy" in used.get(443, "")):
                mode = "docker"
            else:
                raise SSHError(
                    "as portas 80/443 já estão em uso por outro serviço (provavelmente o nginx em contêiner "
                    "da instalação atual). Use uma VPS separada para o Solumia ou mude a atual para o modo "
                    f"nginx do host. Detalhe: {used.get(443) or used.get(80)}"
                )
        ctx.recursos["modo_nginx"] = mode
        ctx.log(f"nginx: modo {mode}")

    # --- 6. arquivos ------------------------------------------------------------------------------
    def arquivos(ctx: Context) -> None:
        s = sessao(ctx)
        mode = ctx.recursos["modo_nginx"]
        rodar(ctx, f"install -d -m 750 {D} {D}/nginx {D}/tunel")
        package = generate.source_package()
        total = hashlib.sha256(package).hexdigest()
        s.send(package, f"{D}/fonte.tar.gz", 0o640)
        remote = rodar(ctx, f"sha256sum {D}/fonte.tar.gz | cut -d' ' -f1").strip().splitlines()[-1]
        if remote != total:
            raise SSHError("o pacote de código chegou corrompido na VPS")
        rodar(ctx, f"set -e; rm -rf {D}/fonte.novo; mkdir {D}/fonte.novo; "
                   f"tar -xzf {D}/fonte.tar.gz -C {D}/fonte.novo --no-same-owner; "
                   f"rm -rf {D}/fonte; mv {D}/fonte.novo {D}/fonte; rm -f {D}/fonte.tar.gz")
        ctx.log(f"Código enviado ({len(package) // 1024} KiB, SHA-256 {total[:12]}… conferido)")

        private_tunnel = vault.obter(secret_store.TUNNEL_PRIVATE_KEY)
        if not private_tunnel:
            private_tunnel, _ = secret_store.generate_ssh_key()
            vault.definir(secret_store.TUNNEL_PRIVATE_KEY, private_tunnel)
        s.send(generate.compose(mode == "docker").encode(), f"{D}/compose.yml", 0o640)
        s.send(generate.env_gateway(m, vault).encode(), f"{D}/gateway.env", 0o600)
        s.send(generate.authorized_keys_tunnel(secret_store.public_key_of(private_tunnel)).encode(),
                 f"{D}/tunel/authorized_keys", 0o644)
        s.send(generate.nginx_security().encode(), f"{D}/nginx/seguranca-http.conf", 0o644)
        ctx.log("compose.yml, gateway.env (0600), chave do túnel e nginx enviados")

    # --- 7. images and services ------------------------------------------------------------------
    dc = f"docker compose -p {names.COMPOSE_PROJECT} --project-directory {D} -f {D}/compose.yml --env-file {D}/.env"

    def imagens(ctx: Context) -> None:
        # Pinned Collabora and certbot versions: the digest is recorded the first time (like instalar_vps).
        cod, current = sessao(ctx).rodar(f"cat {D}/imagens.env", sudo=True, checar=False)
        if cod != 0 or "COLLABORA_IMAGEM=" not in current:
            lines = []
            for var, img in (("COLLABORA_IMAGEM", "collabora/code:latest"), ("CERTBOT_IMAGEM", "certbot/certbot:latest")):
                rodar(ctx, f"docker pull -q {img}")
                digest = rodar(ctx, f"docker image inspect -f '{{{{index .RepoDigests 0}}}}' {img}").strip().splitlines()[-1]
                lines.append(f"{var}={digest}")
            current = "\n".join(lines) + "\n"
            sessao(ctx).send(current.encode(), f"{D}/imagens.env", 0o644)
        imgs = dict(line.split("=", 1) for line in current.strip().splitlines() if "=" in line)
        sessao(ctx).send(generate.env_compose(m, vault, imgs).encode(), f"{D}/.env", 0o600)
        rodar(ctx, f"{dc} build -q gateway tunel", timeout=3600)
        ctx.log("Imagens construídas; Collabora e certbot fixados por digest")

    def servicos(ctx: Context) -> None:
        rodar(ctx, f"{dc} up -d --force-recreate --remove-orphans gateway tunel collabora")
        url = f"http://127.0.0.1:{names.GATEWAY_HOST_PORT}/health"
        for _ in range(30):
            cod, _ = sessao(ctx).rodar(f"curl -fsS {url} >/dev/null", sudo=True, checar=False)
            if cod == 0:
                ctx.log("Gateway respondendo em 127.0.0.1")
                return
            time.sleep(2)
        rodar(ctx, f"{dc} logs --tail 40 gateway", checar=False)
        raise SSHError("o gateway não respondeu ao /health")

    # --- 8. DNS e TLS ---------------------------------------------------------------------------
    def dns(ctx: Context) -> None:
        output = rodar(ctx, f"echo \"$(curl -fsS4 --max-time 5 https://api.ipify.org || true)|$(getent ahostsv4 {q(domain)} | awk 'NR==1{{print $1}}')\"")
        ip_vps, ip_dns = (output.strip().splitlines()[-1].split("|") + [""])[:2]
        if not ip_dns:
            raise SSHError(f"{domain} não resolve no DNS. Crie um registro A apontando para {ip_vps or 'a VPS'}.")
        if ip_vps and ip_dns != ip_vps:
            if m.topologia.cloudflare:
                ctx.log(f"{domain} → {ip_dns} (Cloudflare com proxy; VPS é {ip_vps})")
            else:
                raise SSHError(f"{domain} aponta para {ip_dns}, mas a VPS é {ip_vps}. Corrija o DNS.")
        else:
            ctx.log(f"DNS ok: {domain} → {ip_dns}")

    def tls(ctx: Context) -> None:
        s = sessao(ctx)
        email = m.topologia.email_tls
        if ctx.recursos["modo_nginx"] == "docker":
            tem = s.rodar(f"{dc} run --rm --no-deps --entrypoint test certbot -f "
                          f"/etc/letsencrypt/live/{domain}/fullchain.pem", sudo=True, checar=False)[0] == 0
            if not tem:
                s.send(generate.nginx_desafio(domain).encode(), f"{D}/nginx/site.conf", 0o644)
                rodar(ctx, f"{dc} up -d nginx && {dc} restart nginx")
                rodar(ctx, f"{dc} run --rm --no-deps --entrypoint certbot certbot certonly --webroot "
                           f"-w /var/www/certbot -d {q(domain)} --email {q(email)} --agree-tos "
                           "--non-interactive --no-eff-email", timeout=600)
            rodar(ctx, f"cp -f {D}/nginx/site.conf {D}/nginx/site.conf.anterior 2>/dev/null || true")
            s.send(generate.nginx_site_docker(domain).encode(), f"{D}/nginx/site.conf", 0o644)
            if s.rodar(f"{dc} run --rm --no-deps --entrypoint nginx nginx -t -q", sudo=True, log=ctx.log, checar=False)[0]:
                rodar(ctx, f"mv -f {D}/nginx/site.conf.anterior {D}/nginx/site.conf")
                raise SSHError("configuração nova do nginx inválida: mantida a anterior")
            rodar(ctx, f"{dc} up -d nginx certbot && {dc} restart nginx")
        else:
            site = f"/etc/nginx/sites-available/{names.SITE_NGINX.format(dominio=domain)}"
            active = f"/etc/nginx/sites-enabled/{names.SITE_NGINX.format(dominio=domain)}"
            seg = f"/etc/nginx/conf.d/{names.NGINX_SECURITY_CONF}"
            rodar(ctx, "dpkg -s python3-certbot-nginx >/dev/null 2>&1 || "
                       "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot python3-certbot-nginx")
            existed = s.rodar(f"test -f {site}", sudo=True, checar=False)[0] == 0
            if not existed:  # after certbot the file gains the TLS lines: only written the first time
                s.send(generate.nginx_site_host(domain).encode(), site, 0o644)
            # nginx -T dumps every loaded file under "# configuration file <path>:"; ours is skipped.
            pattern = "|".join(generate.NGINX_SINGLE_DIRECTIVES)
            _, found = s.rodar(
                "nginx -T 2>/dev/null | awk -v f=" + q(seg + ":") + " "
                "'/^# configuration file /{skip=($NF==f); next} !skip{print $1}' "
                f"| grep -xE '({pattern})' | sort -u", sudo=True, checar=False)
            existing = []
            for name in generate.NGINX_SINGLE_DIRECTIVES:
                if name in found.split():
                    existing.append(name)
            if existing:
                ctx.log(f"nginx do host já define {', '.join(existing)}: mantido o existente")
            s.send(generate.nginx_security(skip=existing).encode(), seg, 0o644)
            rodar(ctx, f"ln -sf {site} {active}")
            if s.rodar("nginx -t -q", sudo=True, log=ctx.log, checar=False)[0]:
                rodar(ctx, f"rm -f {seg} {active}" + ("" if existed else f" {site}"))
                raise SSHError("configuração do nginx inválida: removida, o nginx segue como estava")
            rodar(ctx, "systemctl reload nginx")
            rodar(ctx, f"certbot --nginx -d {q(domain)} -m {q(email)} --agree-tos --non-interactive "
                       "--no-eff-email --redirect --keep-until-expiring", timeout=600)
        ctx.log(f"TLS ativo para {domain}")

    # --- 9. hardening (with automatic undo) -------------------------------------------------------
    def endurecer(ctx: Context) -> None:
        if not ctx.recursos.get("por_chave"):
            raise SSHError("endurecimento exige sessão por chave (passo da chave não concluído)")
        s = sessao(ctx)
        ports_ssh = rodar(ctx, "sshd -T 2>/dev/null | awk '$1==\"port\"{print $2}' | sort -u | tr '\\n' ' '").strip()
        ports_ssh = ports_ssh.splitlines()[-1].strip() if ports_ssh else ""
        if not ports_ssh:
            raise SSHError("não consegui ler a porta do SSH (sshd -T): nada foi alterado")
        my_ip = rodar(ctx, "echo \"${SSH_CONNECTION%% *}\"").strip().splitlines()[-1]
        ufw_before = "ativo" if s.rodar("ufw status | grep -q 'Status: active'", sudo=True, checar=False)[0] == 0 else "inativo"
        dropin_existed = s.rodar(f"test -f {names.SSHD_DROPIN}", sudo=True, checar=False)[0] == 0

        undo = "#!/bin/bash\n# Gerado pelo configurador do Solumia: volta SSH e firewall ao estado anterior.\n"
        if not dropin_existed:
            undo += f"rm -f {names.SSHD_DROPIN}\n"
        undo += "sshd -t && (systemctl reload ssh 2>/dev/null || systemctl reload sshd)\n"
        if ufw_before == "inativo":
            undo += "ufw --force disable\n"
        undo += f"rm -f {names.FAIL2BAN_JAIL}; systemctl restart fail2ban 2>/dev/null\n"
        s.send(undo.encode(), names.UNDO_SCRIPT, 0o700)
        u = names.UNDO_UNIT
        rodar(ctx, f"systemctl stop {u}.timer 2>/dev/null; systemctl reset-failed {u}.service {u}.timer 2>/dev/null; "
                   f"systemd-run --quiet --unit={u} --on-active=300 /bin/bash {names.UNDO_SCRIPT}")
        ctx.log("Desfazer automático agendado para daqui a 5 min (cancelado só se o acesso novo funcionar)")

        rules = " ".join(f"ufw allow {p}/tcp >/dev/null;" for p in ports_ssh.split())
        rodar(ctx, f"{rules} ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; "
                   f"ufw allow {names.SSH_TUNNEL_PORT}/tcp >/dev/null; ufw default deny incoming >/dev/null; "
                   "ufw default allow outgoing >/dev/null; ufw --force enable >/dev/null")
        ctx.log(f"Firewall: SSH ({ports_ssh}), 80, 443 e {names.SSH_TUNNEL_PORT}; resto fechado")

        jail = (f"[DEFAULT]\nignoreip = 127.0.0.1/8 ::1 {my_ip}\nbantime = 1h\nfindtime = 10m\nmaxretry = 5\n\n"
                f"[sshd]\nenabled = true\nport = {','.join(ports_ssh.split())}\nbackend = systemd\n")
        s.send(jail.encode(), names.FAIL2BAN_JAIL, 0o644)
        rodar(ctx, "systemctl enable -q --now fail2ban && systemctl restart fail2ban")

        if options.desativar_login_por_senha:
            s.send(b"# Gerado pelo configurador do Solumia.\nPasswordAuthentication no\n"
                     b"KbdInteractiveAuthentication no\nPermitRootLogin prohibit-password\nMaxAuthTries 4\n",
                     names.SSHD_DROPIN, 0o644)
            if s.rodar("sshd -t", sudo=True, log=ctx.log, checar=False)[0]:
                rodar(ctx, f"rm -f {names.SSHD_DROPIN}")
                raise SSHError("sshd -t recusou a configuração: SSH mantido como estava")
            rodar(ctx, "systemctl reload ssh 2>/dev/null || systemctl reload sshd")
            ctx.log("SSH: só por chave (sessões abertas continuam)")

        rodar(ctx, "printf 'APT::Periodic::Update-Package-Lists \"1\";\\nAPT::Periodic::Unattended-Upgrade \"1\";\\n' "
                   "> /etc/apt/apt.conf.d/20auto-upgrades")

        ctx.log("Testando uma conexão SSH NOVA por chave…")
        try:
            new = Session(cred(True), ctx.recursos.get("_mascara", lambda x: x)).conectar()
            new.rodar(f"systemctl stop {u}.timer 2>/dev/null || sudo -n systemctl stop {u}.timer", checar=False)
            new.fechar()
        except SSHError as e:
            raise SSHError(f"a conexão nova falhou ({e}); em até 5 min a VPS desfaz SSH e firewall sozinha") from e
        ctx.log("Acesso confirmado: desfazer automático cancelado")

    # --- 10. final check ----------------------------------------------------------------------------
    def conferir(ctx: Context) -> None:
        for _ in range(10):
            cod, _ = sessao(ctx).rodar(f"curl -fsS https://{q(domain)}/health >/dev/null", checar=False)
            if cod == 0:
                ctx.log(f"https://{domain}/health ok")
                return
            time.sleep(3)
        raise SSHError(f"https://{domain}/health não respondeu (DNS/Cloudflare/firewall do provedor?)")

    steps = [
        Step("conectar", f"Conectar a {target}", "Confere a impressão digital da VPS antes de autenticar", conectar,
              sempre=True),
        Step("sistema", "Conferir sistema da VPS", "Ubuntu/Debian, arquitetura, disco e memória", sistema),
        Step("chave", "Instalar a chave SSH do configurador", "ed25519; a privada fica só no cofre", chave),
        Step("pacotes", "Instalar pacotes de base", packages_list, pacotes, pacotes_ok),
        Step("docker", "Instalar Docker", "repositório oficial da Docker", docker, docker_ok),
        Step("portas", "Conferir portas e escolher o modo do nginx",
              f"Solumia usa {names.GATEWAY_HOST_PORT}, {names.SSH_TUNNEL_PORT}, {names.PIPELINE_TUNNEL_HOST_PORT}, "
              f"{names.COLLABORA_HOST_PORT}", portas, sempre=True),
        Step("arquivos", f"Enviar código e configuração para {D}", "pacote conferido por SHA-256; .env em 0600", arquivos),
        Step("imagens", "Construir imagens", f"{names.GATEWAY_IMAGE}, {names.TUNNEL_IMAGE}; Collabora fixado por digest", imagens),
        Step("servicos", "Subir gateway, túnel e Collabora", f"projeto compose '{names.COMPOSE_PROJECT}'", servicos),
        Step("dns", f"Conferir DNS de {domain}", "o domínio precisa apontar para a VPS", dns),
        Step("tls", "nginx e certificado TLS", "Let's Encrypt; configuração validada antes de recarregar", tls),
        Step("endurecer", "Firewall, fail2ban e SSH só por chave",
              "com desfazer automático em 5 min se o acesso novo falhar"
              + ("" if options.desativar_login_por_senha else " (login por senha mantido)"), endurecer),
        Step("conferir", f"Conferir https://{domain}/health", "", conferir),
    ]
    return Plan(f"Instalar o Solumia na VPS {access.host}", steps)
