"""Quadros brancos guardados um por arquivo em `quadros/<id>.json` na pasta de dados.

Cada quadro tem `elementos` em coordenadas do mundo (quadro infinito): `traco` (pontos `[x, y, p]`,
p = pressão 0–1), `forma` (reta, seta, retângulo, elipse entre `a` e `b`), `texto` e os blocos
(`no`) e setas (`ligacao`) de fluxograma, `tabela` (células editáveis) e `imagem` (id em
`imagens/`); `grupo` junta elementos (Ctrl+G). `paginas` ([{id, nome}]) divide o quadro em
abas; cada elemento diz a sua em `pagina` (vazio = a primeira). O backend só
confere o envelope (`id` e `tipo`); o desenho é do app. `versao` sobe a cada gravação: quem grava
com uma versão velha recebe [Conflito] e mescla antes de tentar de novo (vários aparelhos)."""

import json
import os
import re
import shutil
import threading
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

FUNDOS = ("liso", "pontos", "grade", "linhas")
TIPOS = ("traco", "forma", "texto", "no", "ligacao", "tabela", "imagem")
CAMPOS_EDITAVEIS = {"titulo", "fundo", "pasta", "paginas"}
_ID = re.compile(r"^[0-9a-f]{32}$")
PNG = b"\x89PNG\r\n\x1a\n"
MAX_MINIATURA = 512 * 1024
MAX_ANEXO = 8 * 1024 * 1024


class NaoEncontrado(Exception):
    pass


class Invalido(Exception):
    pass


class Conflito(Exception):
    def __init__(self, atual: dict[str, Any]) -> None:
        super().__init__("O quadro mudou em outro aparelho")
        self.atual = atual


def _agora() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _resumo(q: dict[str, Any]) -> dict[str, Any]:
    return {**{k: v for k, v in q.items() if k != "elementos"}, "total": len(q["elementos"])}


