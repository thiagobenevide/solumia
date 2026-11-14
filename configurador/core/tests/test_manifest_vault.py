from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

from solumia_configurador import manifest, secret_store
from solumia_configurador.manifest import Manifest
from solumia_configurador.vault import Vault, VaultError

from .conftest import ChaveFixa


def _hybrid(**extra) -> dict:
    base = {
        "topologia": {"tipo": "hibrida", "dominio": "solumia.exemplo.com", "email_tls": "a@b.com"},
        "nos": {
            "casa": {"endereco": "local", "papeis": ["worker", "pipeline"]},
            "vps": {"endereco": "ssh", "ssh": {"host": "203.0.113.5"}, "papeis": ["gateway", "tunnel", "collabora"]},
        },
    }
    base.update(extra)
    return base


def test_hybrid_manifest_valid_and_round_trip(tmp_path: Path) -> None:
    m = Manifest.model_validate(_hybrid())
    path = tmp_path / "solumia.toml"
    manifest.save(m, path)
    assert manifest.load(path) == m
    assert "senha" not in path.read_text().lower()


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
def test_manifest_refuses_invalid_combinations(mudanca: dict, erro: str) -> None:
    with pytest.raises(ValueError, match=erro):
        Manifest.model_validate(_hybrid(**mudanca))


def test_malicious_domain_and_host_refused() -> None:
    with pytest.raises(ValueError):
        manifest.Topologia(tipo="nuvem", dominio="x.com; rm -rf /")
    with pytest.raises(ValueError):
        manifest.SSHAccess(host="1.2.3.4 -oProxyCommand=evil")
    with pytest.raises(ValueError):
        manifest.SSHAccess(host="x", usuario="root;id")


def test_vault_encrypted_on_disk_and_permission(tmp_path: Path, vault: Vault) -> None:
    vault.definir("api", "valor-super-secreto-123")
    raw = vault.path.read_text()
    assert "valor-super-secreto" not in raw
    assert (vault.path.stat().st_mode & 0o777) == 0o600
    assert "valor" not in repr(vault)
    reopened = Vault(vault.path, ChaveFixa()).open_file()
    assert reopened.obter("api") == "valor-super-secreto-123"


def test_vault_wrong_key_or_tampered(tmp_path: Path, vault: Vault) -> None:
    vault.definir("a", "b")
    with pytest.raises(VaultError, match="adulterado"):
        Vault(vault.path, ChaveFixa(b"x" * 32)).open_file()
    data = json.loads(vault.path.read_text())
    data["dados"] = data["dados"][:-4] + "AAAA"
    vault.path.write_text(json.dumps(data))
    with pytest.raises(VaultError):
        Vault(vault.path, ChaveFixa()).open_file()


def test_vault_with_passphrase(tmp_path: Path) -> None:
    path = tmp_path / "f.cofre"
    Vault.with_passphrase(path, "frase longa de teste").open_file().definir("x", "y")
    assert Vault.with_passphrase(path, "frase longa de teste").open_file().obter("x") == "y"
    with pytest.raises(VaultError):
        Vault.with_passphrase(path, "frase errada de teste").open_file()


def _backend_security():
    root = Path(__file__).resolve().parents[3]
    file = root / "plataforma/backend/src/backend/auth/security.py"
    if not file.exists():
        pytest.skip("backend não encontrado")
    spec = importlib.util.spec_from_file_location("seguranca_backend", file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_hash_and_totp_compatible_with_the_gateway() -> None:
    backend = _backend_security()
    h = secret_store.hash_password("SenhaForte123")
    assert backend.verify_password("SenhaForte123", h)
    assert not backend.verify_password("errada", h)
    s = secret_store.totp_secret()
    assert secret_store.totp_code(s, 1000) == backend.code_totp(s, 1000)


def test_weak_password() -> None:
    assert secret_store.check_password("curta")
    assert not secret_store.check_password("SenhaForte123")


def test_generated_ssh_key() -> None:
    private, public = secret_store.generate_ssh_key()
    assert public.startswith("ssh-ed25519 ")
    assert secret_store.public_key_of(private) == public
