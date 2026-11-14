"""Dados do módulo Estudos em JSON na pasta de dados: `leituras.json` (livros e artigos) e
`idiomas.json` (trilhas A1–C2 com as sessões registradas) e
`projetos.json` (projetos de leitura) e `conhecimento.json` (progresso nas trilhas de
conhecimento, `conhecimento.py`). As sínteses e anotações ficam nas notas
(`/api/notas`), ligadas pela `nota_id` da leitura."""

import json
import os
import threading
import uuid
from datetime import UTC, date, datetime
from pathlib import Path
from typing import Any

from estudos.knowledge import Knowledge
from estudos.languages import LANGUAGES, LEVELS, schedule, hours_studied, milestones, level_of_hours
from estudos.projects import FIELDS_CLASSIFICATION, FIELDS_PROJECT, Markings, assemble_matrix

AREAS = ["Tecnologia", "Finanças", "Linguagens", "Saúde"]
STATUS_READING = ["quero ler", "lendo", "lido"]
FIELDS_READING = {
    "titulo",
    "autor",
    "tipo",
    "area",
    "status",
    "paginas",
    "pagina_atual",
    "nota_id",
    "arquivo_id",
    "tags",
    "url",
    # ficha do trabalho para a matriz de citações dos projetos
    "ano",
    "referencia",
    "tipo_publicacao",
    "veiculo",
    "doi",
    "idioma",
}
FIELDS_TRACK = {
    "idioma",
    "nivel_inicial",
    "nivel_alvo",
    "minutos_por_dia",
    "dias_semana",
    "inicio",
}


class NotFound(Exception):
    pass


class Invalid(Exception):
    pass


def _now() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat()


def _data(valor: str) -> date:
    try:
        return date.fromisoformat(valor)
    except ValueError as e:
        raise Invalid(f"Data inválida: {valor}") from e


