"""Instalação da VPS por SSH, sem terminal: gateway, túnel, Collabora, nginx, TLS e endurecimento.

Substitui `infra/scripts/instalar_vps` + `endurecer_vps` e convive com a instalação atual:
projeto compose `solumia`, portas e arquivos com prefixo `solumia` (ver `names.py`).

Proteções contra ficar trancado para fora (herdadas do endurecer_vps):
1. a chave do configurador é instalada e TESTADA antes de qualquer mudança no SSH;
2. antes de mexer em SSH/firewall, agenda na VPS um desfazer automático para daqui a 5 min;
3. a porta real do SSH é liberada no firewall antes de ligá-lo;
4. `sshd -t` antes do reload (sessões abertas não caem);
5. só cancela o desfazer depois que uma conexão NOVA, por chave, entra.
"""

from __future__ import annotations

import hashlib
import shlex
import time
from dataclasses import dataclass

from .. import generate, names, secret_store
from ..engine import Contexto, Passo, Plano
from ..manifest import Manifesto, No
from ..ssh import Credenciais, Sessao, SSHErro
from ..vault import Cofre

q = shlex.quote
D = names.DIR_VPS


@dataclass
class OpcoesVPS:
    senha: str | None = None  # 1º acesso; só em memória
    senha_sudo: str | None = None
    desativar_login_por_senha: bool = True
    nginx: str = "auto"  # auto | docker | host


def _no_gateway(m: Manifesto) -> tuple[str, No]:
    achado = m.no_com("gateway")
    if achado is None or achado[1].endereco != "ssh" or achado[1].ssh is None:
        raise ValueError("o gateway não está num nó remoto (VPS)")
    return achado


