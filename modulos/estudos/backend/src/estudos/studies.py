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

from estudos.knowledge import Conhecimento
from estudos.languages import IDIOMAS, NIVEIS, cronograma, horas_estudadas, marcos, nivel_de_horas
from estudos.projects import CAMPOS_CLASSIFICACAO, CAMPOS_PROJETO, Marcacoes, montar_matriz

AREAS = ["Tecnologia", "Finanças", "Linguagens", "Saúde"]
STATUS_LEITURA = ["quero ler", "lendo", "lido"]
CAMPOS_LEITURA = {
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
CAMPOS_TRILHA = {
    "idioma",
    "nivel_inicial",
    "nivel_alvo",
    "minutos_por_dia",
    "dias_semana",
    "inicio",
}


class NaoEncontrado(Exception):
    pass


class Invalido(Exception):
    pass


def _agora() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat()


def _data(valor: str) -> date:
    try:
        return date.fromisoformat(valor)
    except ValueError as e:
        raise Invalido(f"Data inválida: {valor}") from e


class Colecao:
    """Lista de dicionários com `id`, gravada inteira a cada mudança (troca atômica do arquivo)."""

    def __init__(self, arquivo: Path, trava: threading.RLock) -> None:
        self.arquivo = arquivo
        self.trava = trava

    def ler(self) -> list[dict[str, Any]]:
        if not self.arquivo.exists():
            return []
        lista: list[dict[str, Any]] = json.loads(self.arquivo.read_text("utf-8"))
        return lista

    def gravar(self, lista: list[dict[str, Any]]) -> None:
        tmp = self.arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(lista, ensure_ascii=False, indent=1), "utf-8")
        os.replace(tmp, self.arquivo)

    def obter(self, id_: str) -> dict[str, Any]:
        for x in self.ler():
            if x["id"] == id_:
                return x
        raise NaoEncontrado(id_)

    def criar(self, dados: dict[str, Any]) -> dict[str, Any]:
        with self.trava:
            lista = self.ler()
            novo = {
                "id": uuid.uuid4().hex[:12],
                **dados,
                "criado": _agora(),
                "atualizado": _agora(),
            }
            lista.append(novo)
            self.gravar(lista)
            return novo

    def editar(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        with self.trava:
            lista = self.ler()
            for x in lista:
                if x["id"] == id_:
                    x.update(dados, atualizado=_agora())
                    self.gravar(lista)
                    return x
        raise NaoEncontrado(id_)

    def excluir(self, id_: str) -> None:
        with self.trava:
            lista = self.ler()
            restantes = [x for x in lista if x["id"] != id_]
            if len(restantes) == len(lista):
                raise NaoEncontrado(id_)
            self.gravar(restantes)


class Estudos:
    def __init__(self, raiz: str | Path, marcacoes: Marcacoes | None = None) -> None:
        self.raiz = Path(raiz).expanduser()
        self.raiz.mkdir(parents=True, exist_ok=True)
        trava = threading.RLock()
        self.leituras = Colecao(self.raiz / "leituras.json", trava)
        self.trilhas = Colecao(self.raiz / "idiomas.json", trava)
        self.projetos = Colecao(self.raiz / "projetos.json", trava)
        self._marcacoes = marcacoes or (lambda _id: [])
        self.conhecimento = Conhecimento(
            self.raiz / "conhecimento.json", trava, self.leituras.ler, self.criar_leitura
        )

    # --- projetos de leitura ---

    def listar_projetos(self) -> list[dict[str, Any]]:
        lista = []
        for p in self.projetos.ler():
            marc = self._marcacoes(p["id"])
            lista.append({
                **{k: v for k, v in p.items() if k not in ("classificacao", "codigos")},
                "trechos": sum(m["tipo"] == "destaque" for m in marc),
                "comentarios": sum(
                    m["tipo"] == "texto" or bool(m.get("comentario")) for m in marc
                ),
                "manuscritos": len({(m["arquivo_id"], m.get("pagina")) for m in marc
                                    if m["tipo"] == "traco"}),
                "trabalhos": len({m["arquivo_id"] for m in marc}),
            })
        return sorted(lista, key=lambda p: p["atualizado"], reverse=True)

    def criar_projeto(self, dados: dict[str, Any]) -> dict[str, Any]:
        dados = {k: v for k, v in dados.items() if k in CAMPOS_PROJETO}
        padrao = {"descricao": "", "cor": 0xFF3F51B5, "secoes": []}
        return self.projetos.criar({**padrao, **dados, "classificacao": {}, "codigos": {}})

    def editar_projeto(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        return self.projetos.editar(id_, {k: v for k, v in dados.items() if k in CAMPOS_PROJETO})

    def matriz(self, id_: str) -> dict[str, Any]:
        with self.projetos.trava:
            projeto = self.projetos.obter(id_)
            m = montar_matriz(projeto, self._marcacoes(id_), self.leituras.ler())
            if m["codigos"] != (projeto.get("codigos") or {}):
                self.projetos.editar(id_, {"codigos": m["codigos"]})
        del m["codigos"]
        return m

    def classificar(self, id_: str, item_id: str, dados: dict[str, Any]) -> dict[str, Any]:
        with self.projetos.trava:
            projeto = self.projetos.obter(id_)
            classif = dict(projeto.get("classificacao") or {})
            atual = {**(classif.get(item_id) or {}),
                     **{k: v for k, v in dados.items() if k in CAMPOS_CLASSIFICACAO}}
            classif[item_id] = atual
            self.projetos.editar(id_, {"classificacao": classif})
            return atual

    # --- leituras ---

    def listar_leituras(self, area: str | None = None, status: str | None = None) -> list[dict]:
        lista = [
            x
            for x in self.leituras.ler()
            if (area is None or x["area"] == area) and (status is None or x["status"] == status)
        ]
        ordem = {s: i for i, s in enumerate(["lendo", "quero ler", "lido"])}
        return sorted(lista, key=lambda x: (ordem.get(x["status"], 9), x["titulo"].lower()))

    def _validar_leitura(self, dados: dict[str, Any]) -> dict[str, Any]:
        dados = {k: v for k, v in dados.items() if k in CAMPOS_LEITURA}
        if "status" in dados and dados["status"] not in STATUS_LEITURA:
            raise Invalido(f"Status deve ser um de {STATUS_LEITURA}")
        return dados

    def criar_leitura(self, dados: dict[str, Any]) -> dict[str, Any]:
        padrao = {
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
        return self.leituras.criar({**padrao, **self._validar_leitura(dados)})

    def editar_leitura(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        return self.leituras.editar(id_, self._validar_leitura(dados))

    # --- idiomas ---

    def _validar_trilha(self, dados: dict[str, Any]) -> dict[str, Any]:
        dados = {k: v for k, v in dados.items() if k in CAMPOS_TRILHA}
        for campo in ("nivel_inicial", "nivel_alvo"):
            if campo in dados and dados[campo] not in NIVEIS:
                raise Invalido(f"{campo} deve ser um de {NIVEIS}")
        if "idioma" in dados and dados["idioma"] not in IDIOMAS:
            raise Invalido(f"Idioma deve ser um de {list(IDIOMAS)}")
        if "dias_semana" in dados:
            dias = sorted({int(d) for d in dados["dias_semana"]})
            if not dias or any(d < 1 or d > 7 for d in dias):
                raise Invalido("dias_semana: de 1 (segunda) a 7 (domingo)")
            dados["dias_semana"] = dias
        if "inicio" in dados:
            dados["inicio"] = _data(dados["inicio"]).isoformat()
        return dados

    def _com_progresso(self, t: dict[str, Any], hoje: date | None = None) -> dict[str, Any]:
        hoje = hoje or date.today()
        horas = horas_estudadas(t)
        return {
            **{k: v for k, v in t.items() if k != "sessoes"},
            "nome": IDIOMAS[t["idioma"]],
            "horas": round(horas, 1),
            "nivel_atual": nivel_de_horas(horas),
            "marcos": marcos(t, hoje),
            "sessoes_feitas": len(t.get("sessoes", {})),
        }

    def listar_trilhas(self) -> list[dict[str, Any]]:
        return [self._com_progresso(t) for t in self.trilhas.ler()]

    def trilha(self, id_: str) -> dict[str, Any]:
        return self._com_progresso(self.trilhas.obter(id_))

    def criar_trilha(self, dados: dict[str, Any]) -> dict[str, Any]:
        padrao = {
            "nivel_inicial": "A1",
            "nivel_alvo": "C2",
            "minutos_por_dia": 45,
            "dias_semana": [1, 2, 3, 4, 5, 6],
            "inicio": date.today().isoformat(),
        }
        t = self.trilhas.criar({**padrao, **self._validar_trilha(dados), "sessoes": {}})
        return self._com_progresso(t)

    def editar_trilha(self, id_: str, dados: dict[str, Any]) -> dict[str, Any]:
        return self._com_progresso(self.trilhas.editar(id_, self._validar_trilha(dados)))

    def cronograma(self, id_: str, de: str, ate: str) -> list[dict[str, Any]]:
        return cronograma(self.trilhas.obter(id_), _data(de), _data(ate))

    def registrar_sessao(self, id_: str, dia: str, minutos: int) -> dict[str, Any]:
        """Grava os minutos estudados no dia (0 apaga o registro)."""
        chave = _data(dia).isoformat()
        with self.trilhas.trava:
            t = self.trilhas.obter(id_)
            sessoes = dict(t.get("sessoes", {}))
            if minutos > 0:
                sessoes[chave] = minutos
            else:
                sessoes.pop(chave, None)
            return self._com_progresso(self.trilhas.editar(id_, {"sessoes": sessoes}))

    def somar_minutos(self, idioma: str, dia: str, minutos: int) -> None:
        """Soma minutos ao dia da trilha do [idioma] (atividades da Linguagem); sem trilha, nada."""
        with self.trilhas.trava:
            trilha = next((t for t in self.trilhas.ler() if t["idioma"] == idioma), None)
            if trilha is not None:
                atual = int(trilha.get("sessoes", {}).get(_data(dia).isoformat(), 0))
                self.registrar_sessao(trilha["id"], dia, min(atual + minutos, 1440))
