"""Job openings (Jobs section of Empreendimento): Claude Code searches the web for openings matching
the profile (positions, location, remote) and they stay in a list to follow.

Data in `<root>/vagas/vagas.json`: `perfil`, `itens` (id → opening) and `claude` (last search).
`estado` of each opening: `nova` → `interesse` | `candidatei` | `descartada`. Each opening gets
`geo`
(IBGE municipality, `{}` when it could not be located) for the map, and `curriculo` (résumé id)
when Claude adapts the default résumé to it."""

import hashlib
import json
import logging
import re
from collections.abc import Awaitable, Callable
from datetime import UTC, date, datetime
from pathlib import Path
from typing import Any

from exams.geo import Geo
from exams.resumes import Resumes

logger = logging.getLogger("exams.jobs")

ExecuteClaude = Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]

STATES = ("nova", "interesse", "candidatei", "descartada")
MODALITIES = ("remoto", "hibrido", "presencial")
CONTRACTS = ("clt", "pj", "estagio", "outro", "nao_informado")
UFS = {
    *("AC", "AL", "AP", "AM", "BA", "CE", "DF", "ES", "GO", "MA", "MT", "MS", "MG", "PA"),
    *("PB", "PR", "PE", "PI", "RJ", "RN", "RS", "RO", "RR", "SC", "SP", "SE", "TO"),
}
PROFILE_DEFAULT: dict[str, Any] = {
    "areas": ["Desenvolvimento de software", "Engenharia de dados"],
    "cargos": "Desenvolvedor, Engenheiro de software, Engenheiro de dados, Data engineer, "
    "Analytics engineer, Desenvolvedor Python",
    "empresas": [],
    "local": "Custódia/PE",
    "modalidades": ["remoto", "hibrido", "presencial"],
    "senioridade": "",
    "observacoes": "",
}

# One Claude round per area × source group: a single search for everything times out and brings
# few. The key goes into the opening's `fonte` when Claude does not say which one it was.
SOURCES: dict[str, str] = {
    "linkedin": "on LinkedIn Jobs (linkedin.com/jobs, search with site:linkedin.com/jobs/view)",
    "plataformas": "on the recruiting platforms companies use: Gupy (*.gupy.io), Greenhouse "
    "(boards.greenhouse.io, job-boards.greenhouse.io), Lever (jobs.lever.co), Workable "
    "(apply.workable.com), Solides (*.vagas.solides.com.br), InHire (*.inhire.app), Recrutei, "
    "Abler/Kenoby, Pandapé, Teamtailor, SmartRecruiters and Ashby (search with site:<domain> "
    "and the position)",
    "carreiras": "on the companies' own career sites (pages /carreiras, /careers, "
    "/trabalhe-conosco): banks and fintechs (Itaú, Bradesco, Nubank, Inter, C6, PicPay, "
    "Mercado Pago, Stone, PagBank), retail and e-commerce (Magalu, Americanas, Via, Mercado "
    "Livre), technology (iFood, TOTVS, CI&T, Stefanini, Zup, Accenture, ThoughtWorks, Globant), "
    "big techs and foreign companies that hire remotely in Brazil",
    "agregadores": "on the IT job aggregators and job sites: Indeed, Glassdoor, Programathor, "
    "GeekHunter, Remotar, Trampos, Vagas.com, Catho, InfoJobs, BNE, Revelo, Hipsters.jobs, "
    "We Work Remotely and RemoteOK (from these, only the ones that accept Brazil)",
}

_TEXT = {"type": "string"}
SCHEMA_CLAUDE = {
    "type": "object",
    "properties": {
        "vagas": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "titulo": _TEXT,
                    "empresa": _TEXT,
                    "local": _TEXT,
                    "cidade": _TEXT,
                    "uf": _TEXT,
                    "modalidade": {"type": "string", "enum": list(MODALITIES)},
                    "contrato": {"type": "string", "enum": list(CONTRACTS)},
                    "salario": _TEXT,
                    "senioridade": _TEXT,
                    "url": _TEXT,
                    "publicada_em": _TEXT,
                    "fonte": _TEXT,
                    "resumo": _TEXT,
                },
                "required": ["titulo", "empresa", "modalidade", "contrato", "url", "resumo"],
            },
        }
    },
    "required": ["vagas"],
}

