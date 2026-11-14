"""Planos de leitura bíblica em `planos.json`: um escopo (Bíblia, AT, NT, evangelhos…) dividido em
N dias por número de capítulos, com os dias já lidos. Reflexões e estudos de teologia são notas do
vault (`/api/notas`, tags `reflexao` e `teologia`), feitas no app."""

import threading
import uuid
from datetime import date, timedelta
from pathlib import Path
from typing import Any

from saude.workouts import Invalid, NotFound, _write, _read

# cânon protestante: (livro, capítulos)
OLD = [
    ("Gênesis", 50), ("Êxodo", 40), ("Levítico", 27), ("Números", 36), ("Deuteronômio", 34),
    ("Josué", 24), ("Juízes", 21), ("Rute", 4), ("1 Samuel", 31), ("2 Samuel", 24),
    ("1 Reis", 22), ("2 Reis", 25), ("1 Crônicas", 29), ("2 Crônicas", 36), ("Esdras", 10),
    ("Neemias", 13), ("Ester", 10), ("Jó", 42), ("Salmos", 150), ("Provérbios", 31),
    ("Eclesiastes", 12), ("Cantares", 8), ("Isaías", 66), ("Jeremias", 52), ("Lamentações", 5),
    ("Ezequiel", 48), ("Daniel", 12), ("Oseias", 14), ("Joel", 3), ("Amós", 9), ("Obadias", 1),
    ("Jonas", 4), ("Miqueias", 7), ("Naum", 3), ("Habacuque", 3), ("Sofonias", 3), ("Ageu", 2),
    ("Zacarias", 14), ("Malaquias", 4),
]
NEW = [
    ("Mateus", 28), ("Marcos", 16), ("Lucas", 24), ("João", 21), ("Atos", 28), ("Romanos", 16),
    ("1 Coríntios", 16), ("2 Coríntios", 13), ("Gálatas", 6), ("Efésios", 6), ("Filipenses", 4),
    ("Colossenses", 4), ("1 Tessalonicenses", 5), ("2 Tessalonicenses", 3), ("1 Timóteo", 6),
    ("2 Timóteo", 4), ("Tito", 3), ("Filemom", 1), ("Hebreus", 13), ("Tiago", 5), ("1 Pedro", 5),
    ("2 Pedro", 3), ("1 João", 5), ("2 João", 1), ("3 João", 1), ("Judas", 1), ("Apocalipse", 22),
]
BOOKS = dict(OLD + NEW)

SCOPES: dict[str, tuple[str, list[str]]] = {
    "biblia": ("Bíblia inteira", [n for n, _ in OLD + NEW]),
    "at": ("Antigo Testamento", [n for n, _ in OLD]),
    "nt": ("Novo Testamento", [n for n, _ in NEW]),
    "evangelhos": ("Evangelhos e Atos", ["Mateus", "Marcos", "Lucas", "João", "Atos"]),
    "sabedoria": ("Salmos e Provérbios", ["Salmos", "Provérbios"]),
    "cartas": ("Cartas do NT", [n for n, _ in NEW[5:26]]),
}


def chapters(books: list[str]) -> list[tuple[str, int]]:
    return [(book, c) for book in books for c in range(1, BOOKS[book] + 1)]


def _join(span: list[tuple[str, int]]) -> list[str]:
    """[(Gn,1),(Gn,2),(Êx,1)] → ["Gênesis 1–2", "Êxodo 1"]."""
    output: list[str] = []
    i = 0
    while i < len(span):
        book, start = span[i]
        end = start
        while i + 1 < len(span) and span[i + 1] == (book, end + 1):
            i += 1
            end += 1
        output.append(f"{book} {start}" if start == end else f"{book} {start}–{end}")
        i += 1
    return output


