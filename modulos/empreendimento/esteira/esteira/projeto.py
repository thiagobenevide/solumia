"""Pasta de um projeto (episódio) e a configuração mesclada."""

import json
import os
import tomllib
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
# Dados pesados (episódios, acervo, cache) ficam fora do repositório: $AGENT_DATA/empreendimento.
DADOS = Path(os.environ.get("AGENT_DATA", "~/agent-data")).expanduser() / "empreendimento"
PROJETOS = DADOS / "projetos"
CACHE = DADOS / "cache"
AUDIO_EXT = (".wav", ".mp3", ".m4a", ".flac", ".ogg", ".aac")


def _mesclar(base, extra):
    for k, v in extra.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            _mesclar(base[k], v)
        else:
            base[k] = v
    return base


def carregar_env():
    env = {}
    arq = RAIZ / ".env"
    if arq.exists():
        for linha in arq.read_text().splitlines():
            if "=" in linha and not linha.lstrip().startswith("#"):
                k, v = linha.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def pasta_ep(ep):
    """Episódio "finlumia-003" → projetos/finlumia/003 (o canal é o que vem antes do primeiro "-")."""
    canal, _, resto = ep.partition("-")
    return PROJETOS / canal / resto if resto else PROJETOS / ep


def ep_id(pasta):
    """Inverso de pasta_ep: projetos/finlumia/003 → "finlumia-003"."""
    pasta = Path(pasta).resolve()
    return f"{pasta.parent.name}-{pasta.name}" if pasta.parent.parent == PROJETOS.resolve() else pasta.name


def episodios():
    """Pastas de todos os episódios (projetos/<canal>/<NNN>/), em ordem."""
    return sorted(p for p in PROJETOS.glob("*/*") if p.is_dir())


class Projeto:
    def __init__(self, pasta):
        self.pasta = Path(pasta).resolve()
        self.ep = ep_id(self.pasta)
        if not self.pasta.is_dir():
            raise SystemExit(f"pasta de projeto não encontrada: {self.pasta}")
        # config.toml geral ← perfis/<canal>.toml ← config.toml do projeto
        self.cfg = tomllib.loads((RAIZ / "config.toml").read_text())
        arq = self.pasta / "config.toml"
        local = tomllib.loads(arq.read_text()) if arq.exists() else {}
        self.canal = local.get("canal") or self.cfg.get("canal")
        perfil = RAIZ / "perfis" / f"{self.canal}.toml"
        if self.canal and perfil.exists():
            _mesclar(self.cfg, tomllib.loads(perfil.read_text()))
        _mesclar(self.cfg, local)
        if self.vertical:
            _mesclar(self.cfg, self.cfg.get("vertical", {}))
            _mesclar(self.cfg, local)
        self.env = carregar_env()
        (self.pasta / "midia").mkdir(exist_ok=True)

    @property
    def vertical(self):
        return self.cfg["video"].get("formato", "16:9") == "9:16"

    def audio(self):
        for nome in ("narracao", "audio", "narração"):
            for ext in AUDIO_EXT:
                p = self.pasta / f"{nome}{ext}"
                if p.exists():
                    return p
        achados = sorted(p for p in self.pasta.iterdir() if p.suffix.lower() in AUDIO_EXT)
        if not achados:
            raise SystemExit(f"nenhum áudio de narração em {self.pasta} (ex.: narracao.mp3)")
        return achados[0]

    def roteiro(self):
        for nome in ("roteiro.txt", "roteiro.md"):
            p = self.pasta / nome
            if p.exists():
                return p
        return None

    def caminho(self, nome):
        return self.pasta / nome

    def carregar_json(self, nome):
        p = self.pasta / nome
        if not p.exists():
            raise SystemExit(f"{nome} ainda não existe; rode a etapa anterior")
        return json.loads(p.read_text())

    def salvar_json(self, nome, dados):
        (self.pasta / nome).write_text(json.dumps(dados, ensure_ascii=False, indent=2))
