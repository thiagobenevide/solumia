from __future__ import annotations

from pathlib import Path

from solumia_configurador import folders
from solumia_configurador.manifest import Folders


def _p(base: str, sep: str = "/") -> Folders:
    return Folders(**{k: f"{base}{sep}{k}" for k in folders.LABELS})


def test_linux_validates_and_reports_creation(tmp_path: Path) -> None:
    r = folders.validate(_p(str(tmp_path / "midia")), windows=False)
    assert r.ok, r.erros
    assert all("criada" in a[0] for a in r.avisos.values())
    created = folders.create(_p(str(tmp_path / "midia")))
    assert len(created) == 5 and all(Path(c).is_dir() for c in created)


def test_linux_refuses_relative_system_and_nested(tmp_path: Path) -> None:
    p = _p(str(tmp_path))
    p.imagens = "relativo/img"
    p.videos = "/etc/solumia"
    p.audio = "/usr/share/x"
    p.producao = str(tmp_path / "prod")
    p.produzidos = str(tmp_path / "prod" / "saida")
    r = folders.validate(p, windows=False)
    assert not r.ok
    assert "absoluto" in r.erros["imagens"][0]
    assert "sistema" in r.erros["videos"][0]
    assert "sistema" in r.erros["audio"][0]
    assert "dentro" in r.erros["produzidos"][0]


def test_linux_var_lib_and_mnt_allowed() -> None:
    r = folders.validate(Folders(imagens="/var/lib/s/i", videos="/mnt/hd/v", audio="/media/x/a",
                              producao="/srv/p", produzidos="/data/s"), windows=False, local=False)
    assert r.ok, r.erros


def test_windows_form(tmp_path: Path) -> None:
    ok = folders.validate(_p("D:\\Midia", "\\"), windows=True, local=False)
    assert ok.ok, ok.erros
    bad = _p("D:\\Midia", "\\")
    bad.imagens = "C:\\Windows\\Temp\\x"
    bad.videos = "E:\\"
    bad.audio = "d:\\midia\\IMAGENS"  # equal ignoring case? no: imagens changed above

    bad.producao = "D:\\Midia\\produzidos\\x"
    r = folders.validate(bad, windows=True, local=False)
    assert "sistema" in r.erros["imagens"][0]
    assert "sistema" in r.erros["videos"][0]
    assert any("dentro" in e for e in r.erros["producao"])


def test_windows_same_folder_with_different_case() -> None:
    p = _p("D:\\Midia", "\\")
    p.audio = "d:\\MIDIA\\videos"
    r = folders.validate(p, windows=True, local=False)
    assert any("igual" in e for e in r.erros["audio"])


def test_without_permission(tmp_path: Path) -> None:
    locked = tmp_path / "trancada"
    locked.mkdir()
    locked.chmod(0o500)
    try:
        r = folders.validate(_p(str(locked)), windows=False)
        assert not r.ok and "permissão" in next(iter(r.erros.values()))[0]
    finally:
        locked.chmod(0o700)
