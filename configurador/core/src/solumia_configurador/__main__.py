"""Entrada do núcleo.

    solumia-configurador servir [--manifesto CAMINHO] [--cofre-frase]
        Sobe a API local. A 1ª linha da saída padrão é JSON com {"porta", "token"}: a interface
        que iniciou o processo lê essa linha; nada mais recebe o token.

    solumia-configurador verificar [--manifesto CAMINHO]
        Valida o manifesto e mostra o resumo (sem segredos).
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import socket
import sys
import threading
from pathlib import Path

from . import VERSAO, manifest, names
from .platform_setup import dir_config
from .vault import Cofre, CofreErro


def _abrir_cofre(frase: bool) -> Cofre:
    caminho = dir_config() / names.ARQUIVO_COFRE
    if frase:
        return Cofre.com_frase(caminho, getpass.getpass("Frase-senha do cofre: ")).abrir()
    return Cofre(caminho).abrir()


def servir(args: argparse.Namespace) -> int:
    import uvicorn

    from .api import Estado, criar_app, novo_token

    try:
        cofre = _abrir_cofre(args.cofre_frase)
    except CofreErro as e:
        print(json.dumps({"erro": f"cofre: {e}"}), flush=True)
        return 2
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", args.porta))
    porta = sock.getsockname()[1]
    token = novo_token()
    estado = Estado(Path(args.manifesto), cofre)
    app = criar_app(estado, token, porta)
    print(json.dumps({"porta": porta, "token": token, "versao": VERSAO}), flush=True)
    if args.sair_com_stdin:
        # A interface segura o stdin aberto; se ela morrer (até por kill), o núcleo sai junto.
        def vigiar() -> None:
            while sys.stdin.buffer.read(4096):
                pass
            os._exit(0)

        threading.Thread(target=vigiar, daemon=True).start()
    config = uvicorn.Config(app, log_level="warning", access_log=False, server_header=False)
    uvicorn.Server(config).run(sockets=[sock])
    return 0


def verificar(args: argparse.Namespace) -> int:
    try:
        m = manifest.carregar(Path(args.manifesto))
    except (OSError, ValueError) as e:
        print(f"✗ manifesto inválido: {e}", file=sys.stderr)
        return 1
    print(f"✔ manifesto ok: topologia {m.topologia.tipo}, {len(m.nos)} nó(s)")
    for nome, no in m.nos.items():
        onde = f"{no.ssh.usuario}@{no.ssh.host}" if no.ssh else "este computador"
        print(f"  {nome}: {onde} → {', '.join(no.papeis) or '(sem papéis)'}")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(prog="solumia-configurador", description=f"Configurador do Solumia {VERSAO}")
    sub = p.add_subparsers(dest="comando", required=True)
    s = sub.add_parser("servir", help="API local para a interface")
    s.add_argument("--manifesto", default=str(manifest.caminho_padrao()))
    s.add_argument("--porta", type=int, default=names.PORTA_CORE_PADRAO)
    s.add_argument("--sair-com-stdin", action="store_true", help="encerrar quando o stdin fechar (uso da interface)")
    s.add_argument("--cofre-frase", action="store_true", help="sem chaveiro do sistema: pede frase-senha")
    s.set_defaults(func=servir)
    v = sub.add_parser("verificar", help="valida o manifesto")
    v.add_argument("--manifesto", default=str(manifest.caminho_padrao()))
    v.set_defaults(func=verificar)
    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
