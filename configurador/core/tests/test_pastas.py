from __future__ import annotations

from pathlib import Path

from solumia_configurador import pastas
from solumia_configurador.manifesto import Pastas


def _p(base: str, sep: str = "/") -> Pastas:
    return Pastas(**{k: f"{base}{sep}{k}" for k in pastas.ROTULOS})


def test_linux_valida_e_avisa_criacao(tmp_path: Path) -> None:
    r = pastas.validar(_p(str(tmp_path / "midia")), windows=False)
    assert r.ok, r.erros
    assert all("criada" in a[0] for a in r.avisos.values())
    criadas = pastas.criar(_p(str(tmp_path / "midia")))
    assert len(criadas) == 5 and all(Path(c).is_dir() for c in criadas)


def test_linux_recusa_relativo_sistema_e_aninhado(tmp_path: Path) -> None:
    p = _p(str(tmp_path))
    p.imagens = "relativo/img"
    p.videos = "/etc/solumia"
    p.audio = "/usr/share/x"
    p.producao = str(tmp_path / "prod")
    p.produzidos = str(tmp_path / "prod" / "saida")
    r = pastas.validar(p, windows=False)
    assert not r.ok
    assert "absoluto" in r.erros["imagens"][0]
    assert "sistema" in r.erros["videos"][0]
    assert "sistema" in r.erros["audio"][0]
    assert "dentro" in r.erros["produzidos"][0]


def test_linux_var_lib_e_mnt_permitidos() -> None:
    r = pastas.validar(Pastas(imagens="/var/lib/s/i", videos="/mnt/hd/v", audio="/media/x/a",
                              producao="/srv/p", produzidos="/data/s"), windows=False, local=False)
    assert r.ok, r.erros


def test_windows_forma(tmp_path: Path) -> None:
    ok = pastas.validar(_p("D:\\Midia", "\\"), windows=True, local=False)
    assert ok.ok, ok.erros
    ruim = _p("D:\\Midia", "\\")
    ruim.imagens = "C:\\Windows\\Temp\\x"
    ruim.videos = "E:\\"
    ruim.audio = "d:\\midia\\IMAGENS"  # igual ignorando maiúsculas? não: imagens mudou acima
    ruim.producao = "D:\\Midia\\produzidos\\x"
    r = pastas.validar(ruim, windows=True, local=False)
    assert "sistema" in r.erros["imagens"][0]
    assert "sistema" in r.erros["videos"][0]
    assert any("dentro" in e for e in r.erros["producao"])


def test_windows_mesma_pasta_com_caixa_diferente() -> None:
    p = _p("D:\\Midia", "\\")
    p.audio = "d:\\MIDIA\\videos"
    r = pastas.validar(p, windows=True, local=False)
    assert any("igual" in e for e in r.erros["audio"])


def test_sem_permissao(tmp_path: Path) -> None:
    trancada = tmp_path / "trancada"
    trancada.mkdir()
    trancada.chmod(0o500)
    try:
        r = pastas.validar(_p(str(trancada)), windows=False)
        assert not r.ok and "permissão" in next(iter(r.erros.values()))[0]
    finally:
        trancada.chmod(0o700)
