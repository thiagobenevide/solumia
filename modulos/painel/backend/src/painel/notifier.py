"""Cobrança fora do app: de tempos em tempos olha a disciplina do dia e manda os alertas novos como
push para um tópico do ntfy (app ntfy no celular/PC recebe mesmo com o app do agent fechado).

Cada alerta é enviado uma vez por dia; os já enviados ficam em `enviados.json`."""

import asyncio
import json
import logging
import urllib.request
from collections.abc import Callable
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from painel.nagger import Cobrador

logger = logging.getLogger("painel.notifier")


class Notificador:
    def __init__(
        self,
        cobrador: Cobrador,
        tarefas: Callable[[], list[dict[str, Any]]],
        url: str,
        token: str = "",
        enviar: Callable[[str, str, str], None] | None = None,
        extras: Callable[[], list[dict[str, Any]]] | None = None,
    ) -> None:
        """[extras]: alertas de outros módulos (`{nivel, texto, concurso?}`), ex. Concursos."""
        self.cobrador = cobrador
        self.tarefas = tarefas
        self.url = url
        self.token = token
        self._enviar = enviar or self._ntfy
        self.extras = extras
        self._arquivo = cobrador.raiz / "enviados.json"

    def _ntfy(self, titulo: str, texto: str, prioridade: str) -> None:
        # publicação em JSON na raiz do servidor: título e texto em UTF-8 sem passar por cabeçalho
        partes = urlsplit(self.url)
        corpo = {
            "topic": partes.path.strip("/"),
            "title": titulo,
            "message": texto,
            "priority": 4 if prioridade == "high" else 3,
            "tags": ["rotating_light" if prioridade == "high" else "bell"],
        }
        cabecalhos = {"Content-Type": "application/json"}
        if self.token:
            cabecalhos["Authorization"] = f"Bearer {self.token}"
        pedido = urllib.request.Request(
            f"{partes.scheme}://{partes.netloc}/",
            data=json.dumps(corpo).encode(),
            headers=cabecalhos,
        )
        with urllib.request.urlopen(pedido, timeout=10):
            pass

    def _enviados(self, dia: str) -> set[str]:
        if not self._arquivo.exists():
            return set()
        dados: dict[str, list[str]] = json.loads(self._arquivo.read_text("utf-8"))
        return set(dados.get(dia, []))

    def verificar(self) -> list[dict[str, str]]:
        """Envia os alertas de hoje ainda não enviados e devolve-os."""
        d = self.cobrador.disciplina(self.tarefas())
        ja = self._enviados(d["data"])
        alertas = d["alertas"]
        if self.extras:
            try:
                alertas = alertas + self.extras()
            except Exception:
                logger.exception("Falha ao ler os alertas extras")
        novos = [a for a in alertas if a["texto"] not in ja]
        for a in novos:
            critico = a["nivel"] == "critico"
            if a.get("concurso"):
                titulo = "Concursos: prazo" if critico else "Concursos"
            else:
                titulo = "Cobrador: entrega em risco" if critico else "Cobrador"
            self._enviar(titulo, a["texto"], "high" if critico else "default")
            ja.add(a["texto"])
        if novos:
            # só o dia atual fica no arquivo: os alertas de ontem não voltam a valer
            Path(self._arquivo).write_text(json.dumps({d["data"]: sorted(ja)}, ensure_ascii=False))
        return novos

    async def rodar(self, intervalo_s: float) -> None:
        while True:
            try:
                await asyncio.to_thread(self.verificar)
            except Exception:
                logger.exception("Falha ao enviar a cobrança")
            await asyncio.sleep(intervalo_s)