class Quadros:
    """A mesma guarda serve aos wireframes (pasta `wireframes/`, tipos de `wireframe_ia`)."""

    def __init__(
        self, raiz: str | Path, pasta: str = "quadros", tipos: tuple[str, ...] = TIPOS
    ) -> None:
        self.raiz = Path(raiz).expanduser() / pasta
        self.raiz.mkdir(parents=True, exist_ok=True)
        self.tipos = tipos
        self._trava = threading.RLock()

    def _caminho(self, id_: str) -> Path:
        if not _ID.match(id_):
            raise NaoEncontrado(id_)
        return self.raiz / f"{id_}.json"

    def _ler(self, id_: str) -> dict[str, Any]:
        caminho = self._caminho(id_)
        if not caminho.exists():
            raise NaoEncontrado(id_)
        dados: dict[str, Any] = json.loads(caminho.read_text("utf-8"))
        return dados

    def _gravar(self, q: dict[str, Any]) -> None:
        caminho = self._caminho(q["id"])
        tmp = caminho.with_suffix(".tmp")
        tmp.write_text(json.dumps(q, ensure_ascii=False, separators=(",", ":")), "utf-8")
        os.replace(tmp, caminho)

    def _validar(self, campos: dict[str, Any]) -> None:
        if campos.get("fundo", "pontos") not in FUNDOS:
            raise Invalido(f"Fundo inválido: {campos['fundo']}")
        paginas = campos.get("paginas", [])
        if not isinstance(paginas, list) or not all(
            isinstance(p, dict) and p.get("id") and isinstance(p.get("nome"), str) for p in paginas
        ):
            raise Invalido("Páginas precisam de id e nome")
        for e in campos.get("elementos", []):
            if not isinstance(e, dict) or not e.get("id") or e.get("tipo") not in self.tipos:
                raise Invalido("Elemento sem id ou com tipo desconhecido")

    def listar(self, pasta: str | None = None) -> list[dict[str, Any]]:
        with self._trava:
            quadros = [
                {**_resumo(self._ler(p.stem)), "miniatura": p.with_suffix(".png").exists()}
                for p in self.raiz.glob("*.json")
            ]
        if pasta is not None:
            quadros = [q for q in quadros if q["pasta"] == pasta]
        return sorted(quadros, key=lambda q: q["atualizado"], reverse=True)

    def obter(self, id_: str) -> dict[str, Any]:
        with self._trava:
            return self._ler(id_)

    def criar(self, campos: dict[str, Any]) -> dict[str, Any]:
        self._validar(campos)
        agora = _agora()
        q = {
            "id": uuid.uuid4().hex,
            "titulo": campos.get("titulo") or "Quadro sem título",
            "fundo": campos.get("fundo", "pontos"),
            "pasta": campos.get("pasta", ""),
            "criado": agora,
            "atualizado": agora,
            "versao": 1,
            "paginas": campos.get("paginas", []),
            "elementos": campos.get("elementos", []),
        }
        with self._trava:
            self._gravar(q)
        return q

    def editar(self, id_: str, campos: dict[str, Any]) -> dict[str, Any]:
        campos = {k: v for k, v in campos.items() if k in CAMPOS_EDITAVEIS and v is not None}
        self._validar(campos)
        with self._trava:
            q = self._ler(id_)
            q.update(campos, atualizado=_agora())
            self._gravar(q)
        return _resumo(q)

    def salvar(self, id_: str, elementos: list[dict[str, Any]], versao: int) -> dict[str, Any]:
        """Troca os elementos se [versao] for a atual; devolve o resumo com a versão nova."""
        self._validar({"elementos": elementos})
        with self._trava:
            q = self._ler(id_)
            if versao != q["versao"]:
                raise Conflito(q)
            q.update(elementos=elementos, versao=q["versao"] + 1, atualizado=_agora())
            self._gravar(q)
        return _resumo(q)

    def substituir(self, id_: str, campos: dict[str, Any]) -> dict[str, Any]:
        """Troca título, páginas e elementos de uma vez (importação), subindo a versão."""
        campos = {k: campos[k] for k in ("titulo", "paginas", "elementos") if k in campos}
        self._validar(campos)
        with self._trava:
            q = self._ler(id_)
            q.update(campos, versao=q["versao"] + 1, atualizado=_agora())
            self._gravar(q)
        return q

    def duplicar(self, id_: str) -> dict[str, Any]:
        q = self.obter(id_)
        return self.criar({**q, "titulo": f"{q['titulo']} (cópia)"})

    def miniatura(self, id_: str) -> Path:
        """PNG pequeno do quadro, gerado pelo app a cada gravação (a galeria mostra)."""
        caminho = self._caminho(id_).with_suffix(".png")
        if not caminho.exists():
            raise NaoEncontrado(id_)
        return caminho

    def guardar_miniatura(self, id_: str, dados: bytes) -> None:
        if not dados.startswith(PNG) or len(dados) > MAX_MINIATURA:
            raise Invalido("Miniatura deve ser PNG de até 512 KB")
        with self._trava:
            self._ler(id_)
            caminho = self._caminho(id_).with_suffix(".png")
            tmp = caminho.with_suffix(".tmp")
            tmp.write_bytes(dados)
            os.replace(tmp, caminho)

    def _anexos(self, id_: str) -> Path:
        return self._caminho(id_).with_suffix(".anexos")

    def guardar_png(self, id_: str, nome: str, dados: bytes) -> None:
        """PNG avulso do documento (ex.: render de cada tela do wireframe), em `<id>.anexos/`."""
        if not re.fullmatch(r"[\w-]{1,64}", nome):
            raise Invalido("Nome de anexo inválido")
        if not dados.startswith(PNG) or len(dados) > MAX_ANEXO:
            raise Invalido("Anexo deve ser PNG de até 8 MB")
        with self._trava:
            self._ler(id_)
            pasta = self._anexos(id_)
            pasta.mkdir(exist_ok=True)
            tmp = pasta / f"{nome}.tmp"
            tmp.write_bytes(dados)
            os.replace(tmp, pasta / f"{nome}.png")

    def pngs(self, id_: str) -> dict[str, bytes]:
        """{nome: bytes} dos PNGs guardados com [guardar_png]."""
        pasta = self._anexos(id_)
        return (
            {p.stem: p.read_bytes() for p in sorted(pasta.glob("*.png"))} if pasta.is_dir() else {}
        )

    def excluir(self, id_: str) -> None:
        with self._trava:
            caminho = self._caminho(id_)
            if not caminho.exists():
                raise NaoEncontrado(id_)
            caminho.unlink()
            caminho.with_suffix(".png").unlink(missing_ok=True)
            shutil.rmtree(self._anexos(id_), ignore_errors=True)
