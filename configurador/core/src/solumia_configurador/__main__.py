"""Core entry point.

    solumia-configurador servir [--manifesto PATH] [--cofre-frase]
        Starts the local API. The first line of standard output is JSON with {"porta", "token"}: the
        interface that started the process reads that line; nothing else receives the token.

    solumia-configurador verificar [--manifesto PATH]
        Validates the manifest and prints the summary (no secrets).
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

from . import VERSION, manifest, names
from .platform_setup import dir_config
from .vault import Vault, VaultError


def _open_vault(sentence: bool) -> Vault:
    path = dir_config() / names.VAULT_FILE
    if sentence:
        return Vault.with_passphrase(path, getpass.getpass("Frase-senha do cofre: ")).open_file()
    return Vault(path).open_file()


def serve(args: argparse.Namespace) -> int:
    import uvicorn

    from .api import State, create_app, new_token

    try:
        vault = _open_vault(args.cofre_frase)
    except VaultError as e:
        print(json.dumps({"erro": f"cofre: {e}"}), flush=True)
        return 2
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", args.porta))
    port = sock.getsockname()[1]
    token = new_token()
    state = State(Path(args.manifest), vault)
    app = create_app(state, token, port)
    print(json.dumps({"porta": port, "token": token, "versao": VERSION}), flush=True)
    if args.sair_com_stdin:
        # The interface keeps stdin open; if it dies (even by kill), the core exits with it.
        def vigiar() -> None:
            while sys.stdin.buffer.read(4096):
                pass
            os._exit(0)

        threading.Thread(target=vigiar, daemon=True).start()
    config = uvicorn.Config(app, log_level="warning", access_log=False, server_header=False)
    uvicorn.Server(config).run(sockets=[sock])
    return 0


def verify(args: argparse.Namespace) -> int:
    try:
        m = manifest.load(Path(args.manifest))
    except (OSError, ValueError) as e:
        print(f"✗ manifesto inválido: {e}", file=sys.stderr)
        return 1
    print(f"✔ manifesto ok: topologia {m.topologia.tipo}, {len(m.nos)} nó(s)")
    for name, no in m.nos.items():
        where = f"{no.ssh.usuario}@{no.ssh.host}" if no.ssh else "este computador"
        print(f"  {name}: {where} → {', '.join(no.papeis) or '(sem papéis)'}")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(prog="solumia-configurador", description=f"Configurador do Solumia {VERSION}")
    sub = p.add_subparsers(dest="comando", required=True)
    s = sub.add_parser("servir", help="API local para a interface")
    s.add_argument("--manifesto", dest="manifest", default=str(manifest.default_path()))
    s.add_argument("--porta", type=int, default=names.DEFAULT_CORE_PORT)
    s.add_argument("--sair-com-stdin", action="store_true", help="encerrar quando o stdin fechar (uso da interface)")
    s.add_argument("--cofre-frase", action="store_true", help="sem chaveiro do sistema: pede frase-senha")
    s.set_defaults(func=serve)
    v = sub.add_parser("verificar", help="valida o manifesto")
    v.add_argument("--manifesto", dest="manifest", default=str(manifest.default_path()))
    v.set_defaults(func=verify)
    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
