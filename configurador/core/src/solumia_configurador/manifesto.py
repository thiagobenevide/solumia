"""Manifesto `solumia.toml`: a descrição declarativa da instalação. Nunca guarda segredo.

Segredos (senhas, chaves, tokens) ficam no cofre e são referenciados aqui só pelo nome.
"""

from __future__ import annotations

import os
import re
import tomllib
from pathlib import Path
from typing import Literal

import tomli_w
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from . import nomes

ESQUEMA = 1

Papel = Literal["gateway", "worker", "tunnel", "collabora", "pipeline"]
_DOMINIO = re.compile(r"^(?=.{1,253}$)(?!-)([a-z0-9-]{1,63}(?<!-)\.)+[a-z]{2,63}$")
_HOST = re.compile(r"^[A-Za-z0-9.-]{1,253}$|^\[[0-9a-fA-F:]+\]$|^[0-9a-fA-F:]+$")
_USUARIO = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
_EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


class _Base(BaseModel):
    # Chave desconhecida é erro: um erro de digitação no TOML não pode passar calado.
    model_config = ConfigDict(extra="forbid")


class Conta(_Base):
    usuario: str = "admin"

    @field_validator("usuario")
    @classmethod
    def _usuario(cls, v: str) -> str:
        if not re.fullmatch(r"[A-Za-z0-9_.-]{3,32}", v):
            raise ValueError("usuário: 3 a 32 caracteres (letras, números, _ . -)")
        return v


class TopologiaLocal(_Base):
    acesso: Literal["lan", "tunel"] = "lan"


class Topologia(_Base):
    tipo: Literal["local", "hibrida", "nuvem"] = "hibrida"
    dominio: str = ""
    email_tls: str = ""  # avisos do Let's Encrypt
    cloudflare: bool = False
    local: TopologiaLocal = Field(default_factory=TopologiaLocal)

    @field_validator("dominio")
    @classmethod
    def _dominio(cls, v: str) -> str:
        v = v.strip().lower().rstrip(".")
        if v and not _DOMINIO.match(v):
            raise ValueError(f"domínio inválido: {v!r}")
        return v

    @field_validator("email_tls")
    @classmethod
    def _email(cls, v: str) -> str:
        v = v.strip()
        if v and not _EMAIL.match(v):
            raise ValueError("e-mail inválido")
        return v

    @model_validator(mode="after")
    def _exige_dominio(self) -> Topologia:
        if self.tipo in ("hibrida", "nuvem") and not self.dominio:
            raise ValueError("topologia híbrida ou nuvem exige um domínio")
        return self


class Pastas(_Base):
    """Pastas de mídia do nó (Linux ou Windows). Caminhos absolutos; `~` é aceito."""

    imagens: str = ""
    videos: str = ""
    audio: str = ""
    producao: str = ""  # vídeos para produção (entrada da esteira)
    produzidos: str = ""  # vídeos já produzidos (saída)


class AcessoSSH(_Base):
    usuario: str = "root"
    host: str = ""
    porta: int = 22
    # Impressão digital SHA256 da chave do servidor, confirmada pela pessoa no 1º acesso.
    impressao_host: str = ""

    @field_validator("usuario")
    @classmethod
    def _usuario(cls, v: str) -> str:
        if not _USUARIO.match(v):
            raise ValueError(f"usuário SSH inválido: {v!r}")
        return v

    @field_validator("host")
    @classmethod
    def _host(cls, v: str) -> str:
        v = v.strip()
        if v and not _HOST.match(v):
            raise ValueError(f"host inválido: {v!r}")
        return v

    @field_validator("porta")
    @classmethod
    def _porta(cls, v: int) -> int:
        if not 1 <= v <= 65535:
            raise ValueError("porta fora de 1–65535")
        return v


class No(_Base):
    endereco: Literal["local", "ssh"] = "local"
    ssh: AcessoSSH | None = None
    entrega: Literal["ssh", "pacote"] = "ssh"
    papeis: list[Papel] = Field(default_factory=list)
    dir_dados: str = ""
    pastas: Pastas | None = None

    @model_validator(mode="after")
    def _coerente(self) -> No:
        if self.endereco == "ssh" and (self.ssh is None or not self.ssh.host):
            raise ValueError("nó remoto precisa de [ssh] com host")
        if len(set(self.papeis)) != len(self.papeis):
            raise ValueError("papel repetido no mesmo nó")
        return self


class IALocal(_Base):
    ativa: bool = False
    gpu: str = "auto"
    modelos: list[str] = Field(default_factory=list)


