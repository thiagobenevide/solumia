"""Planos de leitura bíblica em `planos.json`: um escopo (Bíblia, AT, NT, evangelhos…) dividido em
N dias por número de capítulos, com os dias já lidos. Reflexões e estudos de teologia são notas do
vault (`/api/notas`, tags `reflexao` e `teologia`), feitas no app."""

import threading
import uuid
from datetime import date, timedelta
from pathlib import Path
from typing import Any

from saude.treinos import Invalido, NaoEncontrado, _gravar, _ler

# cânon protestante: (livro, capítulos)
ANTIGO = [
    ("Gênesis", 50), ("Êxodo", 40), ("Levítico", 27), ("Números", 36), ("Deuteronômio", 34),
    ("Josué", 24), ("Juízes", 21), ("Rute", 4), ("1 Samuel", 31), ("2 Samuel", 24),
    ("1 Reis", 22), ("2 Reis", 25), ("1 Crônicas", 29), ("2 Crônicas", 36), ("Esdras", 10),
    ("Neemias", 13), ("Ester", 10), ("Jó", 42), ("Salmos", 150), ("Provérbios", 31),
    ("Eclesiastes", 12), ("Cantares", 8), ("Isaías", 66), ("Jeremias", 52), ("Lamentações", 5),
    ("Ezequiel", 48), ("Daniel", 12), ("Oseias", 14), ("Joel", 3), ("Amós", 9), ("Obadias", 1),
    ("Jonas", 4), ("Miqueias", 7), ("Naum", 3), ("Habacuque", 3), ("Sofonias", 3), ("Ageu", 2),
    ("Zacarias", 14), ("Malaquias", 4),
]
NOVO = [
    ("Mateus", 28), ("Marcos", 16), ("Lucas", 24), ("João", 21), ("Atos", 28), ("Romanos", 16),
    ("1 Coríntios", 16), ("2 Coríntios", 13), ("Gálatas", 6), ("Efésios", 6), ("Filipenses", 4),
    ("Colossenses", 4), ("1 Tessalonicenses", 5), ("2 Tessalonicenses", 3), ("1 Timóteo", 6),
    ("2 Timóteo", 4), ("Tito", 3), ("Filemom", 1), ("Hebreus", 13), ("Tiago", 5), ("1 Pedro", 5),
    ("2 Pedro", 3), ("1 João", 5), ("2 João", 1), ("3 João", 1), ("Judas", 1), ("Apocalipse", 22),
]
LIVROS = dict(ANTIGO + NOVO)

ESCOPOS: dict[str, tuple[str, list[str]]] = {
    "biblia": ("Bíblia inteira", [n for n, _ in ANTIGO + NOVO]),
    "at": ("Antigo Testamento", [n for n, _ in ANTIGO]),
    "nt": ("Novo Testamento", [n for n, _ in NOVO]),
    "evangelhos": ("Evangelhos e Atos", ["Mateus", "Marcos", "Lucas", "João", "Atos"]),
    "sabedoria": ("Salmos e Provérbios", ["Salmos", "Provérbios"]),
    "cartas": ("Cartas do NT", [n for n, _ in NOVO[5:26]]),
}


def capitulos(livros: list[str]) -> list[tuple[str, int]]:
    return [(livro, c) for livro in livros for c in range(1, LIVROS[livro] + 1)]


def _juntar(trecho: list[tuple[str, int]]) -> list[str]:
    """[(Gn,1),(Gn,2),(Êx,1)] → ["Gênesis 1–2", "Êxodo 1"]."""
    saida: list[str] = []
    i = 0
    while i < len(trecho):
        livro, ini = trecho[i]
        fim = ini
        while i + 1 < len(trecho) and trecho[i + 1] == (livro, fim + 1):
            i += 1
            fim += 1
        saida.append(f"{livro} {ini}" if ini == fim else f"{livro} {ini}–{fim}")
        i += 1
    return saida


