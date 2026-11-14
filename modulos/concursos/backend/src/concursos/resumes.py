"""Currículos da seção Vagas: um Markdown por currículo em `<raiz>/vagas/curriculos/<id>.md` (dá
para editar ou soltar arquivos ali direto). Nome, vaga de origem e qual é o padrão ficam em
`curriculos.json` na mesma pasta. Com a pasta vazia, entra o modelo `curriculo_modelo.md` (deste
pacote) como padrão; o padrão é a base dos currículos gerados para cada vaga."""

import json
import re
import unicodedata
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

MODELO = Path(__file__).with_name("curriculo_modelo.md")
_ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,80}$")


def _agora() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _slug(texto: str) -> str:
    sem_acento = unicodedata.normalize("NFKD", texto).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", sem_acento.lower()).strip("-")[:60] or "curriculo"


class Curriculos:
    def __init__(self, raiz: Path | str) -> None:
        self.pasta = Path(raiz).expanduser() / "vagas" / "curriculos"
        self._indice = self.pasta / "curriculos.json"

    def _ler(self) -> dict[str, Any]:
        if not self._indice.exists():
            return {"padrao": "", "itens": {}}
        dados: dict[str, Any] = json.loads(self._indice.read_text())
        dados.setdefault("padrao", "")
        dados.setdefault("itens", {})
        return dados

    def _gravar(self, dados: dict[str, Any]) -> None:
        self.pasta.mkdir(parents=True, exist_ok=True)
        tmp = self._indice.with_suffix(".tmp")
        tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=1))
        tmp.replace(self._indice)

    def _arquivo(self, id_: str) -> Path | None:
        return self.pasta / f"{id_}.md" if _ID.match(id_) else None

    def _semear(self) -> None:
        self.pasta.mkdir(parents=True, exist_ok=True)
        if any(self.pasta.glob("*.md")) or not MODELO.exists():
            return
        self.salvar(None, "Meu currículo (modelo)", MODELO.read_text())

    def _padrao(self, dados: dict[str, Any]) -> str:
        """O marcado, se o arquivo ainda existe; senão o primeiro que não foi gerado para vaga."""
        ids = sorted(a.stem for a in self.pasta.glob("*.md"))
        if dados["padrao"] in ids:
            return str(dados["padrao"])
        bases = [i for i in ids if not dados["itens"].get(i, {}).get("vaga")]
        return (bases or ids or [""])[0]

    def listar(self) -> dict[str, Any]:
        self._semear()
        dados = self._ler()
        padrao = self._padrao(dados)
        itens = []
        for arq in self.pasta.glob("*.md"):
            meta = dados["itens"].get(arq.stem, {})
            em = meta.get("em") or datetime.fromtimestamp(arq.stat().st_mtime, UTC).isoformat(
                timespec="seconds"
            )
            itens.append(
                {
                    "id": arq.stem,
                    "nome": meta.get("nome") or arq.stem,
                    "vaga": meta.get("vaga", ""),
                    "em": em,
                    "padrao": arq.stem == padrao,
                }
            )
        itens.sort(key=lambda c: c["em"], reverse=True)
        itens.sort(key=lambda c: not c["padrao"])
        return {"pasta": str(self.pasta), "curriculos": itens}

    def existe(self, id_: str) -> bool:
        arq = self._arquivo(id_)
        return arq is not None and arq.exists()

    def ler(self, id_: str) -> dict[str, Any] | None:
        arq = self._arquivo(id_)
        if arq is None or not arq.exists():
            return None
        item = next(c for c in self.listar()["curriculos"] if c["id"] == id_)
        return {**item, "conteudo": arq.read_text()}

    def salvar(self, id_: str | None, nome: str, conteudo: str, vaga: str = "") -> dict[str, Any]:
        """Cria (sem `id_`, a partir do nome) ou regrava o currículo. O primeiro vira o padrão."""
        dados = self._ler()
        if id_ is None:
            base = _slug(nome)
            id_, n = base, 2
            while (self.pasta / f"{id_}.md").exists():
                id_, n = f"{base}-{n}", n + 1
        arq = self._arquivo(id_)
        if arq is None:
            raise ValueError("id de currículo inválido")
        self.pasta.mkdir(parents=True, exist_ok=True)
        arq.write_text(conteudo)
        antigo = dados["itens"].get(id_, {})
        dados["itens"][id_] = {
            "nome": nome.strip() or antigo.get("nome") or id_,
            "vaga": vaga or antigo.get("vaga", ""),
            "em": _agora(),
        }
        if not dados["padrao"]:
            dados["padrao"] = id_
        self._gravar(dados)
        return {"id": id_, **dados["itens"][id_], "padrao": dados["padrao"] == id_}

    def definir_padrao(self, id_: str) -> bool:
        if not self.existe(id_):
            return False
        dados = self._ler()
        dados["padrao"] = id_
        self._gravar(dados)
        return True

    def remover(self, id_: str) -> bool:
        arq = self._arquivo(id_)
        if arq is None or not arq.exists():
            return False
        arq.unlink()
        dados = self._ler()
        dados["itens"].pop(id_, None)
        if dados["padrao"] == id_:
            dados["padrao"] = ""
        self._gravar(dados)
        return True

    def padrao(self) -> dict[str, Any] | None:
        self._semear()
        id_ = self._padrao(self._ler())
        return self.ler(id_) if id_ else None
