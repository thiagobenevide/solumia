"""Treinos guardados em JSON na pasta de dados: `exercicios.json` (catálogo base + os criados pelo
usuário), `agenda.json` (exercícios marcados em cada dia, com séries, carga e se foi feito) e
`imagens/` (fotos enviadas e o cache das imagens do free-exercise-db)."""

import json
import os
import re
import threading
import unicodedata
import urllib.request
import uuid
from datetime import date
from pathlib import Path
from typing import Any

from saude.catalogo import URL_IMAGENS, exercicios_base

CAMPOS_EXERCICIO = {"nome", "area", "grupo", "equipamento", "series", "repeticoes", "carga_kg",
                    "instrucoes"}
CAMPOS_ITEM = {"data", "ordem", "series", "repeticoes", "carga_kg", "observacao", "feito"}
TIPOS_IMAGEM = {"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp"}


class NaoEncontrado(Exception):
    pass


class Invalido(Exception):
    pass


def _ler(caminho: Path, padrao: Any) -> Any:
    if not caminho.exists():
        return padrao
    return json.loads(caminho.read_text("utf-8"))


def _gravar(caminho: Path, dados: Any) -> None:
    tmp = caminho.with_suffix(".tmp")
    tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=1), "utf-8")
    os.replace(tmp, caminho)


def _slug(texto: str) -> str:
    sem_acento = unicodedata.normalize("NFKD", texto).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", sem_acento.lower()).strip("-") or "exercicio"


def _data(valor: str) -> str:
    try:
        return date.fromisoformat(valor).isoformat()
    except ValueError as e:
        raise Invalido(f"Data inválida: {valor}") from e


