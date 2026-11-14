from __future__ import annotations

import pytest

from solumia_configurador import generate, secret_store, watch
from solumia_configurador.vault import Vault

from .test_engine_generate import _m


def test_check_address_accepts_only_local_network() -> None:
    assert watch.check_address("192.168.0.23", 41234) == "192.168.0.23:41234"
    assert watch.check_address("fd00::5", 5555) == "[fd00::5]:5555"
    for host in ("8.8.8.8", "127.0.0.1", "relogio.local", "192.168.0.23; rm -rf /"):
        with pytest.raises(watch.WatchError):
            watch.check_address(host, 5555)
    with pytest.raises(watch.WatchError):
        watch.check_address("192.168.0.23", 70000)


def test_pair_requires_six_digit_code() -> None:
    with pytest.raises(watch.WatchError):
        watch.pair("192.168.0.23", 40000, "12ab56")


def test_gateway_gets_the_watch_scoped_key(vault: Vault) -> None:
    vault.definir(secret_store.PASSWORD_HASH, secret_store.hash_password("SenhaForte123"))
    vault.definir(secret_store.TOTP, secret_store.totp_secret())
    env = generate.env_gateway(_m(), vault)
    key = generate.watch_key(vault)
    assert key.startswith("relogio_")
    line = next(line for line in env.splitlines() if line.startswith("GATEWAY_CLIENT_API_KEYS="))
    assert f",relogio:{key}" in line
    assert generate.watch_key(vault) == key  # reused, never regenerated
