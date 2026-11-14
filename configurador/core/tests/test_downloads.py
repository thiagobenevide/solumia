from __future__ import annotations

import io
import subprocess
import zipfile
from pathlib import Path

import httpx
import pytest

from solumia_configurador import craft_apps, verificacao
from solumia_configurador.plataforma import Sistema

LINUX = Sistema("linux", "x86_64")
WIN = Sistema("windows", "x86_64")


def test_catalogo_aponta_para_o_github_certo() -> None:
    assert set(craft_apps.CATALOGO) == {"filmcraft", "soundcraft", "effectcraft", "photocraft"}
    for app in craft_apps.CATALOGO.values():
        assert app.url_github == f"https://github.com/storytold/{app.id}"
        assert app.exigir_assinatura and app.impressoes == (craft_apps.IMPRESSAO_ARTCRAFT,)


def test_nome_do_arquivo_por_sistema() -> None:
    assert craft_apps.nome_arquivo("filmcraft", "0.20.1", LINUX) == "filmcraft-0.20.1-linux-x86_64.AppImage"
    assert craft_apps.nome_arquivo("photocraft", "0.23.1", WIN) == "photocraft-0.23.1-windows-x64-portable.zip"
    assert craft_apps.nome_arquivo("soundcraft", "1.0.0", WIN, "msi") == "soundcraft-1.0.0-windows-x64.msi"
    with pytest.raises(craft_apps.CraftErro):
        craft_apps.nome_arquivo("filmcraft", "1.0.0", WIN, "appimage")
    with pytest.raises(craft_apps.CraftErro):
        craft_apps.buscar_release("app-qualquer")


def test_host_fora_da_lista_recusado() -> None:
    with pytest.raises(craft_apps.CraftErro, match="não permitido"):
        craft_apps._conferir_host(httpx.Request("GET", "https://evil.example.com/x"))
    with pytest.raises(craft_apps.CraftErro):
        craft_apps._conferir_host(httpx.Request("GET", "http://github.com/x"))
    craft_apps._conferir_host(httpx.Request("GET", "https://objects.githubusercontent.com/x"))


def test_zip_slip_recusado(tmp_path: Path) -> None:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("../../fora.txt", "x")
    arq = tmp_path / "mal.zip"
    arq.write_bytes(buf.getvalue())
    with pytest.raises(craft_apps.CraftErro, match="fora"):
        craft_apps._extrair_zip(arq, tmp_path / "dest")
    assert not (tmp_path.parent / "fora.txt").exists()


def test_sha256sums(tmp_path: Path) -> None:
    arq = tmp_path / "a.bin"
    arq.write_bytes(b"conteudo")
    soma = verificacao.sha256(arq)
    somas = verificacao.ler_sums(f"{soma}  a.bin\n{'0' * 64}  b.bin\n")
    assert verificacao.conferir_arquivo(arq, "a.bin", somas) == soma
    arq.write_bytes(b"adulterado")
    with pytest.raises(verificacao.VerificacaoFalhou, match="não confere"):
        verificacao.conferir_arquivo(arq, "a.bin", somas)
    with pytest.raises(verificacao.VerificacaoFalhou):
        verificacao.conferir_arquivo(arq, "c.bin", somas)
    with pytest.raises(verificacao.VerificacaoFalhou):
        verificacao.ler_sums("lixo")


def _gpg_chave(casa: Path, nome: str) -> tuple[bytes, str]:
    casa.mkdir(mode=0o700)
    base = ["gpg", "--homedir", str(casa), "--batch", "--pinentry-mode", "loopback", "--passphrase", ""]
    subprocess.run([*base, "--quick-gen-key", nome, "ed25519", "sign", "never"], check=True, capture_output=True)
    pub = subprocess.run([*base, "--armor", "--export"], check=True, capture_output=True).stdout
    fpr = [linha.split(":")[9] for linha in subprocess.run(
        [*base, "--with-colons", "--list-keys"], check=True, capture_output=True, text=True).stdout.splitlines()
        if linha.startswith("fpr")][0]
    return pub, fpr


@pytest.mark.skipif(verificacao.gpg_disponivel() is None, reason="gpg ausente")
def test_assinatura_so_aceita_chave_fixada(tmp_path: Path) -> None:
    pub, fpr = _gpg_chave(tmp_path / "boa", "Teste Bom <b@t>")
    pub_mal, fpr_mal = _gpg_chave(tmp_path / "ma", "Atacante <a@t>")
    dados = tmp_path / "SHA256SUMS.txt"
    dados.write_text("x\n")
    for casa, saida in ((tmp_path / "boa", "boa.asc"), (tmp_path / "ma", "ma.asc")):
        subprocess.run(["gpg", "--homedir", str(casa), "--batch", "--pinentry-mode", "loopback", "--passphrase", "",
                        "--armor", "--detach-sign", "-o", str(tmp_path / saida), str(dados)], check=True,
                       capture_output=True)
    assert verificacao.conferir_assinatura(pub, tmp_path / "boa.asc", dados, [fpr]) == fpr
    # Atacante publica a própria chave na release: recusado porque não é a fixada.
    with pytest.raises(verificacao.VerificacaoFalhou, match="não fixada"):
        verificacao.conferir_assinatura(pub_mal, tmp_path / "ma.asc", dados, [fpr])
    dados.write_text("adulterado\n")
    with pytest.raises(verificacao.VerificacaoFalhou, match="inválida"):
        verificacao.conferir_assinatura(pub, tmp_path / "boa.asc", dados, [fpr])
    assert fpr_mal != fpr


def test_apps_solumia_bloqueado_sem_chave_fixada(monkeypatch):
    from solumia_configurador import apps_solumia
    from solumia_configurador.craft_apps import CraftErro
    from solumia_configurador.plataforma import Sistema

    monkeypatch.setattr(apps_solumia, "IMPRESSOES_SOLUMIA", ())
    with pytest.raises(CraftErro, match="bloqueado"):
        apps_solumia.baixar("android", Sistema("linux", "x86_64"))


def test_apps_solumia_instalar_so_no_sistema_certo():
    from solumia_configurador import apps_solumia
    from solumia_configurador.plataforma import Sistema

    linux = Sistema("linux", "x86_64")
    assert apps_solumia.instala_aqui(apps_solumia.CATALOGO["linux"], linux)
    assert not apps_solumia.instala_aqui(apps_solumia.CATALOGO["windows"], linux)
    assert not apps_solumia.instala_aqui(apps_solumia.CATALOGO["android"], linux)
    assert apps_solumia.CATALOGO["wear"].arquivo("1.2.3") == "solumia-1.2.3-wear.apk"
