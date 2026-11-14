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

from painel.nagger import Nagger

logger = logging.getLogger("painel.notifier")


class Notifier:
    def __init__(
        self,
        nagger: Nagger,
        tarefas: Callable[[], list[dict[str, Any]]],
        url: str,
        token: str = "",
        enviar: Callable[[str, str, str], None] | None = None,
        extras: Callable[[], list[dict[str, Any]]] | None = None,
    ) -> None:
        """[extras]: alertas de outros módulos (`{nivel, texto, concurso?}`), ex. Concursos."""
        self.nagger = nagger
        self.tarefas = tarefas
        self.url = url
        self.token = token
        self._enviar = enviar or self._ntfy
        self.extras = extras
        self._arquivo = nagger.root / "enviados.json"

    def _ntfy(self, titulo: str, text: str, prioridade: str) -> None:
        # publicação em JSON na raiz do servidor: título e texto em UTF-8 sem passar por cabeçalho
        parts = urlsplit(self.url)
        body = {
            "topic": parts.path.strip("/"),
            "title": titulo,
            "message": text,
            "priority": 4 if prioridade == "high" else 3,
            "tags": ["rotating_light" if prioridade == "high" else "bell"],
        }
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(
            f"{parts.scheme}://{parts.netloc}/",
            data=json.dumps(body).encode(),
            headers=headers,
        )
        with urllib.request.urlopen(request, timeout=10):
            pass

    def _enviados(self, day: str) -> set[str]:
        if not self._arquivo.exists():
            return set()
        data: dict[str, list[str]] = json.loads(self._arquivo.read_text("utf-8"))
        return set(data.get(day, []))

    def verify(self) -> list[dict[str, str]]:
        """Envia os alertas de hoje ainda não enviados e devolve-os."""
        d = self.nagger.disciplina(self.tarefas())
        ja = self._enviados(d["data"])
        alerts = d["alertas"]
        if self.extras:
            try:
                alerts = alerts + self.extras()
            except Exception:
                logger.exception("Falha ao ler os alertas extras")
        new = [a for a in alerts if a["texto"] not in ja]
        for a in new:
            critico = a["nivel"] == "critico"
            if a.get("concurso"):
                title = "Concursos: prazo" if critico else "Concursos"
            else:
                title = "Cobrador: entrega em risco" if critico else "Cobrador"
            self._enviar(title, a["texto"], "high" if critico else "default")
            ja.add(a["texto"])
        if new:
            # só o dia atual fica no arquivo: os alertas de ontem não voltam a valer
            Path(self._arquivo).write_text(json.dumps({d["data"]: sorted(ja)}, ensure_ascii=False))
        return new

    async def rodar(self, interval_s: float) -> None:
        while True:
            try:
                await asyncio.to_thread(self.verify)
            except Exception:
                logger.exception("Falha ao enviar a cobrança")
            await asyncio.sleep(interval_s)
