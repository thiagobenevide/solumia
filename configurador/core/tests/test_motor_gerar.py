from __future__ import annotations

import io
import tarfile
from pathlib import Path

import pytest

from solumia_configurador import gerar, nomes, segredos
from solumia_configurador.cofre import Cofre
from solumia_configurador.manifesto import Manifesto
from solumia_configurador.motor import Execucao, Mascara, Passo, Plano, listar_registro


def test_plano_executa_pula_e_mascara(tmp_path: Path) -> None:
    feitos = []
    p = Plano("t", [
        Passo("a", "A", executar=lambda c: (feitos.append("a"), c.log("token=SEGREDO-123456"))),
        Passo("b", "B", executar=lambda c: feitos.append("b"), ja_feito=lambda c: True),
    ])
    ex = Execucao(p, tmp_path, Mascara(lambda: ["SEGREDO-123456"]))
    assert ex.rodar() == "concluida"
    assert feitos == ["a"]
    textos = " ".join(e["texto"] for e in ex.eventos_desde(0))
    assert "SEGREDO" not in textos and "•••" in textos
    assert "SEGREDO" not in next(tmp_path.glob("*.jsonl")).read_text()
    assert listar_registro(tmp_path)[0]["estado"] == "concluida"


def test_retomada_pula_concluidos_mas_nao_os_sempre(tmp_path: Path) -> None:
    contagem = {"con": 0, "a": 0, "b": 0}
    falhar = {"b": True}

    def b(_c) -> None:
        contagem["b"] += 1
        if falhar["b"]:
            raise RuntimeError("caiu")

    def plano() -> Plano:
        return Plano("r", [
            Passo("con", "Conectar", executar=lambda c: contagem.__setitem__("con", contagem["con"] + 1), sempre=True),
            Passo("a", "A", executar=lambda c: contagem.__setitem__("a", contagem["a"] + 1)),
            Passo("b", "B", executar=b),
        ])

    assert Execucao(plano(), tmp_path).rodar() == "falhou"
    falhar["b"] = False
    import time
    time.sleep(1.1)  # id da execução tem resolução de segundos
    assert Execucao(plano(), tmp_path).rodar() == "concluida"
    assert contagem == {"con": 2, "a": 1, "b": 2}


def test_hash_do_plano_muda_com_os_passos() -> None:
    a = Plano("x", [Passo("a", "A")])
    b = Plano("x", [Passo("a", "A", detalhe="outro")])
    assert a.hash != b.hash


def test_pacote_fonte_sem_segredos() -> None:
    raiz = gerar.raiz_repositorio()
    if not (raiz / "plataforma/backend").exists():
        pytest.skip("repositório incompleto")
    with tarfile.open(fileobj=io.BytesIO(gerar.pacote_fonte(raiz))) as t:
        nomes_tar = t.getnames()
    assert "infra/docker/backend/Dockerfile" in nomes_tar
    assert any(n.startswith("plataforma/backend/src/") for n in nomes_tar)
    proibidos = [n for n in nomes_tar if n.endswith((".env", ".bak")) or "/tests/" in n or "__pycache__" in n
                 or "/.venv" in n or n.endswith("authorized_keys")]
    assert proibidos == []


def _m() -> Manifesto:
    return Manifesto.model_validate({
        "topologia": {"tipo": "nuvem", "dominio": "solumia.exemplo.com", "email_tls": "a@b.com"},
        "nos": {"vps": {"endereco": "ssh", "ssh": {"host": "203.0.113.5"}, "papeis": ["gateway", "worker"]}},
    })


def test_env_gateway_aspas_simples_e_segredos(cofre: Cofre) -> None:
    cofre.definir(segredos.SENHA_HASH, segredos.hash_senha("SenhaForte123"))
    cofre.definir(segredos.TOTP, segredos.segredo_totp())
    env = gerar.env_gateway(_m(), cofre)
    linha_hash = next(linha for linha in env.splitlines() if linha.startswith("GATEWAY_ADMIN_SENHA_HASH="))
    assert linha_hash.startswith("GATEWAY_ADMIN_SENHA_HASH='scrypt$")  # aspas simples: compose não interpola $
    assert "GATEWAY_DEBUG='false'" in env
    assert gerar.env_gateway(_m(), cofre) == env  # idempotente: segredos reaproveitados


def test_compose_e_nginx_com_nomes_do_solumia() -> None:
    c = gerar.compose(nginx_no_docker=True)
    assert f"name: {nomes.PROJETO_COMPOSE}" in c
    assert f"127.0.0.1:{nomes.PORTA_GATEWAY_HOST}:48080" in c
    assert "48080:48080" not in c and '"2222:2222"' not in c and "agent" not in c.replace("agent-data", "")
    raiz = gerar.raiz_repositorio()
    if not (raiz / "infra/docker/nginx/host-nginx-site.conf.example").exists():
        pytest.skip("modelos nginx ausentes")
    host = gerar.nginx_site_host("solumia.exemplo.com", raiz)
    assert "127.0.0.1:48080" not in host and f"127.0.0.1:{nomes.PORTA_GATEWAY_HOST}" in host
    assert "agent_login" not in host and nomes.ZONA_LOGIN_NGINX in host
    assert "seu-dominio" not in gerar.nginx_site_docker("solumia.exemplo.com", raiz)
    assert "zone=agent_login" not in gerar.nginx_seguranca(raiz)


def test_authorized_keys_do_tunel_restrito() -> None:
    _, pub = segredos.gerar_chave_ssh()
    linha = gerar.authorized_keys_tunel(pub)
    assert linha.startswith('restrict,port-forwarding,permitlisten="0.0.0.0:8765" ssh-ed25519 ')
    with pytest.raises(ValueError):
        gerar.authorized_keys_tunel('ssh-ed25519 AAAA\ncommand="sh" ssh-rsa X')
