"""Simulados (questões inéditas no estilo da banca, geradas pelo Claude) e materiais de estudo
(provas anteriores da banca, questões, apostilas e vídeos achados na web e classificados pela LLM
local), guardados ao lado do concurso: `<raiz>/<id>/simulados.json` e `materiais.json`."""

import json
import re
import threading
import unicodedata
import uuid
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from concursos import ai_plan

Search = Callable[[str], Awaitable[dict[str, Any]]]
ChatLLM = Callable[[list[dict[str, str]]], Awaitable[str]]
KINDS_MATERIAL = ("prova", "questoes", "apostila", "video", "resumo", "edital", "outro")


class Invalid(Exception):
    pass


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _slug(text: str) -> str:
    sem = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "-", sem).strip("-")


class Study:
    def __init__(self, root: Path) -> None:
        self.raiz = root
        self._trava = threading.RLock()

    def _arq(self, id_: str, nome: str) -> Path:
        return self.raiz / id_ / nome

    def _ler(self, id_: str, nome: str, default: Any) -> Any:
        file = self._arq(id_, nome)
        return json.loads(file.read_text("utf-8")) if file.exists() else default

    def _gravar(self, id_: str, nome: str, dados: Any) -> None:
        file = self._arq(id_, nome)
        tmp = file.with_suffix(".tmp")
        tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=1), "utf-8")
        tmp.replace(file)

    # ---------- simulados ----------
    def pedido_simulado(
        self, exam: dict[str, Any], n: int, subject: str = ""
    ) -> tuple[dict[str, Any], str]:
        """Registra um simulado `gerando` e devolve (registro, prompt para o Claude)."""
        structure = exam.get("estrutura")
        if not structure:
            raise Invalid("Gere o plano do concurso antes do simulado.")
        discs = {d["nome"]: max(1, int(d.get("questoes") or 1)) for d in structure["disciplinas"]}
        if subject:
            if subject not in discs:
                raise Invalid(f"Disciplina fora do edital: {subject}")
            discs = {subject: 1}
        cotas = ai_plan.distribute(discs, n)
        done = {
            t["chave"].split("|")[1]
            for t in exam["tarefas"]
            if t.get("feito") and t.get("chave")
        }
        record = {
            "id": uuid.uuid4().hex[:10],
            "criado": _now(),
            "estado": "gerando",
            "erro": "",
            "titulo": f"{subject or 'Simulado geral'} · {n} questões",
            "disciplina": subject,
            "minutos": round(n * 4.5),  # ~ ritmo da prova objetiva (60 questões em ~4h30)
            "cotas": cotas,
            "questoes": [],
            "respostas": None,
            "resultado": None,
        }
        with self._trava:
            self._gravar(
                exam["id"],
                "simulados.json",
                [*self._ler(exam["id"], "simulados.json", []), record],
            )
        return record, ai_plan.prompt_mock_exam(exam, cotas, sorted(done))

    def _alterar(self, id_: str, sid: str, f: Callable[[dict[str, Any]], None]) -> dict[str, Any]:
        with self._trava:
            items = self._ler(id_, "simulados.json", [])
            for s in items:
                if s["id"] == sid:
                    f(s)
                    self._gravar(id_, "simulados.json", items)
                    return dict(s)
        raise KeyError(sid)

    def concluir_simulado(self, id_: str, sid: str, dados: dict[str, Any]) -> None:
        questoes = [
            {**q, "n": i + 1}
            for i, q in enumerate(dados.get("questoes") or [])
            if len(q.get("alternativas") or []) == 5 and 0 <= int(q.get("correta", -1)) <= 4
        ]
        if not questoes:
            raise Invalid("O Claude não devolveu questões válidas.")

        def f(s: dict[str, Any]) -> None:
            s.update(estado="pronto", questoes=questoes, minutos=round(len(questoes) * 4.5))

        self._alterar(id_, sid, f)

    def falha_simulado(self, id_: str, sid: str, erro: str) -> None:
        self._alterar(id_, sid, lambda s: s.update(estado="erro", erro=erro))

    @staticmethod
    def _publico(s: dict[str, Any]) -> dict[str, Any]:
        """Sem gabarito nem comentário enquanto não for respondido."""
        if s["respostas"] is not None:
            return s
        return {
            **s,
            "questoes": [
                {k: v for k, v in q.items() if k not in ("correta", "comentario")}
                for q in s["questoes"]
            ],
        }

    def simulados(self, id_: str) -> list[dict[str, Any]]:
        return [self._publico(s) for s in reversed(self._ler(id_, "simulados.json", []))]

    def excluir_simulado(self, id_: str, sid: str) -> None:
        with self._trava:
            items = self._ler(id_, "simulados.json", [])
            self._gravar(id_, "simulados.json", [s for s in items if s["id"] != sid])

    def responder(
        self, id_: str, sid: str, respostas: list[int | None], seconds: int
    ) -> dict[str, Any]:
        def f(s: dict[str, Any]) -> None:
            if s["estado"] != "pronto":
                raise Invalid("Simulado ainda não está pronto.")
            if len(respostas) != len(s["questoes"]):
                raise Invalid("Uma resposta por questão (vazio = em branco).")
            por: dict[str, dict[str, int]] = {}
            acertos = 0
            for q, r in zip(s["questoes"], respostas, strict=True):
                d = por.setdefault(q["disciplina"], {"acertos": 0, "total": 0})
                d["total"] += 1
                if r == q["correta"]:
                    d["acertos"] += 1
                    acertos += 1
            total = len(s["questoes"])
            s.update(
                respostas=respostas,
                respondido=_now(),
                resultado={
                    "acertos": acertos,
                    "total": total,
                    "pct": round(100 * acertos / total),
                    "em_branco": sum(1 for r in respostas if r is None),
                    "segundos": seconds,
                    "por_disciplina": por,
                    "aprovado": acertos / total >= 0.6,
                },
            )

        return self._alterar(id_, sid, f)

    def desempenho(self, id_: str) -> dict[str, Any]:
        """Acertos por disciplina somando todos os simulados respondidos, do pior para o melhor."""
        total: dict[str, dict[str, int]] = {}
        evolucao = []
        for s in self._ler(id_, "simulados.json", []):
            r = s.get("resultado")
            if not r:
                continue
            evolucao.append({"data": s["respondido"][:10], "pct": r["pct"], "titulo": s["titulo"]})
            for name, d in r["por_disciplina"].items():
                t = total.setdefault(name, {"acertos": 0, "total": 0})
                t["acertos"] += d["acertos"]
                t["total"] += d["total"]
        disciplinas = sorted(
            (
                {"disciplina": k, **v, "pct": round(100 * v["acertos"] / v["total"])}
                for k, v in total.items()
            ),
            key=lambda x: x["pct"],
        )
        return {"disciplinas": disciplinas, "evolucao": evolucao}

    # ---------- materiais ----------
    def materiais(self, id_: str) -> dict[str, Any]:
        data: dict[str, Any] = self._ler(
            id_, "materiais.json", {"estado": "vazio", "atualizado": None, "itens": []}
        )
        return data

    def marcar_materiais(self, id_: str, estado: str, erro: str = "") -> None:
        with self._trava:
            m = self.materiais(id_)
            m.update(estado=estado, erro=erro)
            self._gravar(id_, "materiais.json", m)

    async def buscar_materiais(
        self, exam: dict[str, Any], fetch: Search, llm: ChatLLM | None
    ) -> None:
        """Pesquisa na web (DuckDuckGo) e a LLM local classifica; só links que a busca trouxe."""
        banca = exam.get("banca") or ""
        cargo = exam["cargo"]
        discs = sorted(
            (exam.get("estrutura") or {}).get("disciplinas", []),
            key=lambda d: -int(d.get("questoes") or 0),
        )
        queries = [
            f"provas anteriores {banca} {cargo} pdf gabarito",
            f"prova {banca} analista tecnologia da informação questões comentadas",
            f"{exam['nome']} material de estudo gratuito",
            *[f"{d['nome']} questões {banca} concurso resumo" for d in discs[:4]],
        ]
        results: list[dict[str, Any]] = []
        seen: set[str] = set()
        for q in queries:
            try:
                r = await fetch(q)
            except Exception:
                continue
            for x in r.get("resultados", []):
                if x.get("url", "").startswith("http") and x["url"] not in seen:
                    seen.add(x["url"])
                    results.append(x)
        items: list[dict[str, Any]] = []
        # provas anteriores: o link "Provas relacionadas" do PCI (radar) ou a página da banca
        provas = (exam.get("radar") or {}).get("provas_url") or (
            f"https://www.pciconcursos.com.br/provas/{_slug(banca)}" if banca else ""
        )
        if provas:
            items.append(
                {
                    "titulo": f"Provas anteriores da {banca or 'banca'} (PCI Concursos)",
                    "tipo": "prova",
                    "disciplina": "",
                    "url": provas,
                    "descricao": "Provas e gabaritos oficiais, para treinar no estilo da banca.",
                }
            )
        classes: dict[int, dict[str, Any]] = {}
        if llm and results:
            lista = "\n".join(
                f"{i}. {x.get('titulo', '')} — {x['url']} — {x.get('trecho', '')[:200]}"
                for i, x in enumerate(results)
            )
            system = (
                "Você classifica resultados de busca para um candidato de concurso. "
                'Responda SOMENTE com JSON {"itens": [{"n": 0, "util": true, '
                '"tipo": "prova|questoes|apostila|video|resumo|edital|outro", '
                '"disciplina": "", "descricao": ""}]}. '
                '"util" = ajuda a estudar para este concurso; '
                '"descricao" em 1 frase. Não invente links.'
            )
            user = f"Concurso: {exam['nome']} — banca {banca} — cargo {cargo}\n\n{lista}"
            try:
                resp = await llm(
                    [{"role": "system", "content": system}, {"role": "user", "content": user}]
                )
                m = re.search(r"\{.*\}", resp, re.S)
                for c in json.loads(m[0]).get("itens", []) if m else []:
                    if isinstance(c.get("n"), int):
                        classes[c["n"]] = c
            except Exception:
                classes = {}
        for i, x in enumerate(results):
            c = classes.get(i)
            if classes and (not c or not c.get("util")):
                continue
            kind = (c or {}).get("tipo", "outro")
            items.append(
                {
                    "titulo": x.get("titulo") or x["url"],
                    "url": x["url"],
                    "tipo": kind if kind in KINDS_MATERIAL else "outro",
                    "disciplina": (c or {}).get("disciplina", ""),
                    "descricao": (c or {}).get("descricao") or x.get("trecho", "")[:200],
                }
            )
        with self._trava:
            self._gravar(
                exam["id"],
                "materiais.json",
                {
                    "estado": "pronto",
                    "erro": "",
                    "atualizado": _now(),
                    "itens": items,
                    "classificado": bool(classes),
                },
            )
