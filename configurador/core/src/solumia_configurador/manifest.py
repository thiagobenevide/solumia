"""Manifest `solumia.toml`: the declarative description of the installation. Never holds secrets.

Secrets (passwords, keys, tokens) live in the vault and are referenced here only by name.
"""

from __future__ import annotations

import os
import re
import tomllib
from pathlib import Path
from typing import Literal

import tomli_w
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from . import names

SCHEMA = 1

Role = Literal["gateway", "worker", "tunnel", "collabora", "pipeline"]
_DOMAIN = re.compile(r"^(?=.{1,253}$)(?!-)([a-z0-9-]{1,63}(?<!-)\.)+[a-z]{2,63}$")
_HOST = re.compile(r"^[A-Za-z0-9.-]{1,253}$|^\[[0-9a-fA-F:]+\]$|^[0-9a-fA-F:]+$")
_USER = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
_EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


class _Base(BaseModel):
    # An unknown key is an error: a typo in the TOML must not pass silently.
    model_config = ConfigDict(extra="forbid")


class Account(_Base):
    usuario: str = "admin"

    @field_validator("usuario")
    @classmethod
    def _user(cls, v: str) -> str:
        if not re.fullmatch(r"[A-Za-z0-9_.-]{3,32}", v):
            raise ValueError("usuário: 3 a 32 caracteres (letras, números, _ . -)")
        return v


class TopologiaLocal(_Base):
    acesso: Literal["lan", "tunel"] = "lan"


class Topologia(_Base):
    tipo: Literal["local", "hibrida", "nuvem"] = "hibrida"
    dominio: str = ""
    email_tls: str = ""  # Let's Encrypt notices
    cloudflare: bool = False
    local: TopologiaLocal = Field(default_factory=TopologiaLocal)

    @field_validator("dominio")
    @classmethod
    def _domain(cls, v: str) -> str:
        v = v.strip().lower().rstrip(".")
        if v and not _DOMAIN.match(v):
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
    def _requires_domain(self) -> Topologia:
        if self.tipo in ("hibrida", "nuvem") and not self.dominio:
            raise ValueError("topologia híbrida ou nuvem exige um domínio")
        return self


class Folders(_Base):
    """Media folders of the node (Linux or Windows). Absolute paths; `~` is accepted."""

    imagens: str = ""
    videos: str = ""
    audio: str = ""
    producao: str = ""  # videos to produce (pipeline input)
    produzidos: str = ""  # videos already produced (output)


class SSHAccess(_Base):
    usuario: str = "root"
    host: str = ""
    porta: int = 22
    # SHA256 fingerprint of the server key, confirmed by the person on first access.
    impressao_host: str = ""

    @field_validator("usuario")
    @classmethod
    def _user(cls, v: str) -> str:
        if not _USER.match(v):
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
    def _port(cls, v: int) -> int:
        if not 1 <= v <= 65535:
            raise ValueError("porta fora de 1–65535")
        return v


class Node(_Base):
    endereco: Literal["local", "ssh"] = "local"
    ssh: SSHAccess | None = None
    entrega: Literal["ssh", "pacote"] = "ssh"
    papeis: list[Role] = Field(default_factory=list)
    dir_dados: str = ""
    pastas: Folders | None = None

    @model_validator(mode="after")
    def _coherent(self) -> Node:
        if self.endereco == "ssh" and (self.ssh is None or not self.ssh.host):
            raise ValueError("nó remoto precisa de [ssh] com host")
        if len(set(self.papeis)) != len(self.papeis):
            raise ValueError("papel repetido no mesmo nó")
        return self


class LocalAi(_Base):
    ativa: bool = False
    gpu: str = "auto"
    modelos: list[str] = Field(default_factory=list)


class CloudAi(_Base):
    ativa: bool = False
    provedores: list[Literal["claude-code", "anthropic", "openai", "gemini", "xai", "deepseek"]] = Field(
        default_factory=list
    )
    escalonamento: Literal["local-primeiro", "nuvem-primeiro", "so-nuvem"] = "local-primeiro"