class IANuvem(_Base):
    ativa: bool = False
    provedores: list[Literal["claude-code", "anthropic", "openai", "gemini", "xai", "deepseek"]] = Field(
        default_factory=list
    )
    escalonamento: Literal["local-primeiro", "nuvem-primeiro", "so-nuvem"] = "local-primeiro"


class IA(_Base):
    local: IALocal = Field(default_factory=IALocal)
    nuvem: IANuvem = Field(default_factory=IANuvem)


class CraftApp(_Base):
    instalar: bool = False
    versao: str = "ultima"  # "ultima" ou uma versão fixa como "0.20.1"
    formato: Literal["auto", "appimage", "deb", "tar.gz", "msi", "portatil"] = "auto"

    @field_validator("versao")
    @classmethod
    def _versao(cls, v: str) -> str:
        if v != "ultima" and not re.fullmatch(r"\d+\.\d+\.\d+", v):
            raise ValueError("versão: 'ultima' ou X.Y.Z")
        return v


class Backup(_Base):
    provedor: Literal["nenhum", "gdrive"] = "nenhum"
    agenda: Literal["diario", "semanal"] = "diario"


class Atualizacoes(_Base):
    canal: Literal["estavel", "beta"] = "estavel"
    origem: Literal["github", "propria"] = "github"


class Manifesto(_Base):
    esquema: int = ESQUEMA
    conta: Conta = Field(default_factory=Conta)
    topologia: Topologia = Field(default_factory=lambda: Topologia(tipo="local"))
    nos: dict[str, No] = Field(default_factory=dict)
    ia: IA = Field(default_factory=IA)
    modulos: list[str] = Field(default_factory=list)
    craft_apps: dict[str, CraftApp] = Field(default_factory=dict)
    backup: Backup = Field(default_factory=Backup)
    atualizacoes: Atualizacoes = Field(default_factory=Atualizacoes)

    @field_validator("esquema")
    @classmethod
    def _esquema(cls, v: int) -> int:
        if v != ESQUEMA:
            raise ValueError(f"esquema {v} não suportado (esperado {ESQUEMA})")
        return v

    @field_validator("nos")
    @classmethod
    def _nomes_nos(cls, v: dict[str, No]) -> dict[str, No]:
        for nome in v:
            if not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", nome):
                raise ValueError(f"nome de nó inválido: {nome!r}")
        return v

    @model_validator(mode="after")
    def _regras_de_papel(self) -> Manifesto:
        donos: dict[str, list[str]] = {}
        for nome, no in self.nos.items():
            for papel in no.papeis:
                donos.setdefault(papel, []).append(nome)
        for papel in ("gateway", "collabora", "pipeline"):
            if len(donos.get(papel, [])) > 1:
                raise ValueError(f"papel {papel!r} em mais de um nó: {donos[papel]}")
        # Rascunho (nós sem papéis, ex.: só as pastas salvas) é aceito; com papéis, o gateway é obrigatório.
        if donos and "gateway" not in donos:
            raise ValueError("nenhum nó tem o papel 'gateway'")
        gw, pl = donos.get("gateway", []), donos.get("pipeline", [])
        if "tunnel" in donos and not (gw and pl and gw != pl):
            raise ValueError("papel 'tunnel' só existe com gateway e pipeline em nós diferentes")
        if self.topologia.tipo == "nuvem" and self.ia.local.ativa:
            raise ValueError("topologia nuvem não tem GPU: IA local indisponível")
        if self.topologia.tipo == "nuvem" and pl:
            raise ValueError("topologia nuvem não suporta a esteira (pipeline)")
        return self

    def no_com(self, papel: str) -> tuple[str, No] | None:
        for nome, no in self.nos.items():
            if papel in no.papeis:
                return nome, no
        return None


def caminho_padrao() -> Path:
    from .plataforma import dir_config

    return dir_config() / nomes.ARQUIVO_MANIFESTO


def carregar(caminho: Path) -> Manifesto:
    with caminho.open("rb") as f:
        return Manifesto.model_validate(tomllib.load(f))


def salvar(manifesto: Manifesto, caminho: Path) -> None:
    """Escrita atômica: um arquivo pela metade nunca substitui o anterior."""
    caminho.parent.mkdir(parents=True, exist_ok=True)
    dados = manifesto.model_dump(mode="json", exclude_none=True)
    texto = "# Gerado pelo configurador do Solumia. Sem segredos: eles ficam no cofre.\n"
    texto += tomli_w.dumps(dados)
    temporario = caminho.with_suffix(".tmp")
    temporario.write_text(texto, encoding="utf-8")
    os.replace(temporario, caminho)