SYSTEM_CLAUDE = """You search the internet (WebSearch and WebFetch) for open job positions in Brazil
(CLT, PJ or internship) for a candidate. Check several sources (LinkedIn, Gupy, Indeed, Glassdoor,
Catho, Programathor, GeekHunter, company career sites) and only bring positions you confirmed are
open, with the direct link to the position in "url". "modalidade": remoto, hibrido or presencial.
"contrato": clt, pj, estagio, outro (temporary, cooperative…) or nao_informado, as the position
announces. "cidade" and "uf" (state abbreviation): where the position is (for remote ones, the
company headquarters; empty if unknown). "salario" as announced (empty if not given). "publicada_em"
as YYYY-MM-DD when known. "fonte": where the position is published (LinkedIn, Gupy, Greenhouse,
company site…). "resumo": 1–2 sentences in Brazilian Portuguese with the main stack/requirements. Do
not invent data or repeat the same position."""

SYSTEM_RESUME = """You tailor résumés to job positions. You receive the position and the base résumé
in Markdown; if needed, open the position link (WebFetch) to read the requirements. Return in
"markdown" the complete résumé, in Brazilian Portuguese, with the same structure as the base:
rewrite the summary and reorder skills and experiences to highlight what the position asks for,
using its keywords. Do not invent experiences, companies, dates, degrees, numbers or certifications
that are not in the base; passages in square brackets [like this] stay as they are."""
SCHEMA_RESUME = {
    "type": "object",
    "properties": {"markdown": _TEXT},
    "required": ["markdown"],
}


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _city_uf(v: dict[str, Any]) -> tuple[str, str]:
    """City and state of the opening: from Claude's fields or from the `local` text ("Recife/PE",
    "São Paulo, SP", "Remoto - SP"…); a state alone becomes its capital on the map."""
    uf = str(v.get("uf") or "").strip().upper()
    if uf in UFS:
        return str(v.get("cidade") or "").strip(), uf
    local = str(v.get("local") or "")
    m = re.search(r"([^,/()|–-]+?)\s*[,/–-]\s*([A-Z]{2})\b", local)
    if m and m.group(2) in UFS:
        return m.group(1).strip(), m.group(2)
    ufs = [u for u in re.findall(r"\b[A-Z]{2}\b", local) if u in UFS]
    return ("", ufs[0]) if ufs else ("", "")


def _id(company: str, titulo: str, url: str) -> str:
    base = f"{company}|{titulo}".lower() if company.strip() else url.strip().lower()
    return hashlib.sha1(re.sub(r"\s+", " ", base).encode()).hexdigest()[:12]