class IA(_Base):
    local: LocalAi = Field(default_factory=LocalAi)
    nuvem: CloudAi = Field(default_factory=CloudAi)


class CraftApp(_Base):
    instalar: bool = False
    versao: str = "ultima"  # "ultima" (latest) or a pinned version such as "0.20.1"
    formato: Literal["auto", "appimage", "deb", "tar.gz", "msi", "portatil"] = "auto"

    @field_validator("versao")
    @classmethod
    def _version(cls, v: str) -> str:
        if v != "ultima" and not re.fullmatch(r"\d+\.\d+\.\d+", v):
            raise ValueError("versão: 'ultima' ou X.Y.Z")
        return v


class Backup(_Base):
    provedor: Literal["nenhum", "gdrive"] = "nenhum"
    agenda: Literal["diario", "semanal"] = "diario"


class Atualizacoes(_Base):
    canal: Literal["estavel", "beta"] = "estavel"
    origem: Literal["github", "propria"] = "github"


class Manifest(_Base):
    esquema: int = SCHEMA
    conta: Account = Field(default_factory=Account)
    topologia: Topologia = Field(default_factory=lambda: Topologia(tipo="local"))
    nos: dict[str, Node] = Field(default_factory=dict)
    ia: IA = Field(default_factory=IA)
    modulos: list[str] = Field(default_factory=list)
    craft_apps: dict[str, CraftApp] = Field(default_factory=dict)
    backup: Backup = Field(default_factory=Backup)
    atualizacoes: Atualizacoes = Field(default_factory=Atualizacoes)

    @field_validator("esquema")
    @classmethod
    def _schema(cls, v: int) -> int:
        if v != SCHEMA:
            raise ValueError(f"esquema {v} não suportado (esperado {SCHEMA})")
        return v

    @field_validator("nos")
    @classmethod
    def _node_names(cls, v: dict[str, Node]) -> dict[str, Node]:
        for name in v:
            if not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", name):
                raise ValueError(f"nome de nó inválido: {name!r}")
        return v

    @model_validator(mode="after")
    def _role_rules(self) -> Manifest:
        owners: dict[str, list[str]] = {}
        for name, no in self.nos.items():
            for role in no.papeis:
                owners.setdefault(role, []).append(name)
        for role in ("gateway", "collabora", "pipeline"):
            if len(owners.get(role, [])) > 1:
                raise ValueError(f"papel {role!r} em mais de um nó: {owners[role]}")
        # A draft (nodes without roles, e.g. only the saved folders) is accepted; with roles, the gateway is required.
        if owners and "gateway" not in owners:
            raise ValueError("nenhum nó tem o papel 'gateway'")
        gw, pl = owners.get("gateway", []), owners.get("pipeline", [])
        if "tunnel" in owners and not (gw and pl and gw != pl):
            raise ValueError("papel 'tunnel' só existe com gateway e pipeline em nós diferentes")
        if self.topologia.tipo == "nuvem" and self.ia.local.ativa:
            raise ValueError("topologia nuvem não tem GPU: IA local indisponível")
        if self.topologia.tipo == "nuvem" and pl:
            raise ValueError("topologia nuvem não suporta a esteira (pipeline)")
        return self

    def node_with(self, role: str) -> tuple[str, Node] | None:
        for name, no in self.nos.items():
            if role in no.papeis:
                return name, no
        return None


def default_path() -> Path:
    from .platform_setup import dir_config

    return dir_config() / names.MANIFEST_FILE


def load(path: Path) -> Manifest:
    with path.open("rb") as f:
        return Manifest.model_validate(tomllib.load(f))


def save(manifest: Manifest, path: Path) -> None:
    """Atomic write: a half-written file never replaces the previous one."""
    path.parent.mkdir(parents=True, exist_ok=True)
    data = manifest.model_dump(mode="json", exclude_none=True)
    text = "# Gerado pelo configurador do Solumia. Sem segredos: eles ficam no cofre.\n"
    text += tomli_w.dumps(data)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(text, encoding="utf-8")
    os.replace(temporary, path)
