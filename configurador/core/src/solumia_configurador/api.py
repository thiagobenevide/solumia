"""Local API of the core, used only by the configurator interface.

Protection layers:
- listens only on 127.0.0.1, on a random port per session;
- session token (256 bits) required on every route, compared in constant time; the token is only
  handed to the interface through the standard output of the process the interface itself started;
- `Host` must be 127.0.0.1/localhost on the session port (blocks DNS rebinding);
- requests with an `Origin` header are refused: no browser talks to the core;
- vault values never leave through the API (only the names); VPS passwords stay in memory tied to a
  plan and are discarded when it finishes or expires;
- a destructive plan requires the account TOTP code to be applied;
- applying requires the `hash` of the plan shown: what runs is exactly what the person saw.
"""

from __future__ import annotations

import hmac
import secrets
import subprocess
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx
from fastapi import Body, Depends, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from . import (
    PROTOCOL_VERSION,
    VERSION,
    assistant,
    craft_apps,
    folders,
    generate,
    manifest,
    names,
    secret_store,
    self_update,
    solumia_apps,
    watch,
)
from .engine import Execucao, Mask, Plan, Step, list_runs
from .manifest import Folders, Manifest
from .platform_setup import System, default_media_folders, detect, dir_downloads, state_dir
from .roles import vps, worker
from .ssh import SSHError, read_server_fingerprint
from .vault import Vault, VaultError

_PLAN_VALIDITY = 15 * 60
_MAX_BODY = 1024 * 1024


@dataclass
class _StoredPlan:
    plano: Plan
    criado: float
    recursos: dict[str, Any] = field(default_factory=dict)


class State:
    def __init__(self, path_manifest: Path, vault: Vault, system: System | None = None) -> None:
        self.manifest_path = path_manifest
        self.cofre = vault
        self.sistema = system or detect()
        self.runs_dir = state_dir(self.sistema) / "registro"
        self.plans: dict[str, _StoredPlan] = {}
        self.executions: dict[str, Execucao] = {}
        self.lock = threading.Lock()
        self.mask = Mask(vault.sensitive_values)
        self.conversation = assistant.Conversation()

    def manifest(self) -> Manifest:
        if not self.manifest_path.exists():
            return Manifest()
        return manifest.load(self.manifest_path)

    def store_plan(self, plan: Plan, recursos: dict[str, Any] | None = None) -> dict[str, Any]:
        with self.lock:
            now = time.time()
            for pid in [p for p, g in self.plans.items() if now - g.criado > _PLAN_VALIDITY]:
                del self.plans[pid]
            self.plans[plan.id] = _StoredPlan(plan, now, recursos or {})
        return plan.summary()


class AccountInput(BaseModel):
    usuario: str = Field(min_length=3, max_length=32)
    senha: str = Field(min_length=1, max_length=256)


class FoldersInput(BaseModel):
    pastas: Folders
    windows: bool | None = None  # None = sistema deste host
    local: bool = True


class CraftInput(BaseModel):
    versao: str = "ultima"
    formato: str = "auto"


class SolumiaAppInput(BaseModel):
    versao: str = "ultima"
    instalar: bool = False


class WatchPairInput(BaseModel):
    host: str
    porta: int
    codigo: str


class WatchInstallInput(BaseModel):
    host: str
    porta: int | None = None  # found by the configurator when empty


class FingerprintInput(BaseModel):
    host: str
    porta: int = 22


class VPSInput(BaseModel):
    senha: str | None = Field(default=None, max_length=256)
    senha_sudo: str | None = Field(default=None, max_length=256)
    desativar_login_por_senha: bool = True
    nginx: str = Field(default="auto", pattern="^(auto|docker|host)$")


class QuestionInput(BaseModel):
    pergunta: str = Field(min_length=1, max_length=assistant.MAX_QUESTION)


class ApplyInput(BaseModel):
    hash: str
    totp: str | None = None