def reading_of_day(books: list[str], dias: int, n: int) -> list[str]:
    """Trechos do dia `n` (0 a dias-1): capítulos divididos o mais igual possível."""
    caps = chapters(books)
    total = len(caps)
    return _join(caps[n * total // dias : (n + 1) * total // dias])


def _data(valor: str) -> date:
    try:
        return date.fromisoformat(valor)
    except ValueError as e:
        raise Invalid(f"Data inválida: {valor}") from e


class Espiritual:
    def __init__(self, root: str | Path) -> None:
        self.raiz = Path(root).expanduser()
        self.raiz.mkdir(parents=True, exist_ok=True)
        self._trava = threading.RLock()
        self._planos = self.raiz / "planos.json"

    def _resumo(self, p: dict[str, Any], hoje: date) -> dict[str, Any]:
        start = date.fromisoformat(p["inicio"])
        n_today = (hoje - start).days
        done = set(p.get("feitos", []))
        passados = [
            (start + timedelta(days=i)).isoformat() for i in range(max(0, min(n_today, p["dias"])))
        ]
        return {
            **{k: v for k, v in p.items() if k != "feitos"},
            "nome_escopo": SCOPES[p["escopo"]][0],
            "lidos": len(done),
            "atrasados": [d for d in passados if d not in done],
            "capitulos": len(chapters(SCOPES[p["escopo"]][1])),
            "fim": (start + timedelta(days=p["dias"] - 1)).isoformat(),
        }

    def planos(self, hoje: date | None = None) -> list[dict[str, Any]]:
        with self._trava:
            return [self._resumo(p, hoje or date.today()) for p in _read(self._planos, [])]

    def _plano(self, id_: str) -> dict[str, Any]:
        for p in _read(self._planos, []):
            if p["id"] == id_:
                return p
        raise NotFound(id_)

    def criar_plano(self, dados: dict[str, Any]) -> dict[str, Any]:
        if dados.get("escopo") not in SCOPES:
            raise Invalid(f"escopo deve ser um de {list(SCOPES)}")
        days = int(dados.get("dias", 365))
        if not 1 <= days <= 3650:
            raise Invalid("dias: de 1 a 3650")
        start = _data(dados.get("inicio") or date.today().isoformat()).isoformat()
        new = {
            "id": uuid.uuid4().hex[:12],
            "nome": dados.get("nome") or SCOPES[dados["escopo"]][0],
            "escopo": dados["escopo"],
            "dias": days,
            "inicio": start,
            "feitos": [],
        }
        with self._trava:
            items = _read(self._planos, [])
            items.append(new)
            _write(self._planos, items)
        return self._resumo(new, date.today())

    def excluir_plano(self, id_: str) -> None:
        with self._trava:
            items = _read(self._planos, [])
            restantes = [p for p in items if p["id"] != id_]
            if len(restantes) == len(items):
                raise NotFound(id_)
            _write(self._planos, restantes)

    def leituras(self, id_: str, de: str, ate: str) -> list[dict[str, Any]]:
        with self._trava:
            p = self._plano(id_)
        start = date.fromisoformat(p["inicio"])
        books = SCOPES[p["escopo"]][1]
        done = set(p.get("feitos", []))
        d, end = max(_data(de), start), min(_data(ate), start + timedelta(days=p["dias"] - 1))
        days = []
        while d <= end:
            n = (d - start).days
            days.append({
                "data": d.isoformat(),
                "dia": n + 1,
                "trechos": reading_of_day(books, p["dias"], n),
                "feito": d.isoformat() in done,
            })
            d += timedelta(days=1)
        return days

    def marcar(self, id_: str, day: str, done: bool) -> dict[str, Any]:
        key = _data(day).isoformat()
        with self._trava:
            items = _read(self._planos, [])
            for p in items:
                if p["id"] == id_:
                    feitos = set(p.get("feitos", []))
                    if done:
                        feitos.add(key)
                    else:
                        feitos.discard(key)
                    p["feitos"] = sorted(feitos)
                    _write(self._planos, items)
                    return self._resumo(p, date.today())
        raise NotFound(id_)
