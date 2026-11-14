"""API local do núcleo, usada só pela interface do configurador.

Camadas de proteção:
- escuta só em 127.0.0.1, em porta aleatória por sessão;
- token de sessão (256 bits) exigido em toda rota, comparado em tempo constante; o token só é
  entregue à interface pela saída padrão do processo que ela mesma iniciou;
- `Host` precisa ser 127.0.0.1/localhost na porta da sessão (bloqueia DNS rebinding);
- requisição com cabeçalho `Origin` é recusada: navegador nenhum fala com o núcleo;
- valores do cofre nunca saem pela API (só os nomes); senhas de VPS ficam em memória ligadas a um
  plano e são descartadas quando ele termina ou expira;
- plano destrutivo exige o código TOTP da conta para ser aplicado;
- a aplicação exige o `hash` do plano mostrado: o que roda é exatamente o que a pessoa viu.
"""

from __future__ import annotations

import hmac
import secrets
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx
from fastapi import Body, Depends, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from . import VERSAO, VERSAO_PROTOCOLO, craft_apps, folders, manifest, names, secret_store, solumia_apps
from .engine import Execucao, Mascara, Passo, Plano, listar_registro
from .manifest import Manifesto, Pastas
from .platform_setup import Sistema, detectar, dir_downloads, dir_estado, pastas_midia_padrao
from .roles import vps
from .ssh import SSHErro, ler_impressao_servidor
from .vault import Cofre, CofreErro

_VALIDADE_PLANO = 15 * 60
_CORPO_MAX = 1024 * 1024


@dataclass
class _PlanoGuardado:
    plano: Plano
    criado: float
    recursos: dict[str, Any] = field(default_factory=dict)


class Estado:
    def __init__(self, caminho_manifesto: Path, cofre: Cofre, sistema: Sistema | None = None) -> None:
        self.caminho_manifesto = caminho_manifesto
        self.cofre = cofre
        self.sistema = sistema or detectar()
        self.dir_registro = dir_estado(self.sistema) / "registro"
        self.planos: dict[str, _PlanoGuardado] = {}
        self.execucoes: dict[str, Execucao] = {}
        self.lock = threading.Lock()
        self.mascara = Mascara(cofre.valores_sensiveis)

    def manifesto(self) -> Manifesto:
        if not self.caminho_manifesto.exists():
            return Manifesto()
        return manifest.carregar(self.caminho_manifesto)

    def guardar_plano(self, plano: Plano, recursos: dict[str, Any] | None = None) -> dict[str, Any]:
        with self.lock:
            agora = time.time()
            for pid in [p for p, g in self.planos.items() if agora - g.criado > _VALIDADE_PLANO]:
                del self.planos[pid]
            self.planos[plano.id] = _PlanoGuardado(plano, agora, recursos or {})
        return plano.resumo()


class ContaEntrada(BaseModel):
    usuario: str = Field(min_length=3, max_length=32)
    senha: str = Field(min_length=1, max_length=256)


class PastasEntrada(BaseModel):
    pastas: Pastas
    windows: bool | None = None  # None = sistema deste host
    local: bool = True


class CraftEntrada(BaseModel):
    versao: str = "ultima"
    formato: str = "auto"


class AppSolumiaEntrada(BaseModel):
    versao: str = "ultima"
    instalar: bool = False


class ImpressaoEntrada(BaseModel):
    host: str
    porta: int = 22


class VPSEntrada(BaseModel):
    senha: str | None = Field(default=None, max_length=256)
    senha_sudo: str | None = Field(default=None, max_length=256)
    desativar_login_por_senha: bool = True
    nginx: str = Field(default="auto", pattern="^(auto|docker|host)$")


class AplicarEntrada(BaseModel):
    hash: str
    totp: str | None = None


