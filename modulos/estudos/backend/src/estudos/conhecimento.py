"""Trilhas de conhecimento (Tecnologia → Arquiteto de Software): o catálogo vem de
`catalogo_tecnologia.py`; o que é da pessoa fica em `conhecimento.json`:
`livros` ({id: {tenho, leitura_id}}), `lidas` ({"etapa#i": data}), `praticas` ({etapa: data}) e
`notas` ({etapa: nota_id}). Cada livro pode ser ligado a uma leitura da aba Leituras (com o PDF dos
Arquivos), onde se lê e grifa; a trilha só diz o que ler e em que ordem."""

import json
import os
import threading
import unicodedata
from collections.abc import Callable
from datetime import date
from pathlib import Path
from typing import Any

from estudos.catalogo_tecnologia import FRENTES, LIVROS, TRILHAS

_LIVROS = {x["id"]: x for x in LIVROS}
_TRILHAS = {t["id"]: t for t in TRILHAS}


class ItemInexistente(KeyError):
    pass


def _normal(texto: str) -> str:
    t = unicodedata.normalize("NFKD", texto).encode("ascii", "ignore").decode().lower()
    return " ".join(t.replace(":", " ").split())


class Conhecimento:
    def __init__(
        self,
        arquivo: Path,
        trava: threading.RLock,
        leituras: Callable[[], list[dict[str, Any]]],
        criar_leitura: Callable[[dict[str, Any]], dict[str, Any]],
    ) -> None:
        self.arquivo = arquivo
        self.trava = trava
        self._leituras = leituras
        self._criar_leitura = criar_leitura

    def _ler(self) -> dict[str, Any]:
        base: dict[str, Any] = {"livros": {}, "lidas": {}, "praticas": {}, "notas": {}}
        if self.arquivo.exists():
            base.update(json.loads(self.arquivo.read_text("utf-8")))
        return base

    def _gravar(self, estado: dict[str, Any]) -> None:
        tmp = self.arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(estado, ensure_ascii=False, indent=1), "utf-8")
        os.replace(tmp, self.arquivo)

    # --- estante ---

    def _leitura_do_livro(
        self, livro: dict[str, Any], meu: dict[str, Any], leituras: list[dict[str, Any]]
    ) -> dict[str, Any] | None:
        """A leitura ligada (por id) ou, se não houver, a de mesmo título na aba Leituras."""
        nomes = {_normal(livro["titulo"]), _normal(livro["original"])}
        achada = next((x for x in leituras if x["id"] == meu.get("leitura_id")), None)
        achada = achada or next((x for x in leituras if _normal(x["titulo"]) in nomes), None)
        if achada is None:
            return None
        campos = ("id", "status", "arquivo_id", "nota_id", "pagina_atual", "paginas")
        return {k: achada.get(k) for k in campos}

    def _livro(
        self, id_: str, estado: dict[str, Any], leituras: list[dict[str, Any]]
    ) -> dict[str, Any]:
        livro = _LIVROS[id_]
        meu = estado["livros"].get(id_, {})
        return {
            **livro,
            "tenho": meu.get("tenho", livro["tenho"]),
            "leitura": self._leitura_do_livro(livro, meu, leituras),
        }

    def livros(self) -> list[dict[str, Any]]:
        estado, leituras = self._ler(), self._leituras()
        usos: dict[str, int] = {}
        for t in TRILHAS:
            for e in t["etapas"]:
                for ind in e["leituras"]:
                    usos[ind["livro"]] = usos.get(ind["livro"], 0) + 1
        return [{**self._livro(x["id"], estado, leituras), "indicacoes": usos.get(x["id"], 0)}
                for x in LIVROS]

    def editar_livro(self, id_: str, tenho: bool) -> dict[str, Any]:
        if id_ not in _LIVROS:
            raise ItemInexistente(id_)
        with self.trava:
            estado = self._ler()
            estado["livros"].setdefault(id_, {})["tenho"] = tenho
            self._gravar(estado)
            return self._livro(id_, estado, self._leituras())

    def vincular_leitura(self, id_: str) -> dict[str, Any]:
        """Liga o livro a uma leitura da aba Leituras (cria se não houver) para ler e grifar lá."""
        if id_ not in _LIVROS:
            raise ItemInexistente(id_)
        with self.trava:
            estado = self._ler()
            livro = _LIVROS[id_]
            leitura = self._leitura_do_livro(livro, estado["livros"].get(id_, {}), self._leituras())
            if leitura is None:
                leitura = self._criar_leitura({
                    "titulo": livro["titulo"],
                    "autor": livro["autor"],
                    "area": "Tecnologia",
                    "url": livro.get("url", ""),
                    "tags": ["trilha", "arquitetura"],
                })
            meu = estado["livros"].setdefault(id_, {})
            meu["leitura_id"] = leitura["id"]
            meu["tenho"] = True
            self._gravar(estado)
            return self._livro(id_, estado, self._leituras())

    # --- trilhas ---

    def _etapa(
        self, e: dict[str, Any], estado: dict[str, Any], leituras: list[dict[str, Any]]
    ) -> dict[str, Any]:
        indicacoes = []
        for i, ind in enumerate(e["leituras"]):
            chave = f"{e['id']}#{i}"
            indicacoes.append({
                **ind,
                "chave": chave,
                "indice": i,
                "feita": estado["lidas"].get(chave),
                "livro": self._livro(ind["livro"], estado, leituras),
            })
        pratica = estado["praticas"].get(e["id"])
        feitas = sum(bool(x["feita"]) for x in indicacoes) + bool(pratica)
        total = len(indicacoes) + 1
        return {
            **e,
            "leituras": indicacoes,
            "pratica_feita": pratica,
            "nota_id": estado["notas"].get(e["id"]),
            "progresso": round(feitas / total, 3),
            "concluida": feitas == total,
        }

    @staticmethod
    def _proxima(etapas: list[dict[str, Any]]) -> dict[str, Any] | None:
        """Leitura dinâmica: a primeira etapa aberta; nela, o primeiro capítulo não lido de um livro
        que a pessoa tem (senão o primeiro não lido, a conseguir); lido tudo, a prática."""
        for e in etapas:
            if e["concluida"]:
                continue
            abertas = [x for x in e["leituras"] if not x["feita"]]
            na_estante = [x for x in abertas if x["livro"]["tenho"]]
            base = {"etapa_id": e["id"], "etapa": e["titulo"], "fase": e["fase"]}
            if na_estante:
                return {**base, "tipo": "leitura", "indicacao": na_estante[0]}
            if abertas:
                return {**base, "tipo": "conseguir", "indicacao": abertas[0]}
            return {**base, "tipo": "pratica", "pratica": e["pratica"]}
        return None

    def _resumo(self, etapas: list[dict[str, Any]]) -> dict[str, Any]:
        return {
            "total_etapas": len(etapas),
            "etapas_concluidas": sum(e["concluida"] for e in etapas),
            "progresso": round(sum(e["progresso"] for e in etapas) / len(etapas), 3)
            if etapas
            else 0,
        }

    def listar_trilhas(self) -> list[dict[str, Any]]:
        estado, leituras = self._ler(), self._leituras()
        lista = []
        for t in TRILHAS:
            etapas = [self._etapa(e, estado, leituras) for e in t["etapas"]]
            lista.append({
                **{k: v for k, v in t.items() if k != "etapas"},
                **self._resumo(etapas),
                "proxima": self._proxima(etapas),
            })
        return lista

    def trilha(self, id_: str, frente: str | None = None) -> dict[str, Any]:
        t = _TRILHAS.get(id_)
        if t is None:
            raise ItemInexistente(id_)
        estado, leituras = self._ler(), self._leituras()
        etapas = [self._etapa(e, estado, leituras) for e in t["etapas"]
                  if frente is None or frente in e["frentes"]]
        presentes = {f for e in t["etapas"] for f in e["frentes"]}
        return {
            **{k: v for k, v in t.items() if k != "etapas"},
            "frentes": [f for f in FRENTES if f in presentes],
            "frente": frente,
            "etapas": etapas,
            **self._resumo(etapas),
            "proxima": self._proxima(etapas),
        }

    def marcar(self, trilha_id: str, etapa_id: str, dados: dict[str, Any]) -> dict[str, Any]:
        """`leitura` (índice) + `feita`, `pratica` (bool) e/ou `nota_id`; devolve a etapa."""
        t = _TRILHAS.get(trilha_id)
        etapa = next((e for e in t["etapas"] if e["id"] == etapa_id), None) if t else None
        if etapa is None:
            raise ItemInexistente(etapa_id)
        hoje = date.today().isoformat()
        with self.trava:
            estado = self._ler()
            if dados.get("leitura") is not None:
                i = int(dados["leitura"])
                if not 0 <= i < len(etapa["leituras"]):
                    raise ItemInexistente(f"{etapa_id}#{i}")
                chave = f"{etapa_id}#{i}"
                if dados.get("feita", True):
                    estado["lidas"][chave] = hoje
                else:
                    estado["lidas"].pop(chave, None)
            if dados.get("pratica") is not None:
                if dados["pratica"]:
                    estado["praticas"][etapa_id] = hoje
                else:
                    estado["praticas"].pop(etapa_id, None)
            if dados.get("nota_id"):
                estado["notas"][etapa_id] = dados["nota_id"]
            self._gravar(estado)
            return self._etapa(etapa, estado, self._leituras())