class Treinos:
    def __init__(self, raiz: str | Path, baixar_imagens: bool = True) -> None:
        self.raiz = Path(raiz).expanduser()
        self.imagens = self.raiz / "imagens"
        self.imagens.mkdir(parents=True, exist_ok=True)
        self.baixar_imagens = baixar_imagens
        self._trava = threading.RLock()
        self._arq_exercicios = self.raiz / "exercicios.json"
        self._arq_agenda = self.raiz / "agenda.json"

    # --- exercícios ---

    def _exercicios(self) -> list[dict[str, Any]]:
        lista: list[dict[str, Any]] = _ler(self._arq_exercicios, None)
        if lista is None:
            lista = exercicios_base()
            _gravar(self._arq_exercicios, lista)
        return lista

    def listar_exercicios(self) -> list[dict[str, Any]]:
        with self._trava:
            return self._exercicios()

    def exercicio(self, id_: str) -> dict[str, Any]:
        with self._trava:
            for e in self._exercicios():
                if e["id"] == id_:
                    return e
        raise NaoEncontrado(id_)

    def criar_exercicio(self, dados: dict[str, Any]) -> dict[str, Any]:
        with self._trava:
            lista = self._exercicios()
            usados = {e["id"] for e in lista}
            base = id_ = _slug(dados["nome"])
            n = 2
            while id_ in usados:
                id_, n = f"{base}-{n}", n + 1
            novo = {
                "id": id_, "ref": None, "series": 3, "repeticoes": "10", "carga_kg": None,
                "grupo": "", "equipamento": "", "instrucoes": "",
                **{k: v for k, v in dados.items() if k in CAMPOS_EXERCICIO},
                "personalizado": True, "imagem_propria": False,
            }
            lista.append(novo)
            _gravar(self._arq_exercicios, lista)
            return novo

    def editar_exercicio(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        with self._trava:
            lista = self._exercicios()
            for e in lista:
                if e["id"] == id_:
                    e.update({k: v for k, v in dados.items() if k in CAMPOS_EXERCICIO})
                    _gravar(self._arq_exercicios, lista)
                    return e
        raise NaoEncontrado(id_)

    def excluir_exercicio(self, id_: str) -> None:
        """Exclui o exercício, a foto dele e as marcações na agenda."""
        with self._trava:
            lista = self._exercicios()
            restantes = [e for e in lista if e["id"] != id_]
            if len(restantes) == len(lista):
                raise NaoEncontrado(id_)
            _gravar(self._arq_exercicios, restantes)
            agenda = _ler(self._arq_agenda, [])
            _gravar(self._arq_agenda, [i for i in agenda if i["exercicio_id"] != id_])
            for f in self.imagens.glob(f"{id_}.*"):
                f.unlink()

    # --- imagens ---

    def salvar_imagem(self, id_: str, tipo: str, conteudo: bytes) -> dict[str, Any]:
        ext = TIPOS_IMAGEM.get(tipo)
        if ext is None:
            raise Invalido("Imagem deve ser JPEG, PNG ou WEBP")
        with self._trava:
            self.exercicio(id_)
            for f in self.imagens.glob(f"{id_}.*"):
                f.unlink()
            (self.imagens / f"{id_}.{ext}").write_bytes(conteudo)
            return self._marcar_imagem(id_, True)

    def remover_imagem(self, id_: str) -> dict[str, Any]:
        with self._trava:
            for f in self.imagens.glob(f"{id_}.*"):
                f.unlink()
            return self._marcar_imagem(id_, False)

    def _marcar_imagem(self, id_: str, propria: bool) -> dict[str, Any]:
        lista = self._exercicios()
        for e in lista:
            if e["id"] == id_:
                e["imagem_propria"] = propria
                _gravar(self._arq_exercicios, lista)
                return e
        raise NaoEncontrado(id_)

    def imagem(self, id_: str, n: int = 0) -> Path:
        """Foto enviada pelo usuário ou, sem ela, a imagem `n` (0 = início, 1 = fim do movimento)
        do free-exercise-db, baixada uma vez e guardada em cache."""
        e = self.exercicio(id_)
        if e.get("imagem_propria"):
            for f in self.imagens.glob(f"{id_}.*"):
                return f
        ref = e.get("ref")
        if not ref or n not in (0, 1):
            raise NaoEncontrado(id_)
        cache = self.imagens / "ref" / f"{ref}_{n}.jpg"
        if not cache.exists():
            if not self.baixar_imagens:
                raise NaoEncontrado(id_)
            try:
                with urllib.request.urlopen(URL_IMAGENS.format(ref=ref, n=n), timeout=15) as r:
                    conteudo = r.read()
            except OSError as erro:
                raise NaoEncontrado(id_) from erro
            cache.parent.mkdir(exist_ok=True)
            cache.write_bytes(conteudo)
        return cache

    # --- agenda ---

    def agenda(self, de: str, ate: str) -> list[dict[str, Any]]:
        de, ate = _data(de), _data(ate)
        with self._trava:
            itens = [i for i in _ler(self._arq_agenda, []) if de <= i["data"] <= ate]
        return sorted(itens, key=lambda i: (i["data"], i["ordem"]))

    def marcar(self, dados: dict[str, Any]) -> dict[str, Any]:
        """Põe um exercício num dia; séries, repetições e carga vêm do exercício se não vierem."""
        with self._trava:
            e = self.exercicio(dados["exercicio_id"])
            agenda = _ler(self._arq_agenda, [])
            dia = _data(dados["data"])
            item = {
                "id": uuid.uuid4().hex[:12],
                "data": dia,
                "exercicio_id": e["id"],
                "ordem": max((i["ordem"] for i in agenda if i["data"] == dia), default=-1) + 1,
                "series": e["series"],
                "repeticoes": e["repeticoes"],
                "carga_kg": e["carga_kg"],
                "observacao": "",
                "feito": False,
            }
            item.update({k: v for k, v in dados.items() if k in CAMPOS_ITEM and v is not None})
            item["data"] = dia
            agenda.append(item)
            _gravar(self._arq_agenda, agenda)
            return item

    def editar_item(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        with self._trava:
            agenda = _ler(self._arq_agenda, [])
            for i in agenda:
                if i["id"] == id_:
                    i.update({k: v for k, v in dados.items() if k in CAMPOS_ITEM})
                    i["data"] = _data(i["data"])
                    _gravar(self._arq_agenda, agenda)
                    return dict(i)
        raise NaoEncontrado(id_)

    def desmarcar(self, id_: str) -> None:
        with self._trava:
            agenda = _ler(self._arq_agenda, [])
            restantes = [i for i in agenda if i["id"] != id_]
            if len(restantes) == len(agenda):
                raise NaoEncontrado(id_)
            _gravar(self._arq_agenda, restantes)

    def copiar(self, de: str, ate: str, destino: str) -> list[dict[str, Any]]:
        """Copia os itens de [de, ate] para o período que começa em `destino` (mesmo deslocamento
        de dias), sem marcar como feitos. Serve para repetir um dia ou uma semana de treino."""
        desloc = date.fromisoformat(_data(destino)) - date.fromisoformat(_data(de))
        novos = []
        for i in self.agenda(de, ate):
            dia = (date.fromisoformat(i["data"]) + desloc).isoformat()
            novos.append(self.marcar({**i, "data": dia, "feito": False, "ordem": None}))
        return novos
