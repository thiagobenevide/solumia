"""Concursos guardados em `<raiz>/<id>/`: `concurso.json` (dados, estrutura gerada pelo Claude,
prazos e tarefas), `edital.pdf` e `edital.txt` (texto extraído pelo pdftotext).

`geracao.estado`: `sem_plano` → `gerando` → `pronto` | `erro`."""

import json
import os
import shutil
import subprocess
import threading
import uuid
from collections.abc import Callable
from datetime import UTC, date, datetime
from pathlib import Path
from typing import Any

from concursos import schedule
from concursos.study import Estudo

CAMPOS_EDITAVEIS = {
    "nome",
    "banca",
    "cargo",
    "data_prova",
    "minutos_util",
    "minutos_fds",
    "observacoes",
    "edital_url",
}


class NaoEncontrado(Exception):
    pass


class Invalido(Exception):
    pass


def _agora() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _data(texto: str | None) -> date | None:
    try:
        return date.fromisoformat(str(texto)[:10]) if texto else None
    except ValueError:
        return None


def texto_pdf(pdf: Path) -> str:
    try:
        r = subprocess.run(
            ["pdftotext", "-layout", str(pdf), "-"], capture_output=True, timeout=120, text=True
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        raise Invalido("Não foi possível ler o PDF (pdftotext ausente ou demorou demais).") from e
    return r.stdout


class Concursos:
    def __init__(self, raiz: str | Path, hoje: Callable[[], date] = date.today) -> None:
        self.raiz = Path(raiz).expanduser()
        self.raiz.mkdir(parents=True, exist_ok=True)
        self.hoje = hoje
        self._trava = threading.RLock()
        self.estudo = Estudo(self.raiz)

    # --- arquivos ---
    def _pasta(self, id_: str) -> Path:
        pasta = self.raiz / id_
        if not id_.isalnum() or not (pasta / "concurso.json").exists():
            raise NaoEncontrado(id_)
        return pasta

    def _ler(self, id_: str) -> dict[str, Any]:
        dados: dict[str, Any] = json.loads((self._pasta(id_) / "concurso.json").read_text("utf-8"))
        return dados

    def _gravar(self, c: dict[str, Any]) -> None:
        c["atualizado"] = _agora()
        arquivo = self.raiz / c["id"] / "concurso.json"
        tmp = arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(c, ensure_ascii=False, indent=1), "utf-8")
        os.replace(tmp, arquivo)

    # --- CRUD ---
    def criar(self, dados: dict[str, Any]) -> dict[str, Any]:
        id_ = uuid.uuid4().hex[:12]
        c = {
            "id": id_,
            "nome": dados["nome"],
            "banca": dados.get("banca", ""),
            "cargo": dados["cargo"],
            "data_prova": dados.get("data_prova"),
            "minutos_util": int(dados.get("minutos_util", 120)),
            "minutos_fds": int(dados.get("minutos_fds", 240)),
            "observacoes": dados.get("observacoes", ""),
            "edital_url": dados.get("edital_url", ""),
            "edital": None,
            "criado": _agora(),
            "geracao": {"estado": "sem_plano", "erro": "", "inicio": None, "fim": None},
            "radar": dados.get("radar"),
            "estrutura": None,
            "resumo_plano": None,
            "prazos": [],
            "tarefas": [],
        }
        with self._trava:
            (self.raiz / id_).mkdir()
            self._gravar(c)
        return c

    def listar(self) -> list[dict[str, Any]]:
        saida = []
        for arq in sorted(self.raiz.glob("*/concurso.json")):
            c = json.loads(arq.read_text("utf-8"))
            saida.append(self.resumo(c))
        return sorted(saida, key=lambda c: (c["data_prova"] or "9999", c["nome"]))

    def resumo(self, c: dict[str, Any]) -> dict[str, Any]:
        hoje = self.hoje()
        tarefas = c["tarefas"]
        feitas = sum(1 for t in tarefas if t["feito"])
        prova = _data(c["data_prova"])
        futuros = sorted(
            (p for p in c["prazos"] if (_data(p["data"]) or date.min) >= hoje),
            key=lambda p: p["data"],
        )
        return {
            "id": c["id"],
            "nome": c["nome"],
            "banca": c["banca"],
            "cargo": c["cargo"],
            "data_prova": c["data_prova"],
            "dias_para_prova": (prova - hoje).days if prova else None,
            "estado": c["geracao"]["estado"],
            "tem_edital": bool(c["edital"]),
            "tarefas": len(tarefas),
            "feitas": feitas,
            "atrasadas": sum(1 for t in tarefas if not t["feito"] and t["data"] < hoje.isoformat()),
            "proximo_prazo": futuros[0] if futuros else None,
        }

    def obter(self, id_: str) -> dict[str, Any]:
        c = self._ler(id_)
        c["situacao"] = self.resumo(c)
        return c

    def atualizar(self, id_: str, campos: dict[str, Any]) -> dict[str, Any]:
        with self._trava:
            c = self._ler(id_)
            for k, v in campos.items():
                if k in CAMPOS_EDITAVEIS:
                    c[k] = v
            self._gravar(c)
        return self.obter(id_)

    def excluir(self, id_: str) -> None:
        with self._trava:
            shutil.rmtree(self._pasta(id_))

    # --- edital ---
    def salvar_edital(self, id_: str, nome: str, conteudo: bytes) -> dict[str, Any]:
        if not conteudo.startswith(b"%PDF"):
            raise Invalido("O edital precisa ser um PDF.")
        pasta = self._pasta(id_)
        (pasta / "edital.pdf").write_bytes(conteudo)
        texto = texto_pdf(pasta / "edital.pdf")
        if len(texto.strip()) < 500:
            raise Invalido("O PDF não tem texto legível (edital escaneado?).")
        (pasta / "edital.txt").write_text(texto, "utf-8")
        with self._trava:
            c = self._ler(id_)
            c["edital"] = {
                "nome": nome,
                "bytes": len(conteudo),
                "caracteres": len(texto),
                "enviado": _agora(),
            }
            self._gravar(c)
        return self.obter(id_)

    def texto_edital(self, id_: str) -> str:
        arq = self._pasta(id_) / "edital.txt"
        if not arq.exists():
            raise Invalido("Envie o edital (PDF) antes de gerar o plano.")
        return arq.read_text("utf-8")

    # --- plano ---
    def marcar_geracao(self, id_: str, estado: str, erro: str = "") -> None:
        with self._trava:
            c = self._ler(id_)
            g = c["geracao"]
            g.update(estado=estado, erro=erro)
            if estado == "gerando":
                g.update(inicio=_agora(), fim=None)
            else:
                g["fim"] = _agora()
            self._gravar(c)

    def aplicar_estrutura(self, id_: str, estrutura: dict[str, Any]) -> dict[str, Any]:
        """Guarda a estrutura do Claude, troca os prazos vindos do edital (os manuais ficam) e
        gera o calendário de hoje até a prova."""
        with self._trava:
            c = self._ler(id_)
            c["estrutura"] = estrutura
            if not _data(c["data_prova"]) and _data(estrutura.get("data_prova")):
                c["data_prova"] = estrutura["data_prova"][:10]
            manuais = [p for p in c["prazos"] if p.get("origem") == "manual"]
            do_edital = [
                {**p, "id": uuid.uuid4().hex[:10], "origem": "edital"}
                for p in estrutura.get("prazos", [])
                if _data(p.get("data"))
            ]
            c["prazos"] = sorted(manuais + do_edital, key=lambda p: (p["data"], p.get("hora", "")))
            c["tarefas"] = []
            self._replanejar(c)
            c["geracao"].update(estado="pronto", erro="", fim=_agora())
            self._gravar(c)
        return self.obter(id_)

    def _replanejar(self, c: dict[str, Any]) -> None:
        prova = _data(c["data_prova"])
        if not prova or not c["estrutura"]:
            raise Invalido("Sem data da prova ou sem plano gerado.")
        hoje = self.hoje()
        # feitas ficam; o resto (inclusive atrasadas) é redistribuído de hoje em diante
        mantidas = [t for t in c["tarefas"] if t["feito"]]
        chaves = {t["chave"] for t in mantidas if t.get("chave")}
        novas, resumo = schedule.gerar(
            c["estrutura"], hoje, prova, c["minutos_util"], c["minutos_fds"], chaves
        )
        c["tarefas"] = sorted(mantidas + novas, key=lambda t: t["data"])
        c["resumo_plano"] = {**resumo, "gerado_em": hoje.isoformat()}

    def replanejar(self, id_: str) -> dict[str, Any]:
        with self._trava:
            c = self._ler(id_)
            self._replanejar(c)
            self._gravar(c)
        return self.obter(id_)

    def marcar_tarefa(self, id_: str, tarefa_id: str, feito: bool) -> dict[str, Any]:
        with self._trava:
            c = self._ler(id_)
            for t in c["tarefas"]:
                if t["id"] == tarefa_id:
                    t["feito"] = feito
                    t["feito_em"] = self.hoje().isoformat() if feito else None
                    self._gravar(c)
                    return t
        raise NaoEncontrado(tarefa_id)

    # --- prazos manuais ---
    def adicionar_prazo(self, id_: str, prazo: dict[str, Any]) -> dict[str, Any]:
        if not _data(prazo.get("data")):
            raise Invalido("Data inválida (use AAAA-MM-DD).")
        novo = {
            "hora": "",
            "tipo": "outro",
            "detalhe": "",
            **prazo,
            "id": uuid.uuid4().hex[:10],
            "origem": "manual",
        }
        with self._trava:
            c = self._ler(id_)
            c["prazos"] = sorted(c["prazos"] + [novo], key=lambda p: (p["data"], p.get("hora", "")))
            self._gravar(c)
        return novo

    def remover_prazo(self, id_: str, prazo_id: str) -> None:
        with self._trava:
            c = self._ler(id_)
            antes = len(c["prazos"])
            c["prazos"] = [p for p in c["prazos"] if p["id"] != prazo_id]
            if len(c["prazos"]) == antes:
                raise NaoEncontrado(prazo_id)
            self._gravar(c)

    # --- alertas ---
    def alertas(self) -> list[dict[str, Any]]:
        """Alertas de todos os concursos para hoje: prazos dos próximos 15 dias, contagem até a
        prova, tarefas de hoje e atrasadas. `nivel`: critico | aviso | info."""
        hoje = self.hoje()
        saida: list[dict[str, Any]] = []
        for arq in sorted(self.raiz.glob("*/concurso.json")):
            c = json.loads(arq.read_text("utf-8"))

            def alerta(nivel: str, texto: str, c: dict[str, Any] = c) -> None:
                saida.append(
                    {"nivel": nivel, "texto": texto, "concurso_id": c["id"], "concurso": c["nome"]}
                )

            prova = _data(c["data_prova"])
            if prova and prova >= hoje:
                dias = (prova - hoje).days
                if dias == 0:
                    alerta("critico", f"{c['nome']}: a prova é hoje.")
                elif dias <= 7:
                    alerta(
                        "critico",
                        f"{c['nome']}: prova em {dias} dia(s). Semana final: só revisão leve.",
                    )
                else:
                    alerta("info", f"{c['nome']}: faltam {dias} dias para a prova.")
            for p in c["prazos"]:
                d = _data(p["data"])
                if not d or d < hoje or (d - hoje).days > 15 or p.get("tipo") == "prova":
                    continue
                dias = (d - hoje).days
                quando = "hoje" if dias == 0 else "amanhã" if dias == 1 else f"em {dias} dias"
                hora = f" às {p['hora']}" if p.get("hora") else ""
                nivel = "critico" if dias <= 2 else "aviso" if dias <= 7 else "info"
                alerta(nivel, f"{c['nome']}: {p['titulo']} {quando} ({d.strftime('%d/%m')}{hora}).")
            pendentes = [t for t in c["tarefas"] if not t["feito"]]
            atrasadas = [t for t in pendentes if t["data"] < hoje.isoformat()]
            de_hoje = [t for t in pendentes if t["data"] == hoje.isoformat()]
            if atrasadas:
                nivel = "critico" if len(atrasadas) >= 5 else "aviso"
                alerta(
                    nivel,
                    f"{c['nome']}: {len(atrasadas)} tarefa(s) atrasada(s). Use Replanejar.",
                )
            if de_hoje:
                minutos = sum(t["minutos"] for t in de_hoje)
                alerta(
                    "info", f"{c['nome']}: hoje {len(de_hoje)} tarefa(s) de estudo ({minutos} min)."
                )
        ordem = {"critico": 0, "aviso": 1, "info": 2}
        return sorted(saida, key=lambda a: ordem[a["nivel"]])
