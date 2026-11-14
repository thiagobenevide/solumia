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


_SEM_COMPRESS = {".mov", ".mp4", ".mkv", ".webm", ".png", ".jpg", ".jpeg", ".webp", ".mp3", ".m4a", ".zst"}


def _nodes_with_path(no):
    """Dicionários com `"path"` (string) em qualquer nível do JSON."""
    if isinstance(no, dict):
        if isinstance(no.get("path"), str):
            yield no
        for v in no.values():
            yield from _nodes_with_path(v)
    elif isinstance(no, list):
        for v in no:
            yield from _nodes_with_path(v)


def _relativize(dados, arquivo: Path, pasta: Path):
    """Troca os caminhos da mídia dentro do episódio por relativos a `arquivo`; devolve a mídia a empacotar."""
    media = {}
    for no in _nodes_with_path(dados):
        c = Path(no["path"])
        if c.is_absolute() and c.is_file() and c.is_relative_to(pasta):
            no["path"] = os.path.relpath(c, arquivo.parent)
            media[c] = c.relative_to(pasta)
    return media


class _Output(io.RawIOBase):
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
        data, self.buf = bytes(self.buf), bytearray()
        return data


def pack(arquivo: Path, pasta: Path, nome: str) -> Iterator[bytes]:
    """Zip em fluxo `nome/<caminho no episódio>` com o arquivo (caminhos relativos) e a mídia que ele usa.

    Em fluxo porque o pacote do FilmCraft passa de 1 GB e a Cloudflare corta resposta que demora a começar.
    """
    arquivo = Path(arquivo)
    data = json.loads(arquivo.read_text())
    media = _relativize(data, arquivo, pasta)
    output = _Output()
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as z:
        z.writestr(f"{nome}/{arquivo.relative_to(pasta)}", json.dumps(data, ensure_ascii=False, indent=1))
        yield output.tirar()
        for origin, rel in sorted(media.items()):
            info = zipfile.ZipInfo.from_file(origin, f"{nome}/{rel}")
            info.compress_type = zipfile.ZIP_STORED if origin.suffix.lower() in _SEM_COMPRESS else zipfile.ZIP_DEFLATED
            with open(origin, "rb") as ent, z.open(info, "w", force_zip64=True) as sai:
                while block := ent.read(1 << 20):
                    sai.write(block)
                    yield output.tirar()
    yield output.tirar()


def _reconnect(dados, destino: Path, pasta: Path):
    """Volta os caminhos para a pasta do episódio; devolve quantos não foram achados."""
    mark = f"/{pasta.parent.name}/{pasta.name}/"
    names = None
    missing = 0
    for no in _nodes_with_path(dados):
        raw = no["path"].replace("\\", "/")  # caminho do Windows também
        c = Path(raw)
        if c.is_absolute() and c.is_file():
            continue
        if not c.is_absolute():
            found = (destino.parent / c).resolve()
        elif mark in raw:
            found = pasta / raw.split(mark, 1)[1]
        else:
            found = None
        if not (found and found.is_file()):
            if names is None:
                names = {}
                for f in pasta.rglob("*"):
                    names.setdefault(f.name, f)
            found = names.get(c.name)
        if found and found.is_file():
            no["path"] = str(found)
        else:
            missing += 1
    return missing


def _extract(content: bytes, sufixo: str) -> bytes:
    """Aceita o próprio arquivo ou um zip que o contenha (o pacote baixado, recompactado)."""
    if not zipfile.is_zipfile(io.BytesIO(content)):
        return content
    with zipfile.ZipFile(io.BytesIO(content)) as z:
        names = z.namelist()
        if sufixo == ".pcraft" and "manifest.json" in names:
            return content
        target = [n for n in names if n.lower().endswith(sufixo)]
        if len(target) != 1:
            raise ValueError(f"o zip precisa ter exatamente um {sufixo} (tem {len(target)})")
        return z.read(target[0])


def receive(content: bytes, destino: Path, pasta: Path) -> dict:
    """Grava a edição enviada no lugar de `destino` (guardando o anterior); devolve mídia não achada."""
    destino = Path(destino)
    content = _extract(content, destino.suffix)
    missing = 0
    if destino.suffix == ".pcraft":
        if not zipfile.is_zipfile(io.BytesIO(content)) or \
                "manifest.json" not in zipfile.ZipFile(io.BytesIO(content)).namelist():
            raise ValueError("não é um .pcraft do PhotoCraft")
    else:
        try:
            data = json.loads(content)
        except ValueError as e:
            raise ValueError(f"não é um {destino.suffix} válido") from e
        missing = _reconnect(data, destino, pasta)
        content = json.dumps(data, ensure_ascii=False, indent=1).encode()
    if destino.exists():
        guarda = pasta / "log" / "envios"
        guarda.mkdir(parents=True, exist_ok=True)
        destino.replace(guarda / f"{destino.stem}.{time.strftime('%Y%m%d-%H%M%S')}{destino.suffix}")
    destino.write_bytes(content)
    return {"ok": True, "midia_faltando": missing}
