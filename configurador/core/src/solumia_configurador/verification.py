"""Integrity check of everything the configurator downloads.

Mandatory order before installing any file:
1. `SHA256SUMS` signed by a key whose fingerprint is PINNED in the catalog
   (the key downloaded from the release itself is only used if it matches the pinned fingerprint);
2. SHA-256 of the file equal to the one on the matching line of `SHA256SUMS`.

The signature is checked by `gpg` in its own temporary directory (it never touches the person's
keyring). Without `gpg` installed the installation is refused, unless the person explicitly turns
off the signature requirement in the catalog.
"""

from __future__ import annotations

import hashlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


class VerificationFailed(Exception):
    pass


_SUMS_LINE = re.compile(r"^([0-9a-f]{64})\s+\*?(.+)$")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def read_sums(text: str) -> dict[str, str]:
    sums: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = _SUMS_LINE.match(line)
        if not m:
            raise VerificationFailed(f"linha inválida em SHA256SUMS: {line[:80]!r}")
        name = m.group(2).strip()
        if name in sums and sums[name] != m.group(1):
            raise VerificationFailed(f"SHA256SUMS com duas somas para {name}")
        sums[name] = m.group(1)
    return sums


def check_file(path: Path, name: str, sums: dict[str, str]) -> str:
    expected = sums.get(name)
    if expected is None:
        raise VerificationFailed(f"{name} não está no SHA256SUMS")
    obtained = sha256(path)
    if obtained != expected:
        raise VerificationFailed(f"SHA-256 de {name} não confere (esperado {expected[:12]}…, obtido {obtained[:12]}…)")
    return obtained


def gpg_available() -> str | None:
    return shutil.which("gpg")


def check_signature(key_public: bytes, signature: Path, data: Path, fingerprints_accepted: list[str]) -> str:
    """Returns the fingerprint of the PRIMARY key that signed; raises if it is not an accepted one."""
    gpg = gpg_available()
    if gpg is None:
        raise VerificationFailed("gpg não encontrado: instale o GnuPG (Linux) ou Gpg4win (Windows)")
    accepted = {i.replace(" ", "").upper() for i in fingerprints_accepted}
    if not accepted:
        raise VerificationFailed("nenhuma impressão digital fixada para este app")
    with tempfile.TemporaryDirectory(prefix="solumia-gpg-") as matches:
        Path(matches).chmod(0o700)
        base = [gpg, "--homedir", matches, "--batch", "--no-tty", "--no-auto-key-retrieve"]
        imp = subprocess.run([*base, "--import"], input=key_public, capture_output=True, timeout=30)
        if imp.returncode != 0:
            raise VerificationFailed("chave pública da release inválida")
        r = subprocess.run(
            [*base, "--status-fd", "1", "--verify", str(signature), str(data)],
            capture_output=True, text=True, timeout=60,
        )
    valid = []
    for line in r.stdout.splitlines():
        parts = line.split()
        # [GNUPG:] VALIDSIG <subkey> <date> ... <primary>
        if len(parts) >= 3 and parts[1] == "VALIDSIG":
            valid.append(parts[-1].upper())
    if r.returncode != 0 or not valid:
        raise VerificationFailed("assinatura do SHA256SUMS inválida")
    for fingerprint in valid:
        if fingerprint in accepted:
            return fingerprint
    raise VerificationFailed(f"assinado por chave não fixada no catálogo ({valid[0][-16:]})")
