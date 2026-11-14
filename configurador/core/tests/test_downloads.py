from __future__ import annotations

import io
import subprocess
import zipfile
from pathlib import Path

import httpx
import pytest

from solumia_configurador import craft_apps, verification
from solumia_configurador.platform_setup import System

LINUX = System("linux", "x86_64")
WIN = System("windows", "x86_64")


def test_catalog_points_to_the_right_github() -> None:
    assert set(craft_apps.CATALOG) == {"filmcraft", "soundcraft", "effectcraft", "photocraft"}
    for app in craft_apps.CATALOG.values():
        assert app.url_github == f"https://github.com/storytold/{app.id}"
        assert app.exigir_assinatura and app.impressoes == (craft_apps.ARTCRAFT_FINGERPRINT,)


def test_file_name_per_system() -> None:
    assert craft_apps.file_name("filmcraft", "0.20.1", LINUX) == "filmcraft-0.20.1-linux-x86_64.AppImage"
    assert craft_apps.file_name("photocraft", "0.23.1", WIN) == "photocraft-0.23.1-windows-x64-portable.zip"
    assert craft_apps.file_name("soundcraft", "1.0.0", WIN, "msi") == "soundcraft-1.0.0-windows-x64.msi"
    with pytest.raises(craft_apps.CraftError):
        craft_apps.file_name("filmcraft", "1.0.0", WIN, "appimage")
    with pytest.raises(craft_apps.CraftError):
        craft_apps.fetch_release("app-qualquer")


def test_host_outside_the_list_refused() -> None:
    with pytest.raises(craft_apps.CraftError, match="não permitido"):
        craft_apps._check_host(httpx.Request("GET", "https://evil.example.com/x"))
    with pytest.raises(craft_apps.CraftError):
        craft_apps._check_host(httpx.Request("GET", "http://github.com/x"))
    craft_apps._check_host(httpx.Request("GET", "https://objects.githubusercontent.com/x"))


def test_zip_slip_refused(tmp_path: Path) -> None:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("../../fora.txt", "x")
    file = tmp_path / "mal.zip"
    file.write_bytes(buf.getvalue())
    with pytest.raises(craft_apps.CraftError, match="fora"):
        craft_apps._extract_zip(file, tmp_path / "dest")
    assert not (tmp_path.parent / "fora.txt").exists()


def test_sha256sums(tmp_path: Path) -> None:
    file = tmp_path / "a.bin"
    file.write_bytes(b"conteudo")
    total = verification.sha256(file)
    sums = verification.read_sums(f"{total}  a.bin\n{'0' * 64}  b.bin\n")
    assert verification.check_file(file, "a.bin", sums) == total
    file.write_bytes(b"adulterado")
    with pytest.raises(verification.VerificationFailed, match="não confere"):
        verification.check_file(file, "a.bin", sums)
    with pytest.raises(verification.VerificationFailed):
        verification.check_file(file, "c.bin", sums)
    with pytest.raises(verification.VerificationFailed):
        verification.read_sums("lixo")


def _gpg_key(casa: Path, nome: str) -> tuple[bytes, str]:
    casa.mkdir(mode=0o700)
    base = ["gpg", "--homedir", str(casa), "--batch", "--pinentry-mode", "loopback", "--passphrase", ""]
    subprocess.run([*base, "--quick-gen-key", nome, "ed25519", "sign", "never"], check=True, capture_output=True)
    pub = subprocess.run([*base, "--armor", "--export"], check=True, capture_output=True).stdout
    fpr = [line.split(":")[9] for line in subprocess.run(
        [*base, "--with-colons", "--list-keys"], check=True, capture_output=True, text=True).stdout.splitlines()
        if line.startswith("fpr")][0]
    return pub, fpr


@pytest.mark.skipif(verification.gpg_available() is None, reason="gpg ausente")
def test_signature_only_accepts_pinned_key(tmp_path: Path) -> None:
    pub, fpr = _gpg_key(tmp_path / "boa", "Teste Bom <b@t>")
    pub_bad, fpr_bad = _gpg_key(tmp_path / "ma", "Atacante <a@t>")
    data = tmp_path / "SHA256SUMS.txt"
    data.write_text("x\n")
    for matches, output in ((tmp_path / "boa", "boa.asc"), (tmp_path / "ma", "ma.asc")):
        subprocess.run(["gpg", "--homedir", str(matches), "--batch", "--pinentry-mode", "loopback", "--passphrase", "",
                        "--armor", "--detach-sign", "-o", str(tmp_path / output), str(data)], check=True,
                       capture_output=True)
    assert verification.check_signature(pub, tmp_path / "boa.asc", data, [fpr]) == fpr
    # An attacker publishes their own key in the release: refused because it is not the pinned one.
    with pytest.raises(verification.VerificationFailed, match="não fixada"):
        verification.check_signature(pub_bad, tmp_path / "ma.asc", data, [fpr])
    data.write_text("adulterado\n")
    with pytest.raises(verification.VerificationFailed, match="inválida"):
        verification.check_signature(pub, tmp_path / "boa.asc", data, [fpr])
    assert fpr_bad != fpr


def test_solumia_apps_blocked_without_pinned_key(monkeypatch):
    from solumia_configurador import solumia_apps
    from solumia_configurador.craft_apps import CraftError
    from solumia_configurador.platform_setup import System

    monkeypatch.setattr(solumia_apps, "SOLUMIA_FINGERPRINTS", ())
    with pytest.raises(CraftError, match="bloqueado"):
        solumia_apps.download("android", System("linux", "x86_64"))


def test_solumia_apps_install_only_on_the_right_system():
    from solumia_configurador import solumia_apps
    from solumia_configurador.platform_setup import System

    linux = System("linux", "x86_64")
    assert solumia_apps.installs_here(solumia_apps.CATALOG["linux"], linux)
    assert not solumia_apps.installs_here(solumia_apps.CATALOG["windows"], linux)
    assert not solumia_apps.installs_here(solumia_apps.CATALOG["android"], linux)
    assert solumia_apps.CATALOG["wear"].arquivo("1.2.3") == "solumia-1.2.3-wear.apk"