def leitura_do_dia(livros: list[str], dias: int, n: int) -> list[str]:
    """Trechos do dia `n` (0 a dias-1): capítulos divididos o mais igual possível."""
    caps = capitulos(livros)
    total = len(caps)
    return _juntar(caps[n * total // dias : (n + 1) * total // dias])


def _data(valor: str) -> date:
    try:
        return date.fromisoformat(valor)
    except ValueError as e:
        raise Invalido(f"Data inválida: {valor}") from e


class Espiritual:
    def __init__(self, raiz: str | Path) -> None:
        self.raiz = Path(raiz).expanduser()
        self.raiz.mkdir(parents=True, exist_ok=True)
        self._trava = threading.RLock()
        self._planos = self.raiz / "planos.json"

    def _resumo(self, p: dict[str, Any], hoje: date) -> dict[str, Any]:
        inicio = date.fromisoformat(p["inicio"])
        n_hoje = (hoje - inicio).days
        feitos = set(p.get("feitos", []))
        passados = [
            (inicio + timedelta(days=i)).isoformat() for i in range(max(0, min(n_hoje, p["dias"])))
        ]
        return {
            **{k: v for k, v in p.items() if k != "feitos"},
            "nome_escopo": ESCOPOS[p["escopo"]][0],
            "lidos": len(feitos),
            "atrasados": [d for d in passados if d not in feitos],
            "capitulos": len(capitulos(ESCOPOS[p["escopo"]][1])),
            "fim": (inicio + timedelta(days=p["dias"] - 1)).isoformat(),
        }

    def planos(self, hoje: date | None = None) -> list[dict[str, Any]]:
        with self._trava:
            return [self._resumo(p, hoje or date.today()) for p in _ler(self._planos, [])]

    def _plano(self, id_: str) -> dict[str, Any]:
        for p in _ler(self._planos, []):
            if p["id"] == id_:
                return p
        raise NaoEncontrado(id_)

    def criar_plano(self, dados: dict[str, Any]) -> dict[str, Any]:
        if dados.get("escopo") not in ESCOPOS:
            raise Invalido(f"escopo deve ser um de {list(ESCOPOS)}")
        dias = int(dados.get("dias", 365))
        if not 1 <= dias <= 3650:
            raise Invalido("dias: de 1 a 3650")
        inicio = _data(dados.get("inicio") or date.today().isoformat()).isoformat()
        novo = {
            "id": uuid.uuid4().hex[:12],
            "nome": dados.get("nome") or ESCOPOS[dados["escopo"]][0],
            "escopo": dados["escopo"],
            "dias": dias,
            "inicio": inicio,
            "feitos": [],
        }
        with self._trava:
            lista = _ler(self._planos, [])
            lista.append(novo)
            _gravar(self._planos, lista)
        return self._resumo(novo, date.today())

    def excluir_plano(self, id_: str) -> None:
        with self._trava:
            lista = _ler(self._planos, [])
            restantes = [p for p in lista if p["id"] != id_]
            if len(restantes) == len(lista):
                raise NaoEncontrado(id_)
            _gravar(self._planos, restantes)

    def leituras(self, id_: str, de: str, ate: str) -> list[dict[str, Any]]:
        with self._trava:
            p = self._plano(id_)
        inicio = date.fromisoformat(p["inicio"])
        livros = ESCOPOS[p["escopo"]][1]
        feitos = set(p.get("feitos", []))
        d, fim = max(_data(de), inicio), min(_data(ate), inicio + timedelta(days=p["dias"] - 1))
        dias = []
        while d <= fim:
            n = (d - inicio).days
            dias.append({
                "data": d.isoformat(),
                "dia": n + 1,
                "trechos": leitura_do_dia(livros, p["dias"], n),
                "feito": d.isoformat() in feitos,
            })
            d += timedelta(days=1)
        return dias

    def marcar(self, id_: str, dia: str, feito: bool) -> dict[str, Any]:
        chave = _data(dia).isoformat()
        with self._trava:
            lista = _ler(self._planos, [])
            for p in lista:
                if p["id"] == id_:
                    feitos = set(p.get("feitos", []))
                    if feito:
                        feitos.add(chave)
                    else:
                        feitos.discard(chave)
                    p["feitos"] = sorted(feitos)
                    _gravar(self._planos, lista)
                    return self._resumo(p, date.today())
        raise NaoEncontrado(id_)
