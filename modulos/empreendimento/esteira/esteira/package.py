"""Pacotes de edição: baixa o arquivo de um editor (FilmCraft, EffectCraft, PhotoCraft) com a mídia que ele
usa, para abrir em outra máquina, e recebe o arquivo editado de volta sobrescrevendo o do episódio.

`.fcproj`/`.ecproj` são JSON com a mídia em `"path"`: no pacote os caminhos saem relativos à pasta do arquivo
(os dois editores resolvem assim) e, na volta, são religados à pasta do episódio pelo trecho depois de
`<canal>/<NNN>/` ou pelo nome do arquivo. `.pcraft` é um zip autocontido e vai como está.
O arquivo substituído fica em `log/envios/` do episódio.
"""

import io
import json
import os
import time
import zipfile
from collections.abc import Iterator
from pathlib import Path


_SEM_COMPRIMIR = {".mov", ".mp4", ".mkv", ".webm", ".png", ".jpg", ".jpeg", ".webp", ".mp3", ".m4a", ".zst"}


def _nos_com_caminho(no):
    """Dicionários com `"path"` (string) em qualquer nível do JSON."""
    if isinstance(no, dict):
        if isinstance(no.get("path"), str):
            yield no
        for v in no.values():
            yield from _nos_com_caminho(v)
    elif isinstance(no, list):
        for v in no:
            yield from _nos_com_caminho(v)


def _relativizar(dados, arquivo: Path, pasta: Path):
    """Troca os caminhos da mídia dentro do episódio por relativos a `arquivo`; devolve a mídia a empacotar."""
    midia = {}
    for no in _nos_com_caminho(dados):
        c = Path(no["path"])
        if c.is_absolute() and c.is_file() and c.is_relative_to(pasta):
            no["path"] = os.path.relpath(c, arquivo.parent)
            midia[c] = c.relative_to(pasta)
    return midia


class _Saida(io.RawIOBase):
    """Destino não-seekable do zip: acumula o que o zipfile escreve até o gerador entregar."""

    def __init__(self):
        self.buf = bytearray()
        self.pos = 0

    def writable(self):
        return True

    def write(self, b):
        self.buf += b
        self.pos += len(b)
        return len(b)

    def tell(self):
        return self.pos

    def tirar(self):
        dados, self.buf = bytes(self.buf), bytearray()
        return dados


def empacotar(arquivo: Path, pasta: Path, nome: str) -> Iterator[bytes]:
    """Zip em fluxo `nome/<caminho no episódio>` com o arquivo (caminhos relativos) e a mídia que ele usa.

    Em fluxo porque o pacote do FilmCraft passa de 1 GB e a Cloudflare corta resposta que demora a começar.
    """
    arquivo = Path(arquivo)
    dados = json.loads(arquivo.read_text())
    midia = _relativizar(dados, arquivo, pasta)
    saida = _Saida()
    with zipfile.ZipFile(saida, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as z:
        z.writestr(f"{nome}/{arquivo.relative_to(pasta)}", json.dumps(dados, ensure_ascii=False, indent=1))
        yield saida.tirar()
        for origem, rel in sorted(midia.items()):
            info = zipfile.ZipInfo.from_file(origem, f"{nome}/{rel}")
            info.compress_type = zipfile.ZIP_STORED if origem.suffix.lower() in _SEM_COMPRIMIR else zipfile.ZIP_DEFLATED
            with open(origem, "rb") as ent, z.open(info, "w", force_zip64=True) as sai:
                while bloco := ent.read(1 << 20):
                    sai.write(bloco)
                    yield saida.tirar()
    yield saida.tirar()


def _religar(dados, destino: Path, pasta: Path):
    """Volta os caminhos para a pasta do episódio; devolve quantos não foram achados."""
    marca = f"/{pasta.parent.name}/{pasta.name}/"
    nomes = None
    faltando = 0
    for no in _nos_com_caminho(dados):
        bruto = no["path"].replace("\\", "/")  # caminho do Windows também
        c = Path(bruto)
        if c.is_absolute() and c.is_file():
            continue
        if not c.is_absolute():
            achado = (destino.parent / c).resolve()
        elif marca in bruto:
            achado = pasta / bruto.split(marca, 1)[1]
        else:
            achado = None
        if not (achado and achado.is_file()):
            if nomes is None:
                nomes = {}
                for f in pasta.rglob("*"):
                    nomes.setdefault(f.name, f)
            achado = nomes.get(c.name)
        if achado and achado.is_file():
            no["path"] = str(achado)
        else:
            faltando += 1
    return faltando


def _extrair(conteudo: bytes, sufixo: str) -> bytes:
    """Aceita o próprio arquivo ou um zip que o contenha (o pacote baixado, recompactado)."""
    if not zipfile.is_zipfile(io.BytesIO(conteudo)):
        return conteudo
    with zipfile.ZipFile(io.BytesIO(conteudo)) as z:
        nomes = z.namelist()
        if sufixo == ".pcraft" and "manifest.json" in nomes:
            return conteudo
        alvo = [n for n in nomes if n.lower().endswith(sufixo)]
        if len(alvo) != 1:
            raise ValueError(f"o zip precisa ter exatamente um {sufixo} (tem {len(alvo)})")
        return z.read(alvo[0])


def receber(conteudo: bytes, destino: Path, pasta: Path) -> dict:
    """Grava a edição enviada no lugar de `destino` (guardando o anterior); devolve mídia não achada."""
    destino = Path(destino)
    conteudo = _extrair(conteudo, destino.suffix)
    faltando = 0
    if destino.suffix == ".pcraft":
        if not zipfile.is_zipfile(io.BytesIO(conteudo)) or \
                "manifest.json" not in zipfile.ZipFile(io.BytesIO(conteudo)).namelist():
            raise ValueError("não é um .pcraft do PhotoCraft")
    else:
        try:
            dados = json.loads(conteudo)
        except ValueError as e:
            raise ValueError(f"não é um {destino.suffix} válido") from e
        faltando = _religar(dados, destino, pasta)
        conteudo = json.dumps(dados, ensure_ascii=False, indent=1).encode()
    if destino.exists():
        guarda = pasta / "log" / "envios"
        guarda.mkdir(parents=True, exist_ok=True)
        destino.replace(guarda / f"{destino.stem}.{time.strftime('%Y%m%d-%H%M%S')}{destino.suffix}")
    destino.write_bytes(conteudo)
    return {"ok": True, "midia_faltando": faltando}