class Collection:
    """Lista de dicionários com `id`, gravada inteira a cada mudança (troca atômica do arquivo)."""

    def __init__(self, arquivo: Path, lock: threading.RLock) -> None:
        self.arquivo = arquivo
        self.trava = lock

    def ler(self) -> list[dict[str, Any]]:
        if not self.arquivo.exists():
            return []
        items: list[dict[str, Any]] = json.loads(self.arquivo.read_text("utf-8"))
        return items

    def gravar(self, items: list[dict[str, Any]]) -> None:
        tmp = self.arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(items, ensure_ascii=False, indent=1), "utf-8")
        os.replace(tmp, self.arquivo)

    def obter(self, id_: str) -> dict[str, Any]:
        for x in self.ler():
            if x["id"] == id_:
                return x
        raise NotFound(id_)

    def criar(self, dados: dict[str, Any]) -> dict[str, Any]:
        with self.trava:
            items = self.ler()
            new = {
                "id": uuid.uuid4().hex[:12],
                **dados,
                "criado": _now(),
                "atualizado": _now(),
            }
            items.append(new)
            self.gravar(items)
            return new

    def editar(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        with self.trava:
            items = self.ler()
            for x in items:
                if x["id"] == id_:
                    x.update(dados, atualizado=_now())
                    self.gravar(items)
                    return x
        raise NotFound(id_)

    def excluir(self, id_: str) -> None:
        with self.trava:
            items = self.ler()
            restantes = [x for x in items if x["id"] != id_]
            if len(restantes) == len(items):
                raise NotFound(id_)
            self.gravar(restantes)


class Studies:
    def __init__(self, root: str | Path, marcacoes: Markings | None = None) -> None:
        self.raiz = Path(root).expanduser()
        self.raiz.mkdir(parents=True, exist_ok=True)
        lock = threading.RLock()
        self.leituras = Collection(self.raiz / "leituras.json", lock)
        self.trilhas = Collection(self.raiz / "idiomas.json", lock)
        self.projetos = Collection(self.raiz / "projetos.json", lock)
        self._marcacoes = marcacoes or (lambda _id: [])
        self.conhecimento = Knowledge(
            self.raiz / "conhecimento.json", lock, self.leituras.ler, self.criar_leitura
        )

    # --- projetos de leitura ---

    def listar_projetos(self) -> list[dict[str, Any]]:
        items = []
        for p in self.projetos.ler():
            marc = self._marcacoes(p["id"])
            items.append({
                **{k: v for k, v in p.items() if k not in ("classificacao", "codigos")},
                "trechos": sum(m["tipo"] == "destaque" for m in marc),
                "comentarios": sum(
                    m["tipo"] == "texto" or bool(m.get("comentario")) for m in marc
                ),
                "manuscritos": len({(m["arquivo_id"], m.get("pagina")) for m in marc
                                    if m["tipo"] == "traco"}),
                "trabalhos": len({m["arquivo_id"] for m in marc}),
            })
        return sorted(items, key=lambda p: p["atualizado"], reverse=True)

    def criar_projeto(self, dados: dict[str, Any]) -> dict[str, Any]:
        dados = {k: v for k, v in dados.items() if k in FIELDS_PROJECT}
        default = {"descricao": "", "cor": 0xFF3F51B5, "secoes": []}
        return self.projetos.criar({**default, **dados, "classificacao": {}, "codigos": {}})

    def editar_projeto(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        return self.projetos.editar(id_, {k: v for k, v in dados.items() if k in FIELDS_PROJECT})

    def matriz(self, id_: str) -> dict[str, Any]:
        with self.projetos.trava:
            project = self.projetos.obter(id_)
            m = assemble_matrix(project, self._marcacoes(id_), self.leituras.ler())
            if m["codigos"] != (project.get("codigos") or {}):
                self.projetos.editar(id_, {"codigos": m["codigos"]})
        del m["codigos"]
        return m

    def classificar(self, id_: str, item_id: str, dados: dict[str, Any]) -> dict[str, Any]:
        with self.projetos.trava:
            project = self.projetos.obter(id_)
            classif = dict(project.get("classificacao") or {})
            current = {**(classif.get(item_id) or {}),
                     **{k: v for k, v in dados.items() if k in FIELDS_CLASSIFICATION}}
            classif[item_id] = current
            self.projetos.editar(id_, {"classificacao": classif})
            return current

    # --- leituras ---

    def listar_leituras(self, area: str | None = None, status: str | None = None) -> list[dict]:
        items = [
            x
            for x in self.leituras.ler()
            if (area is None or x["area"] == area) and (status is None or x["status"] == status)
        ]
        order = {s: i for i, s in enumerate(["lendo", "quero ler", "lido"])}
        return sorted(items, key=lambda x: (order.get(x["status"], 9), x["titulo"].lower()))

    def _validar_leitura(self, dados: dict[str, Any]) -> dict[str, Any]:
        dados = {k: v for k, v in dados.items() if k in FIELDS_READING}
        if "status" in dados and dados["status"] not in STATUS_READING:
            raise Invalid(f"Status deve ser um de {STATUS_READING}")
        return dados

    def criar_leitura(self, dados: dict[str, Any]) -> dict[str, Any]:
        default = {
            "autor": "",
            "tipo": "livro",
            "status": "quero ler",
            "paginas": None,
            "pagina_atual": 0,
            "nota_id": None,
            "arquivo_id": None,
            "tags": [],
            "url": "",
        }
        return self.leituras.criar({**default, **self._validar_leitura(dados)})

    def editar_leitura(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        return self.leituras.editar(id_, self._validar_leitura(dados))

    # --- idiomas ---

    def _validar_trilha(self, dados: dict[str, Any]) -> dict[str, Any]:
        dados = {k: v for k, v in dados.items() if k in FIELDS_TRACK}
        for field in ("nivel_inicial", "nivel_alvo"):
            if field in dados and dados[field] not in LEVELS:
                raise Invalid(f"{field} deve ser um de {LEVELS}")
        if "idioma" in dados and dados["idioma"] not in LANGUAGES:
            raise Invalid(f"Idioma deve ser um de {list(LANGUAGES)}")
        if "dias_semana" in dados:
            days = sorted({int(d) for d in dados["dias_semana"]})
            if not days or any(d < 1 or d > 7 for d in days):
                raise Invalid("dias_semana: de 1 (segunda) a 7 (domingo)")
            dados["dias_semana"] = days
        if "inicio" in dados:
            dados["inicio"] = _data(dados["inicio"]).isoformat()
        return dados

    def _com_progresso(self, t: dict[str, Any], hoje: date | None = None) -> dict[str, Any]:
        hoje = hoje or date.today()
        hours = hours_studied(t)
        return {
            **{k: v for k, v in t.items() if k != "sessoes"},
            "nome": LANGUAGES[t["idioma"]],
            "horas": round(hours, 1),
            "nivel_atual": level_of_hours(hours),
            "marcos": milestones(t, hoje),
            "sessoes_feitas": len(t.get("sessoes", {})),
        }

    def listar_trilhas(self) -> list[dict[str, Any]]:
        return [self._com_progresso(t) for t in self.trilhas.ler()]

    def trilha(self, id_: str) -> dict[str, Any]:
        return self._com_progresso(self.trilhas.obter(id_))

    def criar_trilha(self, dados: dict[str, Any]) -> dict[str, Any]:
        default = {
            "nivel_inicial": "A1",
            "nivel_alvo": "C2",
            "minutos_por_dia": 45,
            "dias_semana": [1, 2, 3, 4, 5, 6],
            "inicio": date.today().isoformat(),
        }
        t = self.trilhas.criar({**default, **self._validar_trilha(dados), "sessoes": {}})
        return self._com_progresso(t)

    def editar_trilha(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        return self._com_progresso(self.trilhas.editar(id_, self._validar_trilha(dados)))

    def cronograma(self, id_: str, de: str, ate: str) -> list[dict[str, Any]]:
        return schedule(self.trilhas.obter(id_), _data(de), _data(ate))

    def registrar_sessao(self, id_: str, day: str, minutos: int) -> dict[str, Any]:
        """Grava os minutos estudados no dia (0 apaga o registro)."""
        key = _data(day).isoformat()
        with self.trilhas.trava:
            t = self.trilhas.obter(id_)
            sessions = dict(t.get("sessoes", {}))
            if minutos > 0:
                sessions[key] = minutos
            else:
                sessions.pop(key, None)
            return self._com_progresso(self.trilhas.editar(id_, {"sessoes": sessions}))

    def somar_minutos(self, language: str, day: str, minutos: int) -> None:
        """Soma minutos ao dia da trilha do [idioma] (atividades da Linguagem); sem trilha, nada."""
        with self.trilhas.trava:
            track = next((t for t in self.trilhas.ler() if t["idioma"] == language), None)
            if track is not None:
                current = int(track.get("sessoes", {}).get(_data(day).isoformat(), 0))
                self.registrar_sessao(track["id"], day, min(current + minutos, 1440))
