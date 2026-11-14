import subprocess
import sys

import pytest

from esteira.nucleo import tela


def _sem_tela(monkeypatch, saida):
    monkeypatch.delenv("DISPLAY", raising=False)
    monkeypatch.delenv("WAYLAND_DISPLAY", raising=False)
    monkeypatch.setattr(tela.subprocess, "run", lambda *a, **k: subprocess.CompletedProcess(a, 0, stdout=saida))


def test_servico_sem_display_usa_a_sessao_do_systemd(monkeypatch):
    _sem_tela(monkeypatch, "PATH=/bin\nDISPLAY=:0\nXAUTHORITY=/home/x/.Xauthority\n")
    env = tela._ambiente()
    assert env["DISPLAY"] == ":0" and env["XAUTHORITY"] == "/home/x/.Xauthority"
    assert env["PATH"] != "/bin"


def test_sem_sessao_grafica_avisa(monkeypatch):
    _sem_tela(monkeypatch, "PATH=/bin\n")
    with pytest.raises(tela.SemTela, match="sessão gráfica"):
        tela.abrir_programa("filmcraft", "x.fcproj")


def test_programa_que_cai_ao_abrir_avisa(monkeypatch):
    monkeypatch.setenv("DISPLAY", ":0")
    with pytest.raises(tela.SemTela, match="código 3"):
        tela.abrir_programa(sys.executable, "-c", "raise SystemExit(3)")


def test_saida_limpa_nao_e_erro(monkeypatch):
    monkeypatch.setenv("DISPLAY", ":0")
    tela.abrir_programa(sys.executable, "-c", "pass")