class Slots:
    def __init__(
        self, root: Path | str, hoje: Callable[[], date] = date.today, geo: Geo | None = None
    ) -> None:
        self.arquivo = Path(root).expanduser() / "vagas" / "vagas.json"
        self.hoje = hoje
        self.geo = geo
        self.resumes = Resumes(root)
        self.pesquisando = False
        self.progress = ""
        self.generating: set[str] = set()
        self.errors_resume: dict[str, str] = {}

    def _read(self) -> dict[str, Any]:
        if not self.arquivo.exists():
            return {"perfil": dict(PROFILE_DEFAULT), "itens": {}, "claude": None}
        data: dict[str, Any] = json.loads(self.arquivo.read_text())
        data.setdefault("perfil", dict(PROFILE_DEFAULT))
        data.setdefault("itens", {})
        return data

    def _write(self, dados: dict[str, Any]) -> None:
        self.arquivo.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.arquivo.with_suffix(".tmp")
        tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=1))
        tmp.replace(self.arquivo)

    def list_all(self) -> dict[str, Any]:
        data = self._read()
        items = sorted(
            data["itens"].values(),
            key=lambda v: (v.get("publicada_em") or "", v.get("visto_em") or ""),
            reverse=True,
        )
        for v in items:
            if v.get("curriculo") and not self.resumes.existe(v["curriculo"]):
                v.pop("curriculo")
        return {
            "perfil": data["perfil"],
            "vagas": items,
            "gerando_curriculo": sorted(self.generating),
            "erros_curriculo": self.errors_resume,
            "claude": data.get("claude"),
            "pesquisando": self.pesquisando,
            "progresso": self.progress,
        }

    def save_profile(self, profile: dict[str, Any]) -> dict[str, Any]:
        data = self._read()
        data["perfil"] = {**PROFILE_DEFAULT, **profile}
        self._write(data)
        return data["perfil"]

    def marcar(self, id_: str, estado: str) -> dict[str, Any] | None:
        data = self._read()
        slot = data["itens"].get(id_)
        if slot is None:
            return None
        slot["estado"] = estado
        self._write(data)
        return dict(slot)

    def remover(self, id_: str) -> bool:
        data = self._read()
        if data["itens"].pop(id_, None) is None:
            return False
        self._write(data)
        return True

    async def locate(self) -> None:
        """Sets `geo` on the openings that have not tried yet (the municipalities CSV stays
        cached)."""
        if self.geo is None:
            return
        found: dict[str, dict[str, Any]] = {}
        for id_, v in self._read()["itens"].items():
            if "geo" in v:
                continue
            city, uf = _city_uf(v)
            try:
                m = await self.geo.municipio(city, uf) if uf else None
            except Exception:
                logger.warning("Sem os municípios do IBGE para o mapa das vagas", exc_info=True)
                break
            found[id_] = m or {}
        if not found:
            return
        # reread: the search may have written in the meantime
        data = self._read()
        for id_, m in found.items():
            if id_ in data["itens"]:
                data["itens"][id_]["geo"] = m
        self._write(data)

    async def generate_resume(self, id_: str, execute: ExecuteClaude) -> dict[str, Any]:
        """Adapts the default résumé to the opening through Claude Code and saves it as
        `vaga-<id>`."""
        slot = self._read()["itens"].get(id_)
        base = self.resumes.default()
        if slot is None or base is None:
            self.generating.discard(id_)
            return {"erro": "vaga ou currículo padrão não encontrado"}
        self.generating.add(id_)
        self.errors_resume.pop(id_, None)
        try:
            fields = ("titulo", "empresa", "local", "modalidade", "contrato", "senioridade")
            lines = [f"{k}: {slot[k]}" for k in fields if slot.get(k)]
            prompt = "\n".join(
                [
                    "Position:",
                    *lines,
                    f"resumo: {slot.get('resumo', '')}",
                    f"link: {slot.get('url', '')}",
                    "",
                    "Base résumé:",
                    "",
                    base["conteudo"],
                ]
            )
            r = await execute(
                {
                    "prompt": prompt,
                    "sistema": SYSTEM_RESUME,
                    "esquema": SCHEMA_RESUME,
                    "limite_s": 600,
                    "effort": "medium",
                    "ferramentas": "WebFetch",
                }
            )
            markdown = str(r.get("markdown") or "").strip()
            if not markdown:
                raise ValueError("o Claude não devolveu o currículo")
            name = " · ".join(str(slot[k]) for k in ("titulo", "empresa") if slot.get(k))
            c = self.resumes.salvar(f"vaga-{id_}", name, markdown + "\n", vaga=id_)
            data = self._read()
            if id_ in data["itens"]:
                data["itens"][id_]["curriculo"] = c["id"]
                self._write(data)
            return c
        except Exception as e:
            logger.exception("Falha ao gerar o currículo da vaga %s", id_)
            self.errors_resume[id_] = str(e)[:200] or type(e).__name__
            return {"erro": self.errors_resume[id_]}
        finally:
            self.generating.discard(id_)

    def _rounds(self, profile: dict[str, Any]) -> list[tuple[str, str]]:
        """(label, prompt) of each round: area × source and, if any, the followed companies."""
        today = self.hoje().isoformat()
        modes = ", ".join(profile.get("modalidades") or MODALITIES)
        # optional city: when empty, on-site and hybrid openings come from all of Brazil
        local = str(profile.get("local", PROFILE_DEFAULT["local"])).strip()
        near = (
            f"On-site and hybrid ones only near {local} (up to about 300 km) or in the Northeast "
            "capitals; remote ones, from all of Brazil."
            if local
            else "Positions from all of Brazil."
        )
        common = [
            f"Accepted work modes: {modes}. {near}",
            f"Suitable positions: {profile.get('cargos') or PROFILE_DEFAULT['cargos']}.",
        ]
        if profile.get("senioridade"):
            common.append(f"Seniority: {profile['senioridade']}.")
        if profile.get("observacoes"):
            common.append(f"Candidate's notes: {profile['observacoes']}.")
        common.append("Prioritize the ones published in the last 30 days. Bring as many as you can "
                      "confirm.")
        rounds = [
            (
                f"{area} · {source}",
                " ".join([f"Today is {today}. List open {area} positions {where}.", *common]),
            )
            for area in profile.get("areas") or PROFILE_DEFAULT["areas"]
            for source, where in SOURCES.items()
        ]
        areas = profile.get("areas") or PROFILE_DEFAULT["areas"]
        empresas = [e for e in profile.get("empresas") or [] if str(e).strip()]
        if empresas:
            rounds.append(
                (
                    "empresas acompanhadas",
                    " ".join(
                        [
                            f"Today is {today}. Open the careers site (or the page on Gupy, "
                            "Greenhouse, Lever etc.) of each of these companies and list the open "
                            f"{', '.join(areas)} positions: {', '.join(map(str, empresas))}.",
                            *common,
                        ]
                    ),
                )
            )
        return rounds

    async def search_claude(self, execute: ExecuteClaude) -> dict[str, Any]:
        """Searches through Claude Code (PC worker), one round per area × source; one failing does
        not lose the others. Openings found come in as `nova` and the ones already seen keep the
        state the user marked."""
        if self.pesquisando:
            return {"ja_rodando": True}
        self.pesquisando = True
        errors: list[str] = []
        found = 0
        try:
            rounds = self._rounds(self._read()["perfil"])
            for n, (label, prompt) in enumerate(rounds, 1):
                self.progress = f"{n}/{len(rounds)} · {label}"
                try:
                    r = await execute(
                        {
                            "prompt": prompt,
                            "sistema": SYSTEM_CLAUDE,
                            "esquema": SCHEMA_CLAUDE,
                            "limite_s": 900,
                            "effort": "medium",
                            "ferramentas": "WebSearch,WebFetch",
                        }
                    )
                    found += self._join(r, label)
                except Exception as e:
                    logger.exception("Falha na pesquisa de vagas (%s)", label)
                    errors.append(f"{label}: {str(e)[:150] or type(e).__name__}")
        finally:
            data = self._read()
            data["claude"] = {"em": _now(), "achadas": found, "erro": "; ".join(errors)}
            self._write(data)
            self.pesquisando = False
            self.progress = ""
        await self.locate()
        if errors and not found:
            return {"erro": "; ".join(errors)}
        return {"achadas": found}

    def _join(self, r: dict[str, Any], rounded: str = "") -> int:
        data = self._read()
        items: dict[str, Any] = data["itens"]
        n = 0
        for v in r.get("vagas") or []:
            if not isinstance(v, dict) or not v.get("titulo"):
                continue
            fields = {
                k: str(v.get(k) or "")
                for k in (
                    "titulo",
                    "empresa",
                    "local",
                    "cidade",
                    "uf",
                    "modalidade",
                    "contrato",
                    "salario",
                    "senioridade",
                    "url",
                    "publicada_em",
                    "fonte",
                    "resumo",
                )
            }
            fields["area"] = rounded.split(" · ")[0] if " · " in rounded else ""
            fields["fonte"] = fields["fonte"] or rounded.split(" · ")[-1]
            id_ = _id(fields["empresa"], fields["titulo"], fields["url"])
            old = items.get(id_) or {"id": id_, "estado": "nova", "visto_em": _now()}
            if (fields["cidade"], fields["uf"]) != (old.get("cidade", ""), old.get("uf", "")):
                old.pop("geo", None)  # the place changed: locate it again
            # area and source stay those of the first round that found the opening
            for k in ("area", "fonte"):
                fields[k] = old.get(k) or fields[k]
            items[id_] = {**old, **fields, "atualizada_em": _now()}
            n += 1
        self._write(data)
        return n
