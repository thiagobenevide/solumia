from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

from solumia_configurador import manifesto, segredos
from solumia_configurador.cofre import Cofre, CofreErro
from solumia_configurador.manifesto import Manifesto

from .conftest import ChaveFixa


def _hibrido(**extra) -> dict:
    base = {
        "topologia": {"tipo": "hibrida", "dominio": "solumia.exemplo.com", "email_tls": "a@b.com"},
        "nos": {
            "casa": {"endereco": "local", "papeis": ["worker", "pipeline"]},
            "vps": {"endereco": "ssh", "ssh": {"host": "203.0.113.5"}, "papeis": ["gateway", "tunnel", "collabora"]},
        },
    }
    base.update(extra)
    return base


def test_manifesto_hibrido_valido_e_ida_e_volta(tmp_path: Path) -> None:
    m = Manifesto.model_validate(_hibrido())
    caminho = tmp_path / "solumia.toml"
    manifesto.salvar(m, caminho)
    assert manifesto.carregar(caminho) == m
    assert "senha" not in caminho.read_text().lower()


@pytest.mark.parametrize(
    "mudanca, erro",
    [
        ({"topologia": {"tipo": "hibrida"}}, "domínio"),
        ({"topologia": {"tipo": "nuvem", "dominio": "x.com"}, "ia": {"local": {"ativa": True}}}, "GPU"),
        ({"nos": {"a": {"papeis": ["worker"]}}}, "gateway"),
        ({"nos": {"a": {"papeis": ["gateway", "tunnel"]}}}, "tunnel"),
        ({"nos": {"a": {"endereco": "ssh", "papeis": ["gateway"]}}}, "host"),
        ({"chave_errada": 1}, "Extra"),
    ],
)
def test_manifesto_recusa_combinacoes_invalidas(mudanca: dict, erro: str) -> None:
    with pytest.raises(ValueError, match=erro):
        Manifesto.model_validate(_hibrido(**mudanca))


def test_dominio_e_host_maliciosos_recusados() -> None:
    with pytest.raises(ValueError):
        manifesto.Topologia(tipo="nuvem", dominio="x.com; rm -rf /")
    with pytest.raises(ValueError):
        manifesto.AcessoSSH(host="1.2.3.4 -oProxyCommand=evil")
    with pytest.raises(ValueError):
        manifesto.AcessoSSH(host="x", usuario="root;id")


def test_cofre_cifrado_em_disco_e_permissao(tmp_path: Path, cofre: Cofre) -> None:
    cofre.definir("api", "valor-super-secreto-123")
    bruto = cofre.caminho.read_text()
    assert "valor-super-secreto" not in bruto
    assert (cofre.caminho.stat().st_mode & 0o777) == 0o600
    assert "valor" not in repr(cofre)
    reaberto = Cofre(cofre.caminho, ChaveFixa()).abrir()
    assert reaberto.obter("api") == "valor-super-secreto-123"


def test_cofre_chave_errada_ou_adulterado(tmp_path: Path, cofre: Cofre) -> None:
    cofre.definir("a", "b")
    with pytest.raises(CofreErro, match="adulterado"):
        Cofre(cofre.caminho, ChaveFixa(b"x" * 32)).abrir()
    dados = json.loads(cofre.caminho.read_text())
    dados["dados"] = dados["dados"][:-4] + "AAAA"
    cofre.caminho.write_text(json.dumps(dados))
    with pytest.raises(CofreErro):
        Cofre(cofre.caminho, ChaveFixa()).abrir()


def test_cofre_com_frase(tmp_path: Path) -> None:
    caminho = tmp_path / "f.cofre"
    Cofre.com_frase(caminho, "frase longa de teste").abrir().definir("x", "y")
    assert Cofre.com_frase(caminho, "frase longa de teste").abrir().obter("x") == "y"
    with pytest.raises(CofreErro):
        Cofre.com_frase(caminho, "frase errada de teste").abrir()


def _seguranca_do_backend():
    raiz = Path(__file__).resolve().parents[3]
    arquivo = raiz / "plataforma/backend/src/backend/auth/security.py"
    if not arquivo.exists():
        pytest.skip("backend não encontrado")
    spec = importlib.util.spec_from_file_location("seguranca_backend", arquivo)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_hash_e_totp_compativeis_com_o_gateway() -> None:
    backend = _seguranca_do_backend()
    h = segredos.hash_senha("SenhaForte123")
    assert backend.verify_password("SenhaForte123", h)
    assert not backend.verify_password("errada", h)
    s = segredos.segredo_totp()
    assert segredos.codigo_totp(s, 1000) == backend.code_totp(s, 1000)


def test_senha_fraca() -> None:
    assert segredos.validar_senha("curta")
    assert not segredos.validar_senha("SenhaForte123")


def test_chave_ssh_gerada() -> None:
    privada, publica = segredos.gerar_chave_ssh()
    assert publica.startswith("ssh-ed25519 ")
    assert segredos.publica_de(privada) == publica
