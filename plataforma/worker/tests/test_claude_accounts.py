import asyncio
import os
import stat
from pathlib import Path

import pytest

from worker.claude_accounts import MAIN, Accounts

# Fake `claude`: `auth status` reports logged in only if the account folder has `.credentials.json`;
# `auth login` shows the link, reads the code and writes the credential.
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
def contas(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Accounts:
    binario = tmp_path / "claude"
    binario.write_text(_FALSO)
    binario.chmod(binario.stat().st_mode | stat.S_IEXEC)
    default = tmp_path / "padrao"
    (default / "projects").mkdir(parents=True)
    (default / ".credentials.json").touch()
    monkeypatch.setenv("PADRAO", str(default))
    monkeypatch.delenv("CLAUDE_CONFIG_DIR", raising=False)
    return Accounts(str(tmp_path / "contas"), str(binario), str(default))


def test_login_activate_and_remove(contas: Accounts, tmp_path: Path) -> None:
    async def fluxo() -> None:
        assert (await contas.list_all())["contas"][0]["logado"] is True
        url = (await contas.enter("trabalho"))["url"]
        assert url == "https://claude.com/cai/oauth/authorize?code=true&x=1"
        assert (tmp_path / "contas/trabalho/projects").is_symlink()
        with pytest.raises(RuntimeError, match="não está logada"):
            await contas.activate("trabalho")
        await contas.codigo("trabalho", "certo")
        items = await contas.activate("trabalho")
        assert items["ativa"] == "trabalho"
        assert os.environ["CLAUDE_CONFIG_DIR"] == str(tmp_path / "contas/trabalho")
        items = await contas.remover("trabalho")
        assert items["ativa"] == MAIN and "CLAUDE_CONFIG_DIR" not in os.environ
        # the link goes away, the principal's folder stays
        assert (tmp_path / "padrao/projects").is_dir()

    asyncio.run(fluxo())


def test_wrong_code_and_invalid_name(contas: Accounts) -> None:
    async def fluxo() -> None:
        await contas.enter("outra")
        with pytest.raises(RuntimeError, match="não foi concluído"):
            await contas.codigo("outra", "errado")
        with pytest.raises(RuntimeError, match="inválido"):
            await contas.enter("../fora")
        with pytest.raises(RuntimeError, match="principal"):
            await contas.remover(MAIN)

    asyncio.run(fluxo())
