"""Sessões (abas) do módulo Código: `sessoes/<id>/meta.json`, as etapas em `eventos.jsonl` (uma
por linha, só acrescenta) e as imagens de referência em `imagens/`."""

import json
import re
import shutil
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


class SessaoNaoEncontrada(KeyError):
    pass


def _agora() -> str:
    return datetime.now(UTC).isoformat()


class Sessoes:
    def __init__(self, pasta: str | Path) -> None:
        self._raiz = Path(pasta).expanduser() / "sessoes"

    def _pasta(self, id_: str) -> Path:
        if not re.fullmatch(r"[0-9a-f]{32}", id_) or not (self._raiz / id_).is_dir():
            raise SessaoNaoEncontrada(id_)
        return self._raiz / id_

    def _gravar(self, meta: dict[str, Any]) -> dict[str, Any]:
        meta["atualizada"] = _agora()
        (self._raiz / meta["id"] / "meta.json").write_text(json.dumps(meta, ensure_ascii=False))
        return meta

    def listar(self) -> list[dict[str, Any]]:
        if not self._raiz.is_dir():
            return []
        metas = [json.loads(m.read_text()) for m in self._raiz.glob("*/meta.json")]
        return sorted(metas, key=lambda m: m["criada"])

    def criar(self, titulo: str = "") -> dict[str, Any]:
        id_ = uuid.uuid4().hex
        (self._raiz / id_ / "imagens").mkdir(parents=True)
        (self._raiz / id_ / "eventos.jsonl").touch()
        meta = {
            "id": id_,
            "titulo": titulo.strip() or "Nova aba",
            "criada": _agora(),
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

    def eventos(self, id_: str, desde: int = 0) -> list[dict[str, Any]]:
        linhas = (self._pasta(id_) / "eventos.jsonl").read_text().splitlines()
        return [json.loads(linha) for linha in linhas[desde:]]

    def adicionar(self, id_: str, evento: dict[str, Any]) -> dict[str, Any]:
        """Acrescenta a etapa e atualiza o estado da aba: `pedido` → rodando; `fim` → parada ou
        erro. Guarda a sessão do Claude Code para o próximo pedido continuar a conversa."""
        meta = self.obter(id_)
        evento = {"em": _agora(), **evento}
        with (self._pasta(id_) / "eventos.jsonl").open("a") as f:
            f.write(json.dumps(evento, ensure_ascii=False) + "\n")
        meta["eventos"] += 1
        if evento.get("claude_sessao"):
            meta["claude_sessao"] = evento["claude_sessao"]
        if evento["tipo"] == "pedido":
            meta["estado"] = "rodando"
        elif evento["tipo"] == "fim":
            meta["estado"] = "erro" if evento.get("erro") else "parada"
        return self._gravar(meta)

    def guardar_imagem(self, id_: str, nome: str, dados: bytes) -> str:
        nome = f"{len(list((self._pasta(id_) / 'imagens').iterdir())):03d}-" + (
            re.sub(r"[^A-Za-z0-9._-]", "_", nome)[-80:] or "imagem.png"
        )
        (self._pasta(id_) / "imagens" / nome).write_bytes(dados)
        return nome

    def caminho_imagem(self, id_: str, nome: str) -> Path:
        arq = self._pasta(id_) / "imagens" / nome
        if "/" in nome or nome.startswith(".") or not arq.is_file():
            raise SessaoNaoEncontrada(nome)
        return arq
