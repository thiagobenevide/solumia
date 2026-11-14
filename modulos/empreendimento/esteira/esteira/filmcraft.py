"""Cliente mínimo do servidor MCP do FilmCraft (filmcraft-cli mcp), sobre stdio."""

import json
import subprocess
import time

from esteira.nucleo import eventos

TICKS = 254016000000  # ticks por segundo do FilmCraft


def ticks(segundos):
    return int(round(segundos * TICKS))


class ErroFilmCraft(RuntimeError):
    pass


class FilmCraft:
    def __init__(self, bridge=None):
        cmd = ["filmcraft-cli", "mcp"]
        if bridge:
            cmd += ["--bridge", bridge]
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self._id = 0
        self._rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                 "clientInfo": {"name": "esteira-dark", "version": "1"}})
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _send(self, msg):
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()

    def _rpc(self, method, params):
        self._id += 1
        self._send({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params})
        while True:
            linha = self.proc.stdout.readline()
            if not linha:
                raise ErroFilmCraft("o processo filmcraft-cli mcp terminou")
            msg = json.loads(linha)
            if msg.get("id") == self._id:
                if "error" in msg:
                    raise ErroFilmCraft(msg["error"])
                return msg["result"]

    def tool(self, nome, **args):
        res = self._rpc("tools/call", {"name": nome, "arguments": args})
        texto = "".join(c.get("text", "") for c in res.get("content", []))
        if res.get("isError"):
            raise ErroFilmCraft(f"{nome} {args.get('id', '')}: {texto}")
        try:
            return json.loads(texto)
        except ValueError:
            return texto

    def run(self, cmd_id, **params):
        t = time.monotonic()
        try:
            res = self.tool("command_run", id=cmd_id, params=params)
        except ErroFilmCraft as e:
            eventos.debug(f"fc {cmd_id} falhou", params=str(params)[:300], erro=str(e)[:300])
            raise
        eventos.debug(f"fc {cmd_id}", ms=round((time.monotonic() - t) * 1000))
        return res

    def fechar(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=30)
