"""Eventos da esteira: cada etapa grava em `<projeto>/log/eventos.jsonl` o que fez, quanto levou e o que falhou.

É a fonte única do `./dark status`, do `./dark log` e do painel web. Dentro de `with etapa(p, "montar")`:
- tudo que a etapa imprime vira evento `saida` (os módulos antigos não precisam mudar);
- `progresso(i, n, msg)` mostra barra com previsão de término (no terminal interativo) e grava o evento;
- `debug(msg, **dados)` só grava (chamadas ao FilmCraft, tempos), sem custar linhas no terminal.
"""
import json
import os
import sys
import time
import traceback
from contextlib import contextmanager
from datetime import datetime

_atual = None  # etapa em andamento neste processo


class _Saida:
    """Repassa o stdout ao terminal e grava cada linha como evento."""

    def __init__(self, etapa, original):
        self.etapa, self.original, self.buf = etapa, original, ""

    def write(self, s):
        self.original.write(s)
        self.buf += s
        while "\n" in self.buf:
            linha, self.buf = self.buf.split("\n", 1)
            if linha.strip():
                self.etapa.gravar("saida", linha.strip())
        return len(s)

    def flush(self):
        self.original.flush()

    def isatty(self):
        return self.original.isatty()


class Etapa:
    def __init__(self, projeto, nome):
        pasta = projeto.pasta / "log"
        pasta.mkdir(exist_ok=True)
        self.arq = pasta / "eventos.jsonl"
        self.ep, self.nome = projeto.ep, nome
        self.t0 = time.monotonic()
        self.tty = sys.stdout.isatty()
        self._marco = -1

    def gravar(self, tipo, msg="", **dados):
        reg = {"t": datetime.now().isoformat(timespec="milliseconds"), "ep": self.ep, "etapa": self.nome,
               "tipo": tipo, "msg": msg, **dados}
        with open(self.arq, "a") as f:
            f.write(json.dumps(reg, ensure_ascii=False, default=str) + "\n")

    def decorrido(self):
        return time.monotonic() - self.t0

    def progresso(self, i, n, msg=""):
        dec = self.decorrido()
        resta = dec / i * (n - i) if i else None
        self.gravar("progresso", msg, i=i, n=n, resta=round(resta, 1) if resta is not None else None)
        from esteira.nucleo import rastro
        rastro.progresso(i, n, msg, round(resta, 1) if resta is not None else None)
        pct = int(100 * i / n) if n else 100
        txt = f"  [{self.nome}] {i}/{n} {pct:3d}% · {_tempo(dec)}" + (f" · faltam {_tempo(resta)}" if resta else "")
        if self.tty:
            barra = "█" * (pct // 5) + "░" * (20 - pct // 5)
            sys.__stdout__.write(f"\r\033[K  {barra} {txt.strip()} · {msg[:50]}" + ("\n" if i >= n else ""))
            sys.__stdout__.flush()
        elif pct // 25 > self._marco:  # fora do terminal (log lido pelo Claude): só a cada 25%
            self._marco = pct // 25
            sys.__stdout__.write(txt + "\n")


def _tempo(s):
    s = int(s)
    return f"{s // 60}m{s % 60:02d}s" if s >= 60 else f"{s}s"


@contextmanager
def etapa(projeto, nome):
    global _atual
    e, anterior, saida = Etapa(projeto, nome), _atual, sys.stdout
    _atual = e
    e.gravar("inicio", pid=os.getpid())
    from esteira.nucleo import rastro
    rastro.no(projeto.ep, nome)
    sys.stdout = _Saida(e, saida)
    try:
        yield e
    except KeyboardInterrupt:
        e.gravar("erro", "interrompido", dur=round(e.decorrido(), 1))
        raise
    except BaseException as x:
        if isinstance(x, SystemExit) and not x.code:
            e.gravar("fim", dur=round(e.decorrido(), 1))
        else:
            e.gravar("erro", f"{type(x).__name__}: {x}", dur=round(e.decorrido(), 1),
                     traceback=traceback.format_exc(limit=6))
        raise
    else:
        e.gravar("fim", dur=round(e.decorrido(), 1))
    finally:
        sys.stdout = saida
        _atual = anterior
        rastro.no(None, None)


# Atalhos para módulos que não recebem a etapa: viram no-op fora de uma etapa.
def progresso(i, n, msg=""):
    if _atual:
        _atual.progresso(i, n, msg)


def debug(msg, **dados):
    if _atual:
        _atual.gravar("debug", msg, **dados)


def aviso(msg, **dados):
    print(f"  ! {msg}")
    if _atual:
        _atual.gravar("aviso", msg, **dados)


def gravar_claude(motivo, custo, segundos, ok=True):
    """Toda chamada ao Claude aparece no terminal e no log (é a parte que custa dinheiro)."""
    print(f"  ☁ Claude: {motivo} · US$ {custo:.4f} · {segundos}s" + ("" if ok else " · sem resposta válida"))
    if _atual:
        _atual.gravar("claude", motivo, custo=custo, seg=segundos, ok=ok)