def plano(m: Manifesto, cofre: Cofre, opcoes: OpcoesVPS) -> Plano:
    nome_no, no = _no_gateway(m)
    acesso = no.ssh
    assert acesso is not None
    if not acesso.impressao_host:
        raise ValueError("confirme a impressão digital da VPS na tela VPS antes de instalar")
    if not m.topologia.dominio or not m.topologia.email_tls:
        raise ValueError("defina domínio e e-mail para o certificado TLS")
    for s in (secret_store.SENHA_HASH, secret_store.TOTP):
        cofre.exigir(s)  # conta criada antes (tela Conta)

    nome_chave = secret_store.SSH_CHAVE_PRIVADA.format(no=nome_no)
    dominio = m.topologia.dominio
    alvo = f"{acesso.usuario}@{acesso.host}:{acesso.porta}"

    def cred(com_chave: bool) -> Credenciais:
        return Credenciais(
            usuario=acesso.usuario, host=acesso.host, porta=acesso.porta, impressao_host=acesso.impressao_host,
            chave_privada=cofre.obter(nome_chave) if com_chave else None,
            senha=opcoes.senha, senha_sudo=opcoes.senha_sudo,
        )

    def sessao(ctx: Contexto) -> Sessao:
        s = ctx.recursos.get("ssh")
        if s is None:
            raise SSHErro("sem sessão SSH")
        return s

    def rodar(ctx: Contexto, cmd: str, **kw) -> str:  # noqa: ANN003
        return sessao(ctx).rodar(cmd, sudo=True, log=ctx.log, **kw)[1]

    # --- 1. conectar ----------------------------------------------------------------------------
    def conectar(ctx: Contexto) -> None:
        mascara = ctx.recursos.get("_mascara", lambda s: s)
        ctx.recursos["_fechar"] = lambda: ctx.recursos["ssh"].fechar() if ctx.recursos.get("ssh") else None
        if cofre.obter(nome_chave):
            try:
                ctx.recursos["ssh"] = Sessao(cred(True), mascara).conectar()
                ctx.log(f"Conectado a {alvo} com a chave do configurador")
                ctx.recursos["por_chave"] = True
                return
            except SSHErro as e:
                if not opcoes.senha:
                    raise
                ctx.log(f"Chave do configurador não entrou ({e}); tentando a senha")
        if not opcoes.senha:
            raise SSHErro("informe a senha da VPS para o primeiro acesso")
        ctx.recursos["ssh"] = Sessao(cred(False), mascara).conectar(usar_senha=True)
        ctx.recursos["por_chave"] = False
        ctx.log(f"Conectado a {alvo} com senha (só nesta execução; a senha não é gravada)")

    # --- 2. sistema -----------------------------------------------------------------------------
    def sistema(ctx: Contexto) -> None:
        saida = rodar(ctx, ". /etc/os-release; echo \"$ID|$VERSION_ID|$(uname -m)|$(df -BG --output=avail / | tail -1 | tr -dc 0-9)|$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)\"")
        so, versao, arq, disco, mem = saida.strip().splitlines()[-1].split("|")
        ctx.log(f"Sistema: {so} {versao} ({arq}), {disco} GB livres, {mem} MB de RAM")
        if so not in ("ubuntu", "debian"):
            raise SSHErro(f"sistema {so} não suportado (use Ubuntu 22.04+/Debian 12+)")
        if arq not in ("x86_64", "aarch64"):
            raise SSHErro(f"arquitetura {arq} não suportada")
        if int(disco or 0) < 10:
            raise SSHErro("menos de 10 GB livres no disco")
        if int(mem or 0) < 1800:
            ctx.log("AVISO: menos de 2 GB de RAM; o Collabora pode ficar lento")

    # --- 3. chave do configurador ---------------------------------------------------------------
    def chave(ctx: Contexto) -> None:
        privada = cofre.obter(nome_chave)
        if not privada:
            privada, publica = secret_store.gerar_chave_ssh()
            cofre.definir(nome_chave, privada)
            ctx.log("Chave ed25519 do configurador gerada (privada só no cofre)")
        publica = secret_store.publica_de(privada)
        s = sessao(ctx)
        # authorized_keys do usuário de login (não do root, se for outro).
        s.rodar(
            "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; "
            f"grep -qxF {q(publica)} ~/.ssh/authorized_keys || echo {q(publica)} >> ~/.ssh/authorized_keys",
            log=ctx.log,
        )
        teste = Sessao(cred(True), ctx.recursos.get("_mascara", lambda x: x)).conectar()
        teste.rodar("true")
        s.fechar()
        ctx.recursos["ssh"] = teste
        ctx.recursos["por_chave"] = True
        ctx.log("Acesso por chave confirmado; a partir daqui a senha não é mais usada")

    # --- 4. pacotes e Docker --------------------------------------------------------------------
    pacotes_lista = "curl ca-certificates ufw fail2ban unattended-upgrades openssh-client"

    def pacotes_ok(ctx: Contexto) -> bool:
        cod, _ = sessao(ctx).rodar(f"dpkg -s {pacotes_lista} >/dev/null 2>&1", sudo=True, checar=False)
        return cod == 0

    def pacotes(ctx: Contexto) -> None:
        rodar(ctx, f"export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq {pacotes_lista}")

    def docker_ok(ctx: Contexto) -> bool:
        cod, _ = sessao(ctx).rodar("docker compose version >/dev/null 2>&1", sudo=True, checar=False)
        return cod == 0

    def docker(ctx: Contexto) -> None:
        # Repositório oficial da Docker; o script é baixado para arquivo (não vai direto para o shell).
        rodar(ctx, "set -e; curl -fsSL https://get.docker.com -o /root/solumia-get-docker.sh; "
                   "sh /root/solumia-get-docker.sh; rm -f /root/solumia-get-docker.sh; "
                   "systemctl enable --now docker")

    # --- 5. portas e modo do nginx ----------------------------------------------------------------
    def portas(ctx: Contexto) -> None:
        saida = rodar(ctx, "ss -ltnpH 2>/dev/null || true")
        ocupadas: dict[int, str] = {}
        for linha in saida.splitlines():
            partes = linha.split()
            if len(partes) < 4:
                continue
            try:
                porta = int(partes[3].rsplit(":", 1)[1])
            except (IndexError, ValueError):
                continue
            ocupadas[porta] = linha
        nossas = rodar(ctx, f"docker ps --filter label=com.docker.compose.project={names.PROJETO_COMPOSE} -q | wc -l")
        ja_nosso = int((nossas.strip().splitlines() or ["0"])[-1]) > 0
        for p in (names.PORTA_GATEWAY_HOST, names.PORTA_TUNEL_SSH, names.PORTA_TUNEL_ESTEIRA_HOST,
                  names.PORTA_COLLABORA_HOST):
            if p in ocupadas and not ja_nosso:
                raise SSHErro(f"porta {p} já em uso na VPS: {ocupadas[p]}")
        nginx_host = sessao(ctx).rodar("systemctl is-active --quiet nginx", sudo=True, checar=False)[0] == 0
        web_ocupada = 80 in ocupadas or 443 in ocupadas
        modo = opcoes.nginx
        if modo == "auto":
            if nginx_host:
                modo = "host"
            elif not web_ocupada or (ja_nosso and "docker-proxy" in ocupadas.get(443, "")):
                modo = "docker"
            else:
                raise SSHErro(
                    "as portas 80/443 já estão em uso por outro serviço (provavelmente o nginx em contêiner "
                    "da instalação atual). Use uma VPS separada para o Solumia ou mude a atual para o modo "
                    f"nginx do host. Detalhe: {ocupadas.get(443) or ocupadas.get(80)}"
                )
        ctx.recursos["modo_nginx"] = modo
        ctx.log(f"nginx: modo {modo}")

    # --- 6. arquivos ------------------------------------------------------------------------------
    def arquivos(ctx: Contexto) -> None:
        s = sessao(ctx)
        modo = ctx.recursos["modo_nginx"]
        rodar(ctx, f"install -d -m 750 {D} {D}/nginx {D}/tunel")
        pacote = generate.pacote_fonte()
        soma = hashlib.sha256(pacote).hexdigest()
        s.enviar(pacote, f"{D}/fonte.tar.gz", 0o640)
        remota = rodar(ctx, f"sha256sum {D}/fonte.tar.gz | cut -d' ' -f1").strip().splitlines()[-1]
        if remota != soma:
            raise SSHErro("o pacote de código chegou corrompido na VPS")
        rodar(ctx, f"set -e; rm -rf {D}/fonte.novo; mkdir {D}/fonte.novo; "
                   f"tar -xzf {D}/fonte.tar.gz -C {D}/fonte.novo --no-same-owner; "
                   f"rm -rf {D}/fonte; mv {D}/fonte.novo {D}/fonte; rm -f {D}/fonte.tar.gz")
        ctx.log(f"Código enviado ({len(pacote) // 1024} KiB, SHA-256 {soma[:12]}… conferido)")

        privada_tunel = cofre.obter(secret_store.TUNEL_CHAVE_PRIVADA)
        if not privada_tunel:
            privada_tunel, _ = secret_store.gerar_chave_ssh()
            cofre.definir(secret_store.TUNEL_CHAVE_PRIVADA, privada_tunel)
        s.enviar(generate.compose(modo == "docker").encode(), f"{D}/compose.yml", 0o640)
        s.enviar(generate.env_gateway(m, cofre).encode(), f"{D}/gateway.env", 0o600)
        s.enviar(generate.authorized_keys_tunel(secret_store.publica_de(privada_tunel)).encode(),
                 f"{D}/tunel/authorized_keys", 0o644)
        s.enviar(generate.nginx_seguranca().encode(), f"{D}/nginx/seguranca-http.conf", 0o644)
        ctx.log("compose.yml, gateway.env (0600), chave do túnel e nginx enviados")

    # --- 7. imagens e serviços ------------------------------------------------------------------
    dc = f"docker compose -p {names.PROJETO_COMPOSE} --project-directory {D} -f {D}/compose.yml --env-file {D}/.env"

    def imagens(ctx: Contexto) -> None:
        # Versões fixas do Collabora e do certbot: o digest é gravado na 1ª vez (como o instalar_vps).
        cod, atual = sessao(ctx).rodar(f"cat {D}/imagens.env", sudo=True, checar=False)
        if cod != 0 or "COLLABORA_IMAGEM=" not in atual:
            linhas = []
            for var, img in (("COLLABORA_IMAGEM", "collabora/code:latest"), ("CERTBOT_IMAGEM", "certbot/certbot:latest")):
                rodar(ctx, f"docker pull -q {img}")
                digest = rodar(ctx, f"docker image inspect -f '{{{{index .RepoDigests 0}}}}' {img}").strip().splitlines()[-1]
                linhas.append(f"{var}={digest}")
            atual = "\n".join(linhas) + "\n"
            sessao(ctx).enviar(atual.encode(), f"{D}/imagens.env", 0o644)
        imgs = dict(linha.split("=", 1) for linha in atual.strip().splitlines() if "=" in linha)
        sessao(ctx).enviar(generate.env_compose(m, cofre, imgs).encode(), f"{D}/.env", 0o600)
        rodar(ctx, f"{dc} build -q gateway tunel", timeout=3600)
        ctx.log("Imagens construídas; Collabora e certbot fixados por digest")

    def servicos(ctx: Contexto) -> None:
        rodar(ctx, f"{dc} up -d --force-recreate --remove-orphans gateway tunel collabora")
        url = f"http://127.0.0.1:{names.PORTA_GATEWAY_HOST}/health"
        for _ in range(30):
            cod, _ = sessao(ctx).rodar(f"curl -fsS {url} >/dev/null", sudo=True, checar=False)
            if cod == 0:
                ctx.log("Gateway respondendo em 127.0.0.1")
                return
            time.sleep(2)
        rodar(ctx, f"{dc} logs --tail 40 gateway", checar=False)
        raise SSHErro("o gateway não respondeu ao /health")

    # --- 8. DNS e TLS ---------------------------------------------------------------------------
    def dns(ctx: Contexto) -> None:
        saida = rodar(ctx, f"echo \"$(curl -fsS4 --max-time 5 https://api.ipify.org || true)|$(getent ahostsv4 {q(dominio)} | awk 'NR==1{{print $1}}')\"")
        ip_vps, ip_dns = (saida.strip().splitlines()[-1].split("|") + [""])[:2]
        if not ip_dns:
            raise SSHErro(f"{dominio} não resolve no DNS. Crie um registro A apontando para {ip_vps or 'a VPS'}.")
        if ip_vps and ip_dns != ip_vps:
            if m.topologia.cloudflare:
                ctx.log(f"{dominio} → {ip_dns} (Cloudflare com proxy; VPS é {ip_vps})")
            else:
                raise SSHErro(f"{dominio} aponta para {ip_dns}, mas a VPS é {ip_vps}. Corrija o DNS.")
        else:
            ctx.log(f"DNS ok: {dominio} → {ip_dns}")

    def tls(ctx: Contexto) -> None:
        s = sessao(ctx)
        email = m.topologia.email_tls
        if ctx.recursos["modo_nginx"] == "docker":
            tem = s.rodar(f"{dc} run --rm --no-deps --entrypoint test certbot -f "
                          f"/etc/letsencrypt/live/{dominio}/fullchain.pem", sudo=True, checar=False)[0] == 0
            if not tem:
                s.enviar(generate.nginx_desafio(dominio).encode(), f"{D}/nginx/site.conf", 0o644)
                rodar(ctx, f"{dc} up -d nginx && {dc} restart nginx")
                rodar(ctx, f"{dc} run --rm --no-deps --entrypoint certbot certbot certonly --webroot "
                           f"-w /var/www/certbot -d {q(dominio)} --email {q(email)} --agree-tos "
                           "--non-interactive --no-eff-email", timeout=600)
            rodar(ctx, f"cp -f {D}/nginx/site.conf {D}/nginx/site.conf.anterior 2>/dev/null || true")
            s.enviar(generate.nginx_site_docker(dominio).encode(), f"{D}/nginx/site.conf", 0o644)
            if s.rodar(f"{dc} run --rm --no-deps --entrypoint nginx nginx -t -q", sudo=True, log=ctx.log, checar=False)[0]:
                rodar(ctx, f"mv -f {D}/nginx/site.conf.anterior {D}/nginx/site.conf")
                raise SSHErro("configuração nova do nginx inválida: mantida a anterior")
            rodar(ctx, f"{dc} up -d nginx certbot && {dc} restart nginx")
        else:
            site = f"/etc/nginx/sites-available/{names.SITE_NGINX.format(dominio=dominio)}"
            ativo = f"/etc/nginx/sites-enabled/{names.SITE_NGINX.format(dominio=dominio)}"
            seg = f"/etc/nginx/conf.d/{names.CONF_SEGURANCA_NGINX}"
            rodar(ctx, "dpkg -s python3-certbot-nginx >/dev/null 2>&1 || "
                       "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot python3-certbot-nginx")
            existia = s.rodar(f"test -f {site}", sudo=True, checar=False)[0] == 0
            if not existia:  # depois do certbot o arquivo ganha as linhas do TLS: só escrito na 1ª vez
                s.enviar(generate.nginx_site_host(dominio).encode(), site, 0o644)
            s.enviar(generate.nginx_seguranca().encode(), seg, 0o644)
            rodar(ctx, f"ln -sf {site} {ativo}")
            if s.rodar("nginx -t -q", sudo=True, log=ctx.log, checar=False)[0]:
                rodar(ctx, f"rm -f {seg} {ativo}" + ("" if existia else f" {site}"))
                raise SSHErro("configuração do nginx inválida: removida, o nginx segue como estava")
            rodar(ctx, "systemctl reload nginx")
            rodar(ctx, f"certbot --nginx -d {q(dominio)} -m {q(email)} --agree-tos --non-interactive "
                       "--no-eff-email --redirect --keep-until-expiring", timeout=600)
        ctx.log(f"TLS ativo para {dominio}")

    # --- 9. endurecimento (com desfazer automático) -----------------------------------------------
    def endurecer(ctx: Contexto) -> None:
        if not ctx.recursos.get("por_chave"):
            raise SSHErro("endurecimento exige sessão por chave (passo da chave não concluído)")
        s = sessao(ctx)
        portas_ssh = rodar(ctx, "sshd -T 2>/dev/null | awk '$1==\"port\"{print $2}' | sort -u | tr '\\n' ' '").strip()
        portas_ssh = portas_ssh.splitlines()[-1].strip() if portas_ssh else ""
        if not portas_ssh:
            raise SSHErro("não consegui ler a porta do SSH (sshd -T): nada foi alterado")
        meu_ip = rodar(ctx, "echo \"${SSH_CONNECTION%% *}\"").strip().splitlines()[-1]
        ufw_antes = "ativo" if s.rodar("ufw status | grep -q 'Status: active'", sudo=True, checar=False)[0] == 0 else "inativo"
        dropin_existia = s.rodar(f"test -f {names.SSHD_DROPIN}", sudo=True, checar=False)[0] == 0

        desfazer = "#!/bin/bash\n# Gerado pelo configurador do Solumia: volta SSH e firewall ao estado anterior.\n"
        if not dropin_existia:
            desfazer += f"rm -f {names.SSHD_DROPIN}\n"
        desfazer += "sshd -t && (systemctl reload ssh 2>/dev/null || systemctl reload sshd)\n"
        if ufw_antes == "inativo":
            desfazer += "ufw --force disable\n"
        desfazer += f"rm -f {names.FAIL2BAN_JAIL}; systemctl restart fail2ban 2>/dev/null\n"
        s.enviar(desfazer.encode(), names.SCRIPT_DESFAZER, 0o700)
        u = names.UNIDADE_DESFAZER
        rodar(ctx, f"systemctl stop {u}.timer 2>/dev/null; systemctl reset-failed {u}.service {u}.timer 2>/dev/null; "
                   f"systemd-run --quiet --unit={u} --on-active=300 /bin/bash {names.SCRIPT_DESFAZER}")
        ctx.log("Desfazer automático agendado para daqui a 5 min (cancelado só se o acesso novo funcionar)")

        regras = " ".join(f"ufw allow {p}/tcp >/dev/null;" for p in portas_ssh.split())
        rodar(ctx, f"{regras} ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; "
                   f"ufw allow {names.PORTA_TUNEL_SSH}/tcp >/dev/null; ufw default deny incoming >/dev/null; "
                   "ufw default allow outgoing >/dev/null; ufw --force enable >/dev/null")
        ctx.log(f"Firewall: SSH ({portas_ssh}), 80, 443 e {names.PORTA_TUNEL_SSH}; resto fechado")

        jail = (f"[DEFAULT]\nignoreip = 127.0.0.1/8 ::1 {meu_ip}\nbantime = 1h\nfindtime = 10m\nmaxretry = 5\n\n"
                f"[sshd]\nenabled = true\nport = {','.join(portas_ssh.split())}\nbackend = systemd\n")
        s.enviar(jail.encode(), names.FAIL2BAN_JAIL, 0o644)
        rodar(ctx, "systemctl enable -q --now fail2ban && systemctl restart fail2ban")

        if opcoes.desativar_login_por_senha:
            s.enviar(b"# Gerado pelo configurador do Solumia.\nPasswordAuthentication no\n"
                     b"KbdInteractiveAuthentication no\nPermitRootLogin prohibit-password\nMaxAuthTries 4\n",
                     names.SSHD_DROPIN, 0o644)
            if s.rodar("sshd -t", sudo=True, log=ctx.log, checar=False)[0]:
                rodar(ctx, f"rm -f {names.SSHD_DROPIN}")
                raise SSHErro("sshd -t recusou a configuração: SSH mantido como estava")
            rodar(ctx, "systemctl reload ssh 2>/dev/null || systemctl reload sshd")
            ctx.log("SSH: só por chave (sessões abertas continuam)")

        rodar(ctx, "printf 'APT::Periodic::Update-Package-Lists \"1\";\\nAPT::Periodic::Unattended-Upgrade \"1\";\\n' "
                   "> /etc/apt/apt.conf.d/20auto-upgrades")

        ctx.log("Testando uma conexão SSH NOVA por chave…")
        try:
            nova = Sessao(cred(True), ctx.recursos.get("_mascara", lambda x: x)).conectar()
            nova.rodar(f"systemctl stop {u}.timer 2>/dev/null || sudo -n systemctl stop {u}.timer", checar=False)
            nova.fechar()
        except SSHErro as e:
            raise SSHErro(f"a conexão nova falhou ({e}); em até 5 min a VPS desfaz SSH e firewall sozinha") from e
        ctx.log("Acesso confirmado: desfazer automático cancelado")

    # --- 10. conferência final ----------------------------------------------------------------------
    def conferir(ctx: Contexto) -> None:
        for _ in range(10):
            cod, _ = sessao(ctx).rodar(f"curl -fsS https://{q(dominio)}/health >/dev/null", checar=False)
            if cod == 0:
                ctx.log(f"https://{dominio}/health ok")
                return
            time.sleep(3)
        raise SSHErro(f"https://{dominio}/health não respondeu (DNS/Cloudflare/firewall do provedor?)")

    passos = [
        Passo("conectar", f"Conectar a {alvo}", "Confere a impressão digital da VPS antes de autenticar", conectar,
              sempre=True),
        Passo("sistema", "Conferir sistema da VPS", "Ubuntu/Debian, arquitetura, disco e memória", sistema),
        Passo("chave", "Instalar a chave SSH do configurador", "ed25519; a privada fica só no cofre", chave),
        Passo("pacotes", "Instalar pacotes de base", pacotes_lista, pacotes, pacotes_ok),
        Passo("docker", "Instalar Docker", "repositório oficial da Docker", docker, docker_ok),
        Passo("portas", "Conferir portas e escolher o modo do nginx",
              f"Solumia usa {names.PORTA_GATEWAY_HOST}, {names.PORTA_TUNEL_SSH}, {names.PORTA_TUNEL_ESTEIRA_HOST}, "
              f"{names.PORTA_COLLABORA_HOST}", portas, sempre=True),
        Passo("arquivos", f"Enviar código e configuração para {D}", "pacote conferido por SHA-256; .env em 0600", arquivos),
        Passo("imagens", "Construir imagens", f"{names.IMAGEM_GATEWAY}, {names.IMAGEM_TUNEL}; Collabora fixado por digest", imagens),
        Passo("servicos", "Subir gateway, túnel e Collabora", f"projeto compose '{names.PROJETO_COMPOSE}'", servicos),
        Passo("dns", f"Conferir DNS de {dominio}", "o domínio precisa apontar para a VPS", dns),
        Passo("tls", "nginx e certificado TLS", "Let's Encrypt; configuração validada antes de recarregar", tls),
        Passo("endurecer", "Firewall, fail2ban e SSH só por chave",
              "com desfazer automático em 5 min se o acesso novo falhar"
              + ("" if opcoes.desativar_login_por_senha else " (login por senha mantido)"), endurecer),
        Passo("conferir", f"Conferir https://{dominio}/health", "", conferir),
    ]
    return Plano(f"Instalar o Solumia na VPS {acesso.host}", passos)
