"""Verificação de integridade de tudo que o configurador baixa.

Ordem obrigatória antes de instalar qualquer arquivo:
1. `SHA256SUMS` assinado por uma chave cuja impressão digital está FIXADA no catálogo
   (a chave baixada da própria release só é usada se bater com a impressão fixada);
2. SHA-256 do arquivo igual ao da linha correspondente em `SHA256SUMS`.

A assinatura é conferida pelo `gpg` num diretório temporário próprio (não toca no chaveiro da
pessoa). Sem `gpg` instalado a instalação é recusada, a não ser que a pessoa desligue a exigência
de assinatura de forma explícita no catálogo.
"""

from __future__ import annotations

import hashlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


class VerificacaoFalhou(Exception):
    pass


_LINHA_SUMS = re.compile(r"^([0-9a-f]{64})\s+\*?(.+)$")


def sha256(caminho: Path) -> str:
    h = hashlib.sha256()
    with caminho.open("rb") as f:
        for bloco in iter(lambda: f.read(1 << 20), b""):
            h.update(bloco)
    return h.hexdigest()


def ler_sums(texto: str) -> dict[str, str]:
    somas: dict[str, str] = {}
    for linha in texto.splitlines():
        linha = linha.strip()
        if not linha or linha.startswith("#"):
            continue
        m = _LINHA_SUMS.match(linha)
        if not m:
            raise VerificacaoFalhou(f"linha inválida em SHA256SUMS: {linha[:80]!r}")
        nome = m.group(2).strip()
        if nome in somas and somas[nome] != m.group(1):
            raise VerificacaoFalhou(f"SHA256SUMS com duas somas para {nome}")
        somas[nome] = m.group(1)
    return somas


def conferir_arquivo(caminho: Path, nome: str, somas: dict[str, str]) -> str:
    esperado = somas.get(nome)
    if esperado is None:
        raise VerificacaoFalhou(f"{nome} não está no SHA256SUMS")
    obtido = sha256(caminho)
    if obtido != esperado:
        raise VerificacaoFalhou(f"SHA-256 de {nome} não confere (esperado {esperado[:12]}…, obtido {obtido[:12]}…)")
    return obtido


def gpg_disponivel() -> str | None:
    return shutil.which("gpg")


def conferir_assinatura(chave_publica: bytes, assinatura: Path, dados: Path, impressoes_aceitas: list[str]) -> str:
    """Devolve a impressão digital da chave PRIMÁRIA que assinou; levanta se não for uma aceita."""
    gpg = gpg_disponivel()
    if gpg is None:
        raise VerificacaoFalhou("gpg não encontrado: instale o GnuPG (Linux) ou Gpg4win (Windows)")
    aceitas = {i.replace(" ", "").upper() for i in impressoes_aceitas}
    if not aceitas:
        raise VerificacaoFalhou("nenhuma impressão digital fixada para este app")
    with tempfile.TemporaryDirectory(prefix="solumia-gpg-") as casa:
        Path(casa).chmod(0o700)
        base = [gpg, "--homedir", casa, "--batch", "--no-tty", "--no-auto-key-retrieve"]
        imp = subprocess.run([*base, "--import"], input=chave_publica, capture_output=True, timeout=30)
        if imp.returncode != 0:
            raise VerificacaoFalhou("chave pública da release inválida")
        r = subprocess.run(
            [*base, "--status-fd", "1", "--verify", str(assinatura), str(dados)],
            capture_output=True, text=True, timeout=60,
        )
    validas = []
    for linha in r.stdout.splitlines():
        partes = linha.split()
        # [GNUPG:] VALIDSIG <subchave> <data> ... <primária>
        if len(partes) >= 3 and partes[1] == "VALIDSIG":
            validas.append(partes[-1].upper())
    if r.returncode != 0 or not validas:
        raise VerificacaoFalhou("assinatura do SHA256SUMS inválida")
    for impressao in validas:
        if impressao in aceitas:
            return impressao
    raise VerificacaoFalhou(f"assinado por chave não fixada no catálogo ({validas[0][-16:]})")
