"""Sessões (abas) do módulo Código: `sessoes/<id>/meta.json`, as etapas em `eventos.jsonl` (uma
por linha, só acrescenta) e as imagens de referência em `imagens/`."""

import json
import re
import shutil
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


class SessionNotFound(KeyError):
    pass


def _now() -> str:
    return datetime.now(UTC).isoformat()


class Sessions:
    def __init__(self, pasta: str | Path) -> None:
        self._raiz = Path(pasta).expanduser() / "sessoes"

    def _pasta(self, id_: str) -> Path:
        if not re.fullmatch(r"[0-9a-f]{32}", id_) or not (self._raiz / id_).is_dir():
            raise SessionNotFound(id_)
        return self._raiz / id_

    def _gravar(self, meta: dict[str, Any]) -> dict[str, Any]:
        meta["atualizada"] = _now()
        (self._raiz / meta["id"] / "meta.json").write_text(json.dumps(meta, ensure_ascii=False))
        return meta

    def listar(self) -> list[dict[str, Any]]:
        if not self._raiz.is_dir():
            return []
        goals = [json.loads(m.read_text()) for m in self._raiz.glob("*/meta.json")]
        return sorted(goals, key=lambda m: m["criada"])

    def criar(self, titulo: str = "") -> dict[str, Any]:
        id_ = uuid.uuid4().hex
        (self._raiz / id_ / "imagens").mkdir(parents=True)
        (self._raiz / id_ / "eventos.jsonl").touch()
        meta = {
            "id": id_,
            "titulo": titulo.strip() or "Nova aba",
            "criada": _now(),
            "estado": "parada",
            "claude_sessao": None,
            "eventos": 0,
        }
        return self._gravar(meta)

    def obter(self, id_: str) -> dict[str, Any]:
        meta: dict[str, Any] = json.loads((self._pasta(id_) / "meta.json").read_text())
        return meta

    def editar(self, id_: str, titulo: str) -> dict[str, Any]:
        meta = self.obter(id_)
        meta["titulo"] = titulo.strip() or meta["titulo"]
        return self._gravar(meta)

    def excluir(self, id_: str) -> None:
        shutil.rmtree(self._pasta(id_))

    def eventos(self, id_: str, since: int = 0) -> list[dict[str, Any]]:
        lines = (self._pasta(id_) / "eventos.jsonl").read_text().splitlines()
        return [json.loads(line) for line in lines[since:]]

    def adicionar(self, id_: str, event: dict[str, Any]) -> dict[str, Any]:
        """Acrescenta a etapa e atualiza o estado da aba: `pedido` → rodando; `fim` → parada ou
        erro. Guarda a sessão do Claude Code para o próximo pedido continuar a conversa."""
        meta = self.obter(id_)
        event = {"em": _now(), **event}
        with (self._pasta(id_) / "eventos.jsonl").open("a") as f:
            f.write(json.dumps(event, ensure_ascii=False) + "\n")
        meta["eventos"] += 1
        if event.get("claude_sessao"):
            meta["claude_sessao"] = event["claude_sessao"]
        if event["tipo"] == "pedido":
            meta["estado"] = "rodando"
        elif event["tipo"] == "fim":
            meta["estado"] = "erro" if event.get("erro") else "parada"
        return self._gravar(meta)

    def guardar_imagem(self, id_: str, nome: str, dados: bytes) -> str:
        nome = f"{len(list((self._pasta(id_) / 'imagens').iterdir())):03d}-" + (
            re.sub(r"[^A-Za-z0-9._-]", "_", nome)[-80:] or "imagem.png"
        )
        (self._pasta(id_) / "imagens" / nome).write_bytes(dados)
        return nome

    def caminho_imagem(self, id_: str, nome: str) -> Path:
        file = self._pasta(id_) / "imagens" / nome
        if "/" in nome or nome.startswith(".") or not file.is_file():
            raise SessionNotFound(nome)
        return file
