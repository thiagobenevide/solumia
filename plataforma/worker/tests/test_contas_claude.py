import asyncio
import os
import stat
from pathlib import Path

import pytest

from worker.contas_claude import PRINCIPAL, Contas

# `claude` falso: `auth status` diz logado só se a pasta da conta tiver `.credentials.json`;
# `auth login` mostra o link, lê o código e grava a credencial.
_FALSO = """#!/bin/sh
dir="${CLAUDE_CONFIG_DIR:-$PADRAO}"
if [ "$2" = status ]; then
  if [ -f "$dir/.credentials.json" ]; then
    echo '{"loggedIn": true, "email": "a@b.c", "subscriptionType": "pro"}'
  else
    echo '{"loggedIn": false}'
  fi
else
  u='https://claude.com/cai/oauth/authorize?code=true&x=1'
  printf 'visit: \\033]8;;%s\\007link\\033]8;;\\007\\r\\n> ' "$u"
  read codigo
  [ "$codigo" = certo ] && touch "$dir/.credentials.json"
  echo ok
fi
"""


@pytest.fixture
def contas(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Contas:
    binario = tmp_path / "claude"
    binario.write_text(_FALSO)
    binario.chmod(binario.stat().st_mode | stat.S_IEXEC)
    padrao = tmp_path / "padrao"
    (padrao / "projects").mkdir(parents=True)
    (padrao / ".credentials.json").touch()
    monkeypatch.setenv("PADRAO", str(padrao))
    monkeypatch.delenv("CLAUDE_CONFIG_DIR", raising=False)
    return Contas(str(tmp_path / "contas"), str(binario), str(padrao))


def test_entrar_ativar_e_remover(contas: Contas, tmp_path: Path) -> None:
    async def fluxo() -> None:
        assert (await contas.listar())["contas"][0]["logado"] is True
        url = (await contas.entrar("trabalho"))["url"]
        assert url == "https://claude.com/cai/oauth/authorize?code=true&x=1"
        assert (tmp_path / "contas/trabalho/projects").is_symlink()
        with pytest.raises(RuntimeError, match="não está logada"):
            await contas.ativar("trabalho")
        await contas.codigo("trabalho", "certo")
        lista = await contas.ativar("trabalho")
        assert lista["ativa"] == "trabalho"
        assert os.environ["CLAUDE_CONFIG_DIR"] == str(tmp_path / "contas/trabalho")
        lista = await contas.remover("trabalho")
        assert lista["ativa"] == PRINCIPAL and "CLAUDE_CONFIG_DIR" not in os.environ
        assert (tmp_path / "padrao/projects").is_dir()  # o link some, a pasta da principal fica

    asyncio.run(fluxo())


def test_codigo_errado_e_nome_invalido(contas: Contas) -> None:
    async def fluxo() -> None:
        await contas.entrar("outra")
        with pytest.raises(RuntimeError, match="não foi concluído"):
            await contas.codigo("outra", "errado")
        with pytest.raises(RuntimeError, match="inválido"):
            await contas.entrar("../fora")
        with pytest.raises(RuntimeError, match="principal"):
            await contas.remover(PRINCIPAL)

    asyncio.run(fluxo())
