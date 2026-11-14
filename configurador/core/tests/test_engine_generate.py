from __future__ import annotations

import io
import tarfile
from pathlib import Path

import pytest

from solumia_configurador import generate, names, secret_store
from solumia_configurador.engine import Execucao, Mask, Plan, Step, list_runs
from solumia_configurador.manifest import Manifest
from solumia_configurador.vault import Vault


def test_plan_runs_skips_and_masks(tmp_path: Path) -> None:
    done = []
    p = Plan("t", [
        Step("a", "A", executar=lambda c: (done.append("a"), c.log("token=SEGREDO-123456"))),
        Step("b", "B", executar=lambda c: done.append("b"), ja_feito=lambda c: True),
    ])
    ex = Execucao(p, tmp_path, Mask(lambda: ["SEGREDO-123456"]))
    assert ex.rodar() == "concluida"
    assert done == ["a"]
    texts = " ".join(e["texto"] for e in ex.events_since(0))
    assert "SEGREDO" not in texts and "•••" in texts
    assert "SEGREDO" not in next(tmp_path.glob("*.jsonl")).read_text()
    assert list_runs(tmp_path)[0]["estado"] == "concluida"


def test_resume_skips_finished_but_not_always_steps(tmp_path: Path) -> None:
    count = {"con": 0, "a": 0, "b": 0}
    fail = {"b": True}

    def b(_c) -> None:
        count["b"] += 1
        if fail["b"]:
            raise RuntimeError("caiu")

    def plano() -> Plan:
        return Plan("r", [
            Step("con", "Conectar", executar=lambda c: count.__setitem__("con", count["con"] + 1), sempre=True),
            Step("a", "A", executar=lambda c: count.__setitem__("a", count["a"] + 1)),
            Step("b", "B", executar=b),
        ])

    assert Execucao(plano(), tmp_path).rodar() == "falhou"
    fail["b"] = False
    import time
    time.sleep(1.1)  # the run id has one-second resolution
    assert Execucao(plano(), tmp_path).rodar() == "concluida"
    assert count == {"con": 2, "a": 1, "b": 2}


def test_plan_hash_changes_with_steps() -> None:
    a = Plan("x", [Step("a", "A")])
    b = Plan("x", [Step("a", "A", detalhe="outro")])
    assert a.hash != b.hash


def test_source_package_without_secrets() -> None:
    root = generate.repository_root()
    if not (root / "plataforma/backend").exists():
        pytest.skip("repositório incompleto")
    with tarfile.open(fileobj=io.BytesIO(generate.source_package(root))) as t:
        names_tar = t.getnames()
    assert "infra/docker/backend/Dockerfile" in names_tar
    assert any(n.startswith("plataforma/backend/src/") for n in names_tar)
    forbidden = [n for n in names_tar if n.endswith((".env", ".bak")) or "/tests/" in n or "__pycache__" in n
                 or "/.venv" in n or n.endswith("authorized_keys")]
    assert forbidden == []


def _m() -> Manifest:
    return Manifest.model_validate({
        "topologia": {"tipo": "nuvem", "dominio": "solumia.exemplo.com", "email_tls": "a@b.com"},
        "nos": {"vps": {"endereco": "ssh", "ssh": {"host": "203.0.113.5"}, "papeis": ["gateway", "worker"]}},
    })


def test_env_gateway_single_quotes_and_secrets(vault: Vault) -> None:
    vault.definir(secret_store.PASSWORD_HASH, secret_store.hash_password("SenhaForte123"))
    vault.definir(secret_store.TOTP, secret_store.totp_secret())
    env = generate.env_gateway(_m(), vault)
    line_hash = next(line for line in env.splitlines() if line.startswith("GATEWAY_ADMIN_SENHA_HASH="))
    assert line_hash.startswith("GATEWAY_ADMIN_SENHA_HASH='scrypt$")  # single quotes: compose does not interpolate $
    assert "GATEWAY_DEBUG='false'" in env
    assert generate.env_gateway(_m(), vault) == env  # idempotente: segredos reaproveitados


def test_compose_and_nginx_with_solumia_names() -> None:
    c = generate.compose(nginx_no_docker=True)
    assert f"name: {names.COMPOSE_PROJECT}" in c
    assert f"127.0.0.1:{names.GATEWAY_HOST_PORT}:48080" in c
    assert "48080:48080" not in c and '"2222:2222"' not in c and "agent" not in c.replace("agent-data", "")
    root = generate.repository_root()
    if not (root / "infra/docker/nginx/host-nginx-site.conf.example").exists():
        pytest.skip("modelos nginx ausentes")
    host = generate.nginx_site_host("solumia.exemplo.com", root)
    assert "127.0.0.1:48080" not in host and f"127.0.0.1:{names.GATEWAY_HOST_PORT}" in host
    assert "agent_login" not in host and names.ZONA_LOGIN_NGINX in host
    assert "seu-dominio" not in generate.nginx_site_docker("solumia.exemplo.com", root)
    assert "zone=agent_login" not in generate.nginx_security(root)
    assert "real_ip_header" in generate.nginx_security(root)
    skipped = generate.nginx_security(root, skip=["real_ip_header", "limit_req_status"])
    assert "real_ip_header" not in skipped and "limit_req_status" not in skipped
    assert "set_real_ip_from" in skipped and "limit_req_zone" in skipped


def test_tunnel_authorized_keys_restricted() -> None:
    _, pub = secret_store.generate_ssh_key()
    line = generate.authorized_keys_tunnel(pub)
    assert line.startswith('restrict,port-forwarding,permitlisten="0.0.0.0:8765" ssh-ed25519 ')
    with pytest.raises(ValueError):
        generate.authorized_keys_tunnel('ssh-ed25519 AAAA\ncommand="sh" ssh-rsa X')