def criar_app(estado: Estado, token: str, porta: int) -> FastAPI:
    app = FastAPI(title="Solumia configurador (núcleo)", version=VERSAO, docs_url=None, redoc_url=None,
                  openapi_url=None)
    hosts = {f"127.0.0.1:{porta}", f"localhost:{porta}"}

    @app.middleware("http")
    async def _guarda(request: Request, call_next):  # noqa: ANN001, ANN202
        if request.headers.get("host") not in hosts:
            return JSONResponse({"detail": "host recusado"}, status_code=421)
        if "origin" in request.headers:
            return JSONResponse({"detail": "origem recusada"}, status_code=403)
        tamanho = request.headers.get("content-length")
        if tamanho and int(tamanho) > _CORPO_MAX:
            return JSONResponse({"detail": "corpo grande demais"}, status_code=413)
        enviado = request.headers.get("authorization", "")
        if not hmac.compare_digest(enviado.encode(), f"Bearer {token}".encode()):
            return JSONResponse({"detail": "token inválido"}, status_code=401)
        resposta = await call_next(request)
        resposta.headers["Cache-Control"] = "no-store"
        return resposta

    def e() -> Estado:
        return estado

    # --- geral -----------------------------------------------------------------------------------
    @app.get("/saude")
    def saude(s: Estado = Depends(e)) -> dict[str, Any]:
        return {"versao": VERSAO, "protocolo": VERSAO_PROTOCOLO, "so": s.sistema.so,
                "arquitetura": s.sistema.arquitetura, "manifesto": str(s.caminho_manifesto),
                "nomes": {"prefixo": names.PREFIXO, "porta_gateway": names.PORTA_GATEWAY_HOST,
                          "porta_tunel": names.PORTA_TUNEL_SSH}}

    @app.get("/manifesto")
    def ler_manifesto(s: Estado = Depends(e)) -> dict[str, Any]:
        return s.manifesto().model_dump(mode="json")

    @app.put("/manifesto")
    def gravar_manifesto(dados: dict[str, Any] = Body(...), s: Estado = Depends(e)) -> dict[str, Any]:
        try:
            m = Manifesto.model_validate(dados)
        except ValueError as erro:
            raise HTTPException(422, str(erro)) from erro
        manifest.salvar(m, s.caminho_manifesto)
        return m.model_dump(mode="json")

    @app.get("/cofre")
    def cofre_nomes(s: Estado = Depends(e)) -> dict[str, Any]:
        return {"segredos": s.cofre.nomes()}

    # --- conta -----------------------------------------------------------------------------------
    @app.post("/conta")
    def conta(dados: ContaEntrada, s: Estado = Depends(e)) -> dict[str, Any]:
        problemas = secret_store.validar_senha(dados.senha)
        if problemas:
            raise HTTPException(422, "senha fraca: " + "; ".join(problemas))
        m = s.manifesto()
        m.conta.usuario = dados.usuario
        manifest.salvar(Manifesto.model_validate(m.model_dump()), s.caminho_manifesto)
        s.cofre.definir(secret_store.SENHA_HASH, secret_store.hash_senha(dados.senha))
        novo = not s.cofre.obter(secret_store.TOTP)
        resposta: dict[str, Any] = {"usuario": dados.usuario, "totp_novo": novo}
        if novo:
            segredo = secret_store.segredo_totp()
            s.cofre.definir(secret_store.TOTP, segredo)
            # Única vez em que o segredo TOTP sai do núcleo: para o QR do Google Authenticator.
            resposta["totp_uri"] = secret_store.uri_totp(segredo, dados.usuario)
        return resposta

    @app.post("/conta/totp/conferir")
    def conferir_totp(codigo: str = Body(..., embed=True), s: Estado = Depends(e)) -> dict[str, bool]:
        return {"ok": secret_store.conferir_totp(s.cofre.obter(secret_store.TOTP) or "", codigo)}

    # --- pastas de mídia ---------------------------------------------------------------------------
    @app.get("/pastas/padrao")
    def pastas_padrao(s: Estado = Depends(e)) -> dict[str, Any]:
        return {"pastas": pastas_midia_padrao(s.sistema), "rotulos": folders.ROTULOS}

    @app.post("/pastas/validar")
    def validar_pastas(dados: PastasEntrada, s: Estado = Depends(e)) -> dict[str, Any]:
        windows = s.sistema.windows if dados.windows is None else dados.windows
        r = folders.validar(dados.pastas, windows=windows, local=dados.local)
        return {"ok": r.ok, "erros": r.erros, "avisos": r.avisos, "resolvidas": r.resolvidas}

    @app.post("/pastas/{no}/plano")
    def plano_pastas(no: str, s: Estado = Depends(e)) -> dict[str, Any]:
        m = s.manifesto()
        alvo = m.nos.get(no)
        if alvo is None or alvo.pastas is None:
            raise HTTPException(404, "nó sem pastas definidas")
        if alvo.endereco != "local":
            raise HTTPException(422, "pastas de nó remoto são criadas pela instalação do nó")
        r = folders.validar(alvo.pastas, windows=s.sistema.windows)
        if not r.ok:
            raise HTTPException(422, {"erros": r.erros})
        definidas = alvo.pastas

        def criar(ctx) -> None:  # noqa: ANN001
            for c in folders.criar(definidas):
                ctx.log(f"Criada: {c}")

        return s.guardar_plano(Plano(f"Criar pastas de mídia do nó {no}", [
            Passo("pastas", "Criar pastas de mídia que faltam", ", ".join(r.resolvidas.values()), criar)]))

    # --- Craft Apps ----------------------------------------------------------------------------------
    @app.get("/craft-apps")
    def listar_craft(s: Estado = Depends(e)) -> dict[str, Any]:
        inst = craft_apps.instalados()
        m = s.manifesto()
        return {"apps": [
            {"id": a.id, "nome": a.nome, "descricao": a.descricao, "github": a.url_github,
             "releases": a.url_releases, "instalado": inst.get(a.id),
             "config": (m.craft_apps.get(a.id) or manifest.CraftApp()).model_dump()}
            for a in craft_apps.CATALOGO.values()
        ]}

    @app.get("/craft-apps/{app_id}/release")
    def release_craft(app_id: str, versao: str = "ultima", s: Estado = Depends(e)) -> dict[str, Any]:
        try:
            r = craft_apps.buscar_release(app_id, versao)
            arquivo = craft_apps.nome_arquivo(app_id, r.versao, s.sistema)
        except craft_apps.CraftErro as erro:
            raise HTTPException(422, str(erro)) from erro
        return {"versao": r.versao, "publicada_em": r.publicada_em, "arquivo": arquivo,
                "disponivel": arquivo in r.arquivos}

    @app.post("/craft-apps/{app_id}/plano")
    def plano_craft(app_id: str, dados: CraftEntrada, s: Estado = Depends(e)) -> dict[str, Any]:
        if app_id not in craft_apps.CATALOGO:
            raise HTTPException(404, "app fora do catálogo")
        app_c = craft_apps.CATALOGO[app_id]

        def instalar(ctx) -> None:  # noqa: ANN001
            def progresso(lido: int, total: int | None) -> None:
                if total and lido == total or lido % (50 << 20) < (1 << 20):
                    ctx.log(f"  {lido >> 20} MiB" + (f" de {total >> 20} MiB" if total else ""))
            craft_apps.instalar(app_id, s.sistema, dados.versao, dados.formato, log=ctx.log, progresso=progresso)

        return s.guardar_plano(Plano(f"Baixar e instalar {app_c.nome}", [
            Passo("instalar", f"Baixar {app_c.nome} de {app_c.url_releases}",
                  "assinatura (chave fixada) e SHA-256 conferidos antes de instalar", instalar)]))

    # --- Apps do Solumia (celular, relógio, PC/notebook) ------------------------------------------
    @app.get("/apps-solumia")
    def listar_apps_solumia(s: Estado = Depends(e)) -> dict[str, Any]:
        resp: dict[str, Any] = {
            "releases": solumia_apps.url_releases(),
            "assinatura_fixada": bool(solumia_apps.IMPRESSOES_SOLUMIA),
            "pasta": str(dir_downloads(s.sistema)),
            "versao": None, "erro": None,
        }
        release = None
        try:
            release = solumia_apps.buscar()
            resp["versao"] = release.versao
        except (craft_apps.CraftErro, httpx.HTTPError) as erro:
            resp["erro"] = str(erro)
        apps = []
        for a in solumia_apps.CATALOGO.values():
            arquivo = a.arquivo(release.versao) if release else None
            apps.append({"id": a.id, "dispositivo": a.dispositivo,
                         "instala_aqui": solumia_apps.instala_aqui(a, s.sistema), "arquivo": arquivo,
                         "url": release.arquivos.get(arquivo) if release and arquivo else None})
        resp["apps"] = apps
        return resp

    @app.post("/apps-solumia/{app_id}/plano")
    def plano_app_solumia(app_id: str, dados: AppSolumiaEntrada, s: Estado = Depends(e)) -> dict[str, Any]:
        if app_id not in solumia_apps.CATALOGO:
            raise HTTPException(404, "app fora do catálogo")
        a = solumia_apps.CATALOGO[app_id]
        if dados.instalar and not solumia_apps.instala_aqui(a, s.sistema):
            raise HTTPException(422, "este app não é para este sistema")

        def baixar(ctx) -> None:  # noqa: ANN001
            def progresso(lido: int, total: int | None) -> None:
                if total and lido == total or lido % (50 << 20) < (1 << 20):
                    ctx.log(f"  {lido >> 20} MiB" + (f" de {total >> 20} MiB" if total else ""))
            solumia_apps.baixar(app_id, s.sistema, dados.versao, dados.instalar, log=ctx.log, progresso=progresso)

        acao = "Baixar e instalar" if dados.instalar else "Baixar"
        return s.guardar_plano(Plano(f"{acao} Solumia ({app_id})", [
            Passo("baixar", f"{acao} {a.modelo.format(v='X.Y.Z')} de {solumia_apps.url_releases()}",
                  f"assinatura (chave fixada) e SHA-256 conferidos; salvo em {dir_downloads(s.sistema)}", baixar)]))

    # --- VPS -----------------------------------------------------------------------------------------
    @app.post("/vps/impressao")
    def impressao(dados: ImpressaoEntrada) -> dict[str, str]:
        try:
            manifest.AcessoSSH(host=dados.host, porta=dados.porta)
            return ler_impressao_servidor(dados.host, dados.porta)
        except (ValueError, OSError, SSHErro) as erro:
            raise HTTPException(422, f"não consegui ler a chave do servidor: {erro}") from erro

    @app.post("/vps/plano")
    def plano_vps(dados: VPSEntrada, s: Estado = Depends(e)) -> dict[str, Any]:
        opcoes = vps.OpcoesVPS(dados.senha or None, dados.senha_sudo or None,
                               dados.desativar_login_por_senha, dados.nginx)
        try:
            p = vps.plano(s.manifesto(), s.cofre, opcoes)
        except (ValueError, CofreErro) as erro:
            raise HTTPException(422, str(erro)) from erro
        # As senhas desta requisição vivem só dentro do plano (closures) e somem com ele.
        return s.guardar_plano(p)

    # --- aplicação ------------------------------------------------------------------------------------
    @app.post("/planos/{plano_id}/aplicar")
    def aplicar(plano_id: str, dados: AplicarEntrada, s: Estado = Depends(e)) -> dict[str, Any]:
        with s.lock:
            guardado = s.planos.pop(plano_id, None)
        if guardado is None:
            raise HTTPException(404, "plano não encontrado ou expirado; gere de novo")
        if not hmac.compare_digest(guardado.plano.hash, dados.hash):
            raise HTTPException(409, "o plano mudou desde que foi mostrado")
        if guardado.plano.destrutivo and not secret_store.conferir_totp(s.cofre.obter(secret_store.TOTP) or "",
                                                                    dados.totp or ""):
            raise HTTPException(403, "ação destrutiva: confirme com o código do autenticador")
        if any(x.estado == "rodando" for x in s.execucoes.values()):
            raise HTTPException(409, "já há uma aplicação em andamento")
        recursos = {**guardado.recursos, "_mascara": s.mascara}
        ex = Execucao(guardado.plano, s.dir_registro, s.mascara, recursos)
        s.execucoes[ex.id] = ex
        ex.iniciar()
        return ex.resumo()

    @app.get("/execucoes/{exec_id}")
    def execucao(exec_id: str, desde: int = 0, s: Estado = Depends(e)) -> dict[str, Any]:
        ex = s.execucoes.get(exec_id)
        if ex is None:
            raise HTTPException(404, "execução não encontrada")
        return {**ex.resumo(), "novos": ex.eventos_desde(max(desde, 0))}

    @app.post("/execucoes/{exec_id}/cancelar")
    def cancelar(exec_id: str, s: Estado = Depends(e)) -> dict[str, str]:
        ex = s.execucoes.get(exec_id)
        if ex is None:
            raise HTTPException(404, "execução não encontrada")
        ex.cancelar()
        return {"estado": "cancelando"}

    @app.get("/registro")
    def registro(s: Estado = Depends(e)) -> dict[str, Any]:
        return {"execucoes": listar_registro(s.dir_registro)}

    return app


def novo_token() -> str:
    return secrets.token_urlsafe(32)
