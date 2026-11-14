"""Pasta de um projeto (episódio) e a configuração mesclada."""

import json
import os
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Dados pesados (episódios, acervo, cache) ficam fora do repositório: $AGENT_DATA/empreendimento.
DATA = Path(os.environ.get("AGENT_DATA", "~/agent-data")).expanduser() / "empreendimento"
PROJECTS = DATA / "projetos"
CACHE = DATA / "cache"
AUDIO_EXT = (".wav", ".mp3", ".m4a", ".flac", ".ogg", ".aac")


def _merge(base, extra):
    for k, v in extra.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            _merge(base[k], v)
        else:
            base[k] = v
    return base


def load_env():
    env = {}
    file = ROOT / ".env"
    if file.exists():
        for line in file.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def folder_ep(ep):
    """Episódio "finlumia-003" → projetos/finlumia/003 (o canal é o que vem antes do primeiro "-")."""
    channel, _, rest = ep.partition("-")
    return PROJECTS / channel / rest if rest else PROJECTS / ep


def ep_id(folder):
    """Inverso de pasta_ep: projetos/finlumia/003 → "finlumia-003"."""
    folder = Path(folder).resolve()
    return f"{folder.parent.name}-{folder.name}" if folder.parent.parent == PROJECTS.resolve() else folder.name


def episodes():
    """Pastas de todos os episódios (projetos/<canal>/<NNN>/), em ordem."""
    return sorted(p for p in PROJECTS.glob("*/*") if p.is_dir())


class Project:
    def __init__(self, folder):
        self.folder_path = Path(folder).resolve()
        self.ep = ep_id(self.folder_path)
        if not self.folder_path.is_dir():
            raise SystemExit(f"pasta de projeto não encontrada: {self.folder_path}")
        # config.toml geral ← perfis/<canal>.toml ← config.toml do projeto
        self.cfg = tomllib.loads((ROOT / "config.toml").read_text())
        file = self.folder_path / "config.toml"
        local = tomllib.loads(file.read_text()) if file.exists() else {}
        self.canal = local.get("canal") or self.cfg.get("canal")
        profile = ROOT / "perfis" / f"{self.canal}.toml"
        if self.canal and profile.exists():
            _merge(self.cfg, tomllib.loads(profile.read_text()))
        _merge(self.cfg, local)
        if self.vertical:
            _merge(self.cfg, self.cfg.get("vertical", {}))
            _merge(self.cfg, local)
        self.env = load_env()
        (self.folder_path / "midia").mkdir(exist_ok=True)

    @property
    def vertical(self):
        return self.cfg["video"].get("formato", "16:9") == "9:16"

    def audio(self):
        for name in ("narracao", "audio", "narração"):
            for ext in AUDIO_EXT:
                p = self.folder_path / f"{name}{ext}"
                if p.exists():
                    return p
        found = sorted(p for p in self.folder_path.iterdir() if p.suffix.lower() in AUDIO_EXT)
        if not found:
            raise SystemExit(f"nenhum áudio de narração em {self.folder_path} (ex.: narracao.mp3)")
        return found[0]

    def script_path(self):
        for name in ("roteiro.txt", "roteiro.md"):
            p = self.folder_path / name
            if p.exists():
                return p
        return None

    def path_of(self, name):
        return self.folder_path / name

    def load_json(self, name):
        p = self.folder_path / name
        if not p.exists():
            raise SystemExit(f"{name} ainda não existe; rode a etapa anterior")
        return json.loads(p.read_text())

    def save_json(self, name, data):
        (self.folder_path / name).write_text(json.dumps(data, ensure_ascii=False, indent=2))
