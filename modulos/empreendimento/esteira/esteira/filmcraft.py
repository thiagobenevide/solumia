"""Cliente mínimo do servidor MCP do FilmCraft (filmcraft-cli mcp), sobre stdio."""

import json
import subprocess
import time

from esteira.core import events

TICKS = 254016000000  # ticks por segundo do FilmCraft


def ticks(seconds):
    return int(round(seconds * TICKS))


class ErrorFilmCraft(RuntimeError):
    pass


class FilmCraft:
    def __init__(self, bridge=None):
        cmd = ["filmcraft-cli", "mcp"]
        if bridge:
            cmd += ["--bridge", bridge]
        self.process = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self._id = 0
        self._rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                 "clientInfo": {"name": "esteira-dark", "version": "1"}})
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _send(self, msg):
        self.process.stdin.write(json.dumps(msg) + "\n")
        self.process.stdin.flush()

    def _rpc(self, method, params):
        self._id += 1
        self._send({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params})
        while True:
            line = self.process.stdout.readline()
            if not line:
                raise ErrorFilmCraft("o processo filmcraft-cli mcp terminou")
            msg = json.loads(line)
            if msg.get("id") == self._id:
                if "error" in msg:
                    raise ErrorFilmCraft(msg["error"])
                return msg["result"]

    def tool(self, name, **args):
        res = self._rpc("tools/call", {"name": name, "arguments": args})
        text = "".join(c.get("text", "") for c in res.get("content", []))
        if res.get("isError"):
            raise ErrorFilmCraft(f"{name} {args.get('id', '')}: {text}")
        try:
            return json.loads(text)
        except ValueError:
            return text

    def run(self, cmd_id, **params):
        t = time.monotonic()
        try:
            res = self.tool("command_run", id=cmd_id, params=params)
        except ErrorFilmCraft as e:
            events.debug(f"fc {cmd_id} falhou", params=str(params)[:300], erro=str(e)[:300])
            raise
        events.debug(f"fc {cmd_id}", ms=round((time.monotonic() - t) * 1000))
        return res

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=30)