def create_app(state: State, token: str, porta: int) -> FastAPI:
    app = FastAPI(title="Solumia configurador (núcleo)", version=VERSION, docs_url=None, redoc_url=None,
                  openapi_url=None)
    hosts = {f"127.0.0.1:{porta}", f"localhost:{porta}"}

    @app.middleware("http")
    async def _guarda(request: Request, call_next):  # noqa: ANN001, ANN202
        if request.headers.get("host") not in hosts:
            return JSONResponse({"detail": "host recusado"}, status_code=421)
        if "origin" in request.headers:
            return JSONResponse({"detail": "origem recusada"}, status_code=403)
        size = request.headers.get("content-length")
        if size and int(size) > _MAX_BODY:
            return JSONResponse({"detail": "corpo grande demais"}, status_code=413)
        sent = request.headers.get("authorization", "")
        if not hmac.compare_digest(sent.encode(), f"Bearer {token}".encode()):
            return JSONResponse({"detail": "token inválido"}, status_code=401)
        answer = await call_next(request)
        answer.headers["Cache-Control"] = "no-store"
        return answer

    def e() -> State:
        return state

    # --- geral -----------------------------------------------------------------------------------
    @app.get("/saude")
    def saude(s: State = Depends(e)) -> dict[str, Any]:
        return {"versao": VERSION, "protocolo": PROTOCOL_VERSION, "so": s.sistema.so,
                "arquitetura": s.sistema.arquitetura, "manifesto": str(s.manifest_path),
                "nomes": {"prefixo": names.PREFIX, "porta_gateway": names.GATEWAY_HOST_PORT,
                          "porta_tunel": names.SSH_TUNNEL_PORT}}

    @app.get("/manifesto")
    def ler_manifesto(s: State = Depends(e)) -> dict[str, Any]:
        return s.manifest().model_dump(mode="json")

    @app.put("/manifesto")
    def gravar_manifesto(dados: dict[str, Any] = Body(...), s: State = Depends(e)) -> dict[str, Any]:
        try:
            m = Manifest.model_validate(dados)
        except ValueError as error:
            raise HTTPException(422, str(error)) from error
        manifest.save(m, s.manifest_path)
        return m.model_dump(mode="json")

    @app.get("/cofre")
    def cofre_nomes(s: State = Depends(e)) -> dict[str, Any]:
        return {"segredos": s.cofre.names()}

    # --- conta -----------------------------------------------------------------------------------
    @app.post("/conta")
    def conta(dados: AccountInput, s: State = Depends(e)) -> dict[str, Any]:
        problems = secret_store.check_password(dados.senha)
        if problems:
            raise HTTPException(422, "senha fraca: " + "; ".join(problems))
        m = s.manifest()
        m.conta.usuario = dados.usuario
        manifest.save(Manifest.model_validate(m.model_dump()), s.manifest_path)
        s.cofre.definir(secret_store.PASSWORD_HASH, secret_store.hash_password(dados.senha))
        new = not s.cofre.obter(secret_store.TOTP)
        answer: dict[str, Any] = {"usuario": dados.usuario, "totp_novo": new}
        if new:
            secret = secret_store.totp_secret()
            s.cofre.definir(secret_store.TOTP, secret)
            # The only time the TOTP secret leaves the core: for the Google Authenticator QR code.
            answer["totp_uri"] = secret_store.uri_totp(secret, dados.usuario)
        return answer

    @app.post("/conta/totp/conferir")
    def conferir_totp(codigo: str = Body(..., embed=True), s: State = Depends(e)) -> dict[str, bool]:
        return {"ok": secret_store.check_totp(s.cofre.obter(secret_store.TOTP) or "", codigo)}

    # --- media folders ------------------------------------------------------------------------------
    @app.get("/pastas/padrao")
    def pastas_padrao(s: State = Depends(e)) -> dict[str, Any]:
        return {"pastas": default_media_folders(s.sistema), "rotulos": folders.LABELS}

    @app.post("/pastas/validar")
    def validar_pastas(dados: FoldersInput, s: State = Depends(e)) -> dict[str, Any]:
        windows = s.sistema.windows if dados.windows is None else dados.windows
        r = folders.validate(dados.pastas, windows=windows, local=dados.local)
        return {"ok": r.ok, "erros": r.erros, "avisos": r.avisos, "resolvidas": r.resolvidas}

    @app.post("/pastas/{no}/plano")
    def plano_pastas(no: str, s: State = Depends(e)) -> dict[str, Any]:
        m = s.manifest()
        target = m.nos.get(no)
        if target is None or target.pastas is None:
            raise HTTPException(404, "nó sem pastas definidas")
        if target.endereco != "local":
            raise HTTPException(422, "pastas de nó remoto são criadas pela instalação do nó")
        r = folders.validate(target.pastas, windows=s.sistema.windows)
        if not r.ok:
            raise HTTPException(422, {"erros": r.erros})
        defined = target.pastas

        def criar(ctx) -> None:  # noqa: ANN001
            for c in folders.create(defined):
                ctx.log(f"Criada: {c}")

        return s.store_plan(Plan(f"Criar pastas de mídia do nó {no}", [
            Step("pastas", "Criar pastas de mídia que faltam", ", ".join(r.resolvidas.values()), criar)]))

    # --- configurator update ------------------------------------------------------------------------
    @app.post("/configurador/atualizar/plano")
    def plano_atualizar(s: State = Depends(e)) -> dict[str, Any]:
        try:
            return s.store_plan(self_update.plan(s.sistema))
        except ValueError as error:
            raise HTTPException(422, str(error)) from error

    # --- Craft Apps ----------------------------------------------------------------------------------
    @app.get("/craft-apps")
    def listar_craft(s: State = Depends(e)) -> dict[str, Any]:
        inst = craft_apps.instalados()
        m = s.manifest()
        return {"apps": [
            {"id": a.id, "nome": a.nome, "descricao": a.descricao, "github": a.url_github,
             "releases": a.url_releases, "instalado": inst.get(a.id),
             "config": (m.craft_apps.get(a.id) or manifest.CraftApp()).model_dump()}
            for a in craft_apps.CATALOG.values()
        ]}

    @app.get("/craft-apps/{app_id}/release")
    def release_craft(app_id: str, versao: str = "ultima", s: State = Depends(e)) -> dict[str, Any]:
        try:
            r = craft_apps.fetch_release(app_id, versao)
            file = craft_apps.file_name(app_id, r.versao, s.sistema)
        except craft_apps.CraftError as error:
            raise HTTPException(422, str(error)) from error
        return {"versao": r.versao, "publicada_em": r.publicada_em, "arquivo": file,
                "disponivel": file in r.arquivos}

    @app.post("/craft-apps/{app_id}/plano")
    def plano_craft(app_id: str, dados: CraftInput, s: State = Depends(e)) -> dict[str, Any]:
        if app_id not in craft_apps.CATALOG:
            raise HTTPException(404, "app fora do catálogo")
        app_c = craft_apps.CATALOG[app_id]

        def instalar(ctx) -> None:  # noqa: ANN001
            def progresso(read: int, total: int | None) -> None:
                if total and read == total or read % (50 << 20) < (1 << 20):
                    ctx.log(f"  {read >> 20} MiB" + (f" de {total >> 20} MiB" if total else ""))
            craft_apps.install(app_id, s.sistema, dados.versao, dados.formato, log=ctx.log, progresso=progresso)

        return s.store_plan(Plan(f"Baixar e instalar {app_c.nome}", [
            Step("instalar", f"Baixar {app_c.nome} de {app_c.url_releases}",
                  "assinatura (chave fixada) e SHA-256 conferidos antes de instalar", instalar)]))

    # --- Solumia apps (phone, watch, PC/laptop) --------------------------------------------------
    @app.get("/apps-solumia")
    def listar_apps_solumia(s: State = Depends(e)) -> dict[str, Any]:
        resp: dict[str, Any] = {
            "releases": solumia_apps.url_releases(),
            "assinatura_fixada": bool(solumia_apps.SOLUMIA_FINGERPRINTS),
            "pasta": str(dir_downloads(s.sistema)),
            "versao": None, "erro": None,
        }
        release = None
        try:
            release = solumia_apps.fetch()
            resp["versao"] = release.versao
        except (craft_apps.CraftError, httpx.HTTPError) as error:
            resp["erro"] = str(error)
        apps = []
        for a in solumia_apps.CATALOG.values():
            file = a.arquivo(release.versao) if release else None
            apps.append({"id": a.id, "dispositivo": a.dispositivo,
                         "instala_aqui": solumia_apps.installs_here(a, s.sistema), "arquivo": file,
                         "url": release.arquivos.get(file) if release and file else None})
        resp["apps"] = apps
        return resp

    @app.post("/apps-solumia/{app_id}/plano")
    def plano_app_solumia(app_id: str, dados: SolumiaAppInput, s: State = Depends(e)) -> dict[str, Any]:
        if app_id not in solumia_apps.CATALOG:
            raise HTTPException(404, "app fora do catálogo")
        a = solumia_apps.CATALOG[app_id]
        if dados.instalar and not solumia_apps.installs_here(a, s.sistema):
            raise HTTPException(422, "este app não é para este sistema")

        def baixar(ctx) -> None:  # noqa: ANN001
            def progresso(read: int, total: int | None) -> None:
                if total and read == total or read % (50 << 20) < (1 << 20):
                    ctx.log(f"  {read >> 20} MiB" + (f" de {total >> 20} MiB" if total else ""))
            solumia_apps.download(app_id, s.sistema, dados.versao, dados.instalar, log=ctx.log, progresso=progresso)

        action = "Baixar e instalar" if dados.instalar else "Baixar"
        return s.store_plan(Plan(f"{action} Solumia ({app_id})", [
            Step("baixar", f"{action} {a.modelo.format(v='X.Y.Z')} de {solumia_apps.url_releases()}",
                  f"assinatura (chave fixada) e SHA-256 conferidos; salvo em {dir_downloads(s.sistema)}", baixar)]))

    # --- watch (Wear OS over Wi-Fi) -------------------------------------------------------------------
    @app.post("/relogio/parear")
    def parear_relogio(dados: WatchPairInput) -> dict[str, bool]:
        try:
            watch.pair(dados.host, dados.porta, dados.codigo, log=lambda _line: None)
        except (watch.WatchError, OSError, subprocess.TimeoutExpired) as error:
            raise HTTPException(422, str(error)) from error
        return {"ok": True}

    @app.post("/relogio/plano")
    def plano_relogio(dados: WatchInstallInput, s: State = Depends(e)) -> dict[str, Any]:
        domain = s.manifest().topologia.dominio
        if not domain:
            raise HTTPException(422, "configure a VPS (domínio) antes de instalar o relógio")
        try:
            watch.check_address(dados.host, dados.porta or 1)
        except watch.WatchError as error:
            raise HTTPException(422, str(error)) from error
        url = f"https://{domain}"
        key = generate.watch_key(s.cofre)

        def conectar(ctx) -> None:  # noqa: ANN001
            ctx.recursos["relogio"] = watch.connect(dados.host, dados.porta, log=ctx.log)

        def conferir_chave(ctx) -> None:  # noqa: ANN001
            watch.check_key(url, key, log=ctx.log)

        def baixar(ctx) -> None:  # noqa: ANN001
            info = solumia_apps.download("wear", s.sistema, log=ctx.log)
            ctx.recursos["apk_relogio"] = info["caminho"]

        def instalar(ctx) -> None:  # noqa: ANN001
            watch.install(ctx.recursos["relogio"], Path(ctx.recursos["apk_relogio"]), url, key, log=ctx.log)

        return s.store_plan(Plan("Instalar o Solumia no relógio", [
            Step("conectar", f"Conectar ao relógio {dados.host}",
                 "adb por Wi-Fi; a porta de conexão é encontrada sozinha", conectar),
            Step("chave", f"Conferir a chave do relógio em {url}",
                 "chave própria do relógio: só abre as rotas dele", conferir_chave),
            Step("baixar", "Baixar o app do relógio da release",
                 "assinatura (chave fixada) e SHA-256 conferidos", baixar),
            Step("instalar", "Instalar e configurar no relógio",
                 "o app abre já com o endereço do servidor e a chave", instalar),
        ]))

    # --- VPS -----------------------------------------------------------------------------------------
    @app.post("/vps/impressao")
    def impressao(dados: FingerprintInput) -> dict[str, str]:
        try:
            manifest.SSHAccess(host=dados.host, porta=dados.porta)
            return read_server_fingerprint(dados.host, dados.porta)
        except (ValueError, OSError, SSHError) as error:
            raise HTTPException(422, f"não consegui ler a chave do servidor: {error}") from error

    @app.post("/vps/plano")
    def plano_vps(dados: VPSInput, s: State = Depends(e)) -> dict[str, Any]:
        options = vps.VPSOptions(dados.senha or None, dados.senha_sudo or None,
                               dados.desativar_login_por_senha, dados.nginx)
        try:
            p = vps.plan(s.manifest(), s.cofre, options)
        except (ValueError, VaultError) as error:
            raise HTTPException(422, str(error)) from error
        # The passwords of this request live only inside the plan (closures) and go away with it.
        return s.store_plan(p)

    # --- worker on this PC -----------------------------------------------------------------------
    @app.get("/worker")
    def estado_worker() -> dict[str, Any]:
        return worker.status()

    @app.post("/worker/plano")
    def plano_worker(s: State = Depends(e)) -> dict[str, Any]:
        try:
            p = worker.plan(s.manifest(), s.cofre, s.sistema)
        except (ValueError, VaultError) as error:
            raise HTTPException(422, str(error)) from error
        return s.store_plan(p)

    # --- Claude assistant --------------------------------------------------------------------------
    def contexto_assistente(s: State) -> str:
        return assistant.state_text(s.manifest(), s.cofre.names(), s.sistema, s.runs_dir, s.mask)

    @app.get("/assistente")
    def assistente(s: State = Depends(e)) -> dict[str, Any]:
        with s.conversation.lock:
            turns = list(s.conversation.turns)
        return {"disponivel": assistant.find_claude() is not None, "contexto": contexto_assistente(s),
                "historico": turns}

    @app.post("/assistente/perguntar")
    def perguntar(dados: QuestionInput, s: State = Depends(e)) -> dict[str, Any]:
        try:
            return assistant.answer(dados.pergunta, s.conversation, contexto_assistente(s), s.manifest(), s.mask)
        except assistant.AssistantError as error:
            raise HTTPException(502, str(error)) from error

    @app.post("/assistente/limpar")
    def limpar_assistente(s: State = Depends(e)) -> dict[str, bool]:
        s.conversation.clear()
        return {"ok": True}

    # --- apply -----------------------------------------------------------------------------------------

    @app.post("/planos/{plano_id}/aplicar")
    def aplicar(plano_id: str, dados: ApplyInput, s: State = Depends(e)) -> dict[str, Any]:
        with s.lock:
            stored = s.plans.pop(plano_id, None)
        if stored is None:
            raise HTTPException(404, "plano não encontrado ou expirado; gere de novo")
        if not hmac.compare_digest(stored.plano.hash, dados.hash):
            raise HTTPException(409, "o plano mudou desde que foi mostrado")
        if stored.plano.destrutivo and not secret_store.check_totp(s.cofre.obter(secret_store.TOTP) or "",
                                                                    dados.totp or ""):
            raise HTTPException(403, "ação destrutiva: confirme com o código do autenticador")
        if any(x.state == "rodando" for x in s.executions.values()):
            raise HTTPException(409, "já há uma aplicação em andamento")
        resources = {**stored.recursos, "_mascara": s.mask}
        ex = Execucao(stored.plano, s.runs_dir, s.mask, resources)
        s.executions[ex.id] = ex
        ex.iniciar()
        return ex.summary()

    @app.get("/execucoes/{exec_id}")
    def execucao(exec_id: str, desde: int = 0, s: State = Depends(e)) -> dict[str, Any]:
        ex = s.executions.get(exec_id)
        if ex is None:
            raise HTTPException(404, "execução não encontrada")
        return {**ex.summary(), "novos": ex.events_since(max(desde, 0))}

    @app.post("/execucoes/{exec_id}/cancelar")
    def cancelar(exec_id: str, s: State = Depends(e)) -> dict[str, str]:
        ex = s.executions.get(exec_id)
        if ex is None:
            raise HTTPException(404, "execução não encontrada")
        ex.cancel()
        return {"estado": "cancelando"}

    @app.get("/registro")
    def registro(s: State = Depends(e)) -> dict[str, Any]:
        return {"execucoes": list_runs(s.runs_dir)}

    return app


def new_token() -> str:
    return secrets.token_urlsafe(32)
