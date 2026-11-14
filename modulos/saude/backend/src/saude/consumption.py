"""Saúde › Consumo: controle do uso de redes sociais, vídeos, compras, notícias, conteúdo adulto e
VPN nos aparelhos Android (celular e tablets).

Os aparelhos aplicam as regras (o app Android: Vigia de acessibilidade, filtro de DNS por VPN local
e proteção contra desinstalação) e mandam o uso agregado por app e por hora. Buscas nunca chegam
aqui como texto: o aparelho classifica e manda só a categoria.

Regra da trava: apertar vale na hora; afrouxar (liberar categoria, subir limite, tirar horário, app,
domínio ou a proteção) vira uma pendência que só se aplica 24 h depois e pode ser cancelada.

Arquivos na pasta: `config.json`, `pendencias.json`, `dispositivos.json`, `uso/<dia>.json` e
`analises.json`. WhatsApp é isento (trabalho) e nunca entra nas regras.
"""

import threading
import uuid
from collections.abc import Callable
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Any

from saude.workouts import Invalid, NotFound, _write, _read

WAIT = timedelta(hours=24)
MODES = ("livre", "limite", "bloqueado")
CATEGORIES = {
    "redes_sociais": "Redes sociais",
    "videos": "Vídeos",
    "compras": "Compras",
    "noticias": "Notícias",
    "navegadores": "Navegadores",
    "adulto": "Conteúdo adulto",
    "vpn": "VPN e contorno",
}
APPS_EXEMPT = ("com.whatsapp", "com.whatsapp.w4b")
DOMAINS_EXEMPT = ("whatsapp.com", "whatsapp.net", "wa.me")
# DNS de família da Cloudflare: além da nossa lista, já barra conteúdo adulto e malware
DNS_DEFAULT = "1.1.1.3"

APPS_DEFAULT: dict[str, tuple[str, str]] = {
    "com.instagram.android": ("Instagram", "redes_sociais"),
    "com.instagram.barcelona": ("Threads", "redes_sociais"),
    "com.facebook.katana": ("Facebook", "redes_sociais"),
    "com.facebook.lite": ("Facebook Lite", "redes_sociais"),
    "com.twitter.android": ("X", "redes_sociais"),
    "com.zhiliaoapp.musically": ("TikTok", "redes_sociais"),
    "com.ss.android.ugc.trill": ("TikTok", "redes_sociais"),
    "com.zhiliaoapp.musically.go": ("TikTok Lite", "redes_sociais"),
    "com.reddit.frontpage": ("Reddit", "redes_sociais"),
    "com.patreon.android": ("Patreon", "redes_sociais"),
    "com.pinterest": ("Pinterest", "redes_sociais"),
    "com.snapchat.android": ("Snapchat", "redes_sociais"),
    "com.kwai.video": ("Kwai", "redes_sociais"),
    "com.google.android.youtube": ("YouTube", "videos"),
    "app.revanced.android.youtube": ("YouTube ReVanced", "videos"),
    "tv.twitch.android.app": ("Twitch", "videos"),
    "com.netflix.mediaclient": ("Netflix", "videos"),
    "com.shopee.br": ("Shopee", "compras"),
    "com.mercadolibre": ("Mercado Livre", "compras"),
    "com.amazon.mShop.android.shopping": ("Amazon", "compras"),
    "com.alibaba.aliexpresshd": ("AliExpress", "compras"),
    "com.einnovation.temu": ("Temu", "compras"),
    "com.zzkko": ("Shein", "compras"),
    "com.luizalabs.mlapp": ("Magalu", "compras"),
    "com.globo.g1.app": ("g1", "noticias"),
    "br.com.uol.app": ("UOL", "noticias"),
    "com.google.android.apps.magazines": ("Google Notícias", "noticias"),
    "com.android.chrome": ("Chrome", "navegadores"),
    "com.sec.android.app.sbrowser": ("Samsung Internet", "navegadores"),
    "org.mozilla.firefox": ("Firefox", "navegadores"),
    "com.microsoft.emmx": ("Edge", "navegadores"),
    "com.opera.browser": ("Opera", "navegadores"),
    "com.opera.mini.native": ("Opera Mini", "navegadores"),
    "com.brave.browser": ("Brave", "navegadores"),
    "com.duckduckgo.mobile.android": ("DuckDuckGo", "navegadores"),
    "org.torproject.torbrowser": ("Tor Browser", "vpn"),
    "com.cloudflare.onedotonedotonedotone": ("1.1.1.1 WARP", "vpn"),
}

DOMAINS_DEFAULT: dict[str, list[str]] = {
    "redes_sociais": [
        "instagram.com",
        "cdninstagram.com",
        "threads.net",
        "facebook.com",
        "fb.com",
        "tiktok.com",
        "tiktokv.com",
        "tiktokcdn.com",
        "twitter.com",
        "x.com",
        "twimg.com",
        "t.co",
        "reddit.com",
        "redd.it",
        "redditmedia.com",
        "redditstatic.com",
        "patreon.com",
        "pinterest.com",
        "snapchat.com",
        "kwai.com",
    ],
    "videos": [
        "youtube.com",
        "youtu.be",
        "googlevideo.com",
        "ytimg.com",
        "twitch.tv",
        "netflix.com",
    ],
    "compras": [
        "shopee.com.br",
        "mercadolivre.com.br",
        "mercadolibre.com",
        "amazon.com.br",
        "aliexpress.com",
        "temu.com",
        "shein.com",
        "magazineluiza.com.br",
    ],
    "noticias": [
        "g1.globo.com",
        "uol.com.br",
        "cnnbrasil.com.br",
        "metropoles.com",
        "terra.com.br",
        "news.google.com",
    ],
    "navegadores": [],
    "adulto": [
        "pornhub.com",
        "xvideos.com",
        "xnxx.com",
        "xhamster.com",
        "redtube.com",
        "youporn.com",
        "onlyfans.com",
        "fansly.com",
        "privacy.com.br",
        "chaturbate.com",
        "stripchat.com",
        "spankbang.com",
        "eporner.com",
        "brazzers.com",
        "rule34.xxx",
        "e-hentai.org",
        "nhentai.net",
    ],
    # DNS sobre HTTPS e provedores de VPN: sem eles não dá para contornar o filtro
    "vpn": [
        "dns.google",
        "cloudflare-dns.com",
        "mozilla.cloudflare-dns.com",
        "doh.opendns.com",
        "dns.quad9.net",
        "dns.nextdns.io",
        "dns.adguard.com",
        "cloudflareclient.com",
        "nordvpn.com",
        "expressvpn.com",
        "protonvpn.com",
        "surfshark.com",
        "windscribe.com",
        "hide.me",
        "psiphon.ca",
        "tunnelbear.com",
        "hotspotshield.com",
        "ultrasurf.us",
        "torproject.org",
    ],
}

# o aparelho compara as buscas com estas palavras e guarda só a categoria, nunca o texto
WORDS_DEFAULT: dict[str, list[str]] = {
    "adulto": [
        "porn",
        "porno",
        "pornô",
        "xxx",
        "nude",
        "nudes",
        "pelada",
        "peladas",
        "sexo",
        "sex ",
        "onlyfans",
        "hentai",
        "putaria",
        "nsfw",
        "xvideos",
        "camgirl",
        "erótico",
        "erotico",
        "safada",
        "gostosa",
        "privacy fotos",
        "vazado",
        "vazados",
    ],
    "vpn": ["vpn", "proxy", "desbloquear site", "tor browser", "warp 1.1.1.1", "burlar bloqueio"],
    "compras": ["comprar", "preço", "promoção", "cupom", "frete grátis", "oferta", "desconto"],
    "noticias": ["notícia", "noticias", "urgente", "polêmica", "treta", "escândalo"],
    "redes_sociais": ["instagram", "tiktok", "twitter", "reddit", "patreon", "perfil de"],
    "videos": ["youtube", "vídeo", "video engraçado", "shorts", "reels"],
}

NIGHT = {"inicio": "22:00", "fim": "07:00"}
RULES_DEFAULT: dict[str, dict[str, Any]] = {
    "redes_sociais": {"modo": "limite", "limite_min": 30, "horarios": [NIGHT]},
    "videos": {"modo": "limite", "limite_min": 30, "horarios": [NIGHT]},
    "compras": {"modo": "limite", "limite_min": 15, "horarios": []},
    "noticias": {"modo": "limite", "limite_min": 15, "horarios": []},
    "navegadores": {"modo": "livre", "limite_min": 0, "horarios": []},
    "adulto": {"modo": "bloqueado", "limite_min": 0, "horarios": []},
    "vpn": {"modo": "bloqueado", "limite_min": 0, "horarios": []},
}

KINDS_EVENT = ("busca", "bloqueio", "violacao", "instalacao")


def _config_default() -> dict[str, Any]:
    return {
        "regras": {
            c: {**r, "horarios": [dict(h) for h in r["horarios"]]} for c, r in RULES_DEFAULT.items()
        },
        "apps": {p: {"nome": n, "categoria": c} for p, (n, c) in APPS_DEFAULT.items()},
        "dominios": {c: [] for c in CATEGORIES},
        "protecao": True,
        "dns": DNS_DEFAULT,
    }


def _hour(valor: str) -> str:
    try:
        h, m = (int(x) for x in valor.split(":"))
    except ValueError as e:
        raise Invalid(f"Horário inválido: {valor}") from e
    if not (0 <= h < 24 and 0 <= m < 60):
        raise Invalid(f"Horário inválido: {valor}")
    return f"{h:02d}:{m:02d}"


def _category(c: str) -> str:
    if c not in CATEGORIES:
        raise Invalid(f"Categoria desconhecida: {c}")
    return c


def _domain(d: str) -> str:
    d = d.strip().lower().removeprefix("https://").removeprefix("http://").split("/")[0]
    d = d.removeprefix("www.").strip(".")
    if not d or "." not in d or " " in d:
        raise Invalid(f"Domínio inválido: {d}")
    if any(d == i or d.endswith("." + i) for i in DOMAINS_EXEMPT):
        raise Invalid("WhatsApp é isento: é o seu trabalho")
    return d


def validate_rule(dados: dict[str, Any]) -> dict[str, Any]:
    mode = dados.get("modo", "livre")
    if mode not in MODES:
        raise Invalid("modo: livre, limite ou bloqueado")
    limit = int(dados.get("limite_min") or 0)
    if not 0 <= limit <= 1440:
        raise Invalid("limite_min: de 0 a 1440")
    if mode == "limite" and limit <= 0:
        raise Invalid("Com limite, informe os minutos por dia")
    horarios = []
    for h in dados.get("horarios") or []:
        pair = {"inicio": _hour(h["inicio"]), "fim": _hour(h["fim"])}
        if pair["inicio"] == pair["fim"]:
            raise Invalid("Horário com início igual ao fim")
        if pair not in horarios:
            horarios.append(pair)
    return {"modo": mode, "limite_min": limit, "horarios": horarios}


def loosens(antiga: dict[str, Any], new: dict[str, Any]) -> bool:
    """A regra nova libera mais que a antiga? (então espera 24 h)"""
    if MODES.index(new["modo"]) < MODES.index(antiga["modo"]):
        return True
    if antiga["modo"] == new["modo"] == "limite" and new["limite_min"] > antiga["limite_min"]:
        return True
    if new["modo"] == "bloqueado":
        return False
    return any(h not in new["horarios"] for h in antiga["horarios"])


class Consumption:
    def __init__(self, root: str | Path, agora: Callable[[], datetime] | None = None) -> None:
        self.raiz = Path(root).expanduser()
        (self.raiz / "uso").mkdir(parents=True, exist_ok=True)
        self._agora = agora or (lambda: datetime.now(UTC))
        self._trava = threading.RLock()
        self._config = self.raiz / "config.json"
        self._pendencias = self.raiz / "pendencias.json"
        self._dispositivos = self.raiz / "dispositivos.json"
        self._analises = self.raiz / "analises.json"

    # --- configuração e trava de 24 h ---

    def _ler_config(self) -> dict[str, Any]:
        """Config com as pendências vencidas já aplicadas."""
        cfg = _read(self._config, None) or _config_default()
        pend = _read(self._pendencias, [])
        now = self._agora().isoformat()
        vencidas = [p for p in pend if p["libera_em"] <= now]
        if vencidas or not self._config.exists():
            for p in vencidas:
                self._aplicar(cfg, p["tipo"], p["alvo"], p["valor"])
            _write(self._config, cfg)
            _write(self._pendencias, [p for p in pend if p["libera_em"] > now])
        return cfg

    @staticmethod
    def _aplicar(cfg: dict[str, Any], tipo: str, target: str, valor: Any) -> None:
        if tipo == "regra":
            cfg["regras"][target] = valor
        elif tipo == "app":
            if valor is None:
                cfg["apps"].pop(target, None)
            else:
                cfg["apps"][target] = valor
        elif tipo == "dominio":
            cat, dom = valor["categoria"], valor["dominio"]
            if valor["acao"] == "incluir":
                if dom not in cfg["dominios"][cat]:
                    cfg["dominios"][cat].append(dom)
            elif dom in cfg["dominios"][cat]:
                cfg["dominios"][cat].remove(dom)
        elif tipo == "protecao":
            cfg["protecao"] = bool(valor)

    def _mudar(
        self, tipo: str, target: str, valor: Any, frouxo: bool, description: str
    ) -> dict[str, Any]:
        """Aplica já (apertar) ou agenda para daqui a 24 h (afrouxar)."""
        with self._trava:
            cfg = self._ler_config()
            if not frouxo:
                self._aplicar(cfg, tipo, target, valor)
                _write(self._config, cfg)
                return {"aplicado": True, "pendencia": None}
            now = self._agora()
            pend = [
                p
                for p in _read(self._pendencias, [])
                if not (p["tipo"] == tipo and p["alvo"] == target)
            ]
            new = {
                "id": uuid.uuid4().hex[:12],
                "tipo": tipo,
                "alvo": target,
                "valor": valor,
                "descricao": description,
                "pedido_em": now.isoformat(timespec="seconds"),
                "libera_em": (now + WAIT).isoformat(timespec="seconds"),
            }
            _write(self._pendencias, [*pend, new])
            return {"aplicado": False, "pendencia": new}

    def config(self) -> dict[str, Any]:
        with self._trava:
            cfg = self._ler_config()
            pend = _read(self._pendencias, [])
        return {
            **cfg,
            "categorias": CATEGORIES,
            "dominios_padrao": DOMAINS_DEFAULT,
            "apps_isentos": list(APPS_EXEMPT),
            "pendencias": pend,
        }

    def definir_regra(self, categoria: str, dados: dict[str, Any]) -> dict[str, Any]:
        cat = _category(categoria)
        new = validate_rule(dados)
        with self._trava:
            old = self._ler_config()["regras"][cat]
            return self._mudar(
                "regra", cat, new, loosens(old, new), f"Afrouxar {CATEGORIES[cat]}"
            )

    def definir_app(self, package: str, nome: str, categoria: str) -> dict[str, Any]:
        package = package.strip()
        if not package or " " in package:
            raise Invalid("Pacote inválido")
        if package in APPS_EXEMPT:
            raise Invalid("WhatsApp é isento: é o seu trabalho")
        cat = _category(categoria)
        with self._trava:
            current = self._ler_config()["apps"].get(package)
            value = {"nome": nome.strip() or package, "categoria": cat}
            # trocar a categoria de um app já vigiado pode tirá-lo de um bloqueio
            frouxo = current is not None and current["categoria"] != cat
            return self._mudar("app", package, value, frouxo, f"Mudar {value['nome']} de categoria")

    def remover_app(self, package: str) -> dict[str, Any]:
        with self._trava:
            current = self._ler_config()["apps"].get(package)
            if current is None:
                raise NotFound(package)
            return self._mudar("app", package, None, True, f"Deixar de vigiar {current['nome']}")

    def incluir_dominio(self, categoria: str, domain: str) -> dict[str, Any]:
        cat, dom = _category(categoria), _domain(domain)
        value = {"categoria": cat, "dominio": dom, "acao": "incluir"}
        return self._mudar("dominio", f"{cat}:{dom}", value, False, "")

    def remover_dominio(self, categoria: str, domain: str) -> dict[str, Any]:
        cat = _category(categoria)
        with self._trava:
            if domain not in self._ler_config()["dominios"][cat]:
                raise NotFound(domain)
        value = {"categoria": cat, "dominio": domain, "acao": "remover"}
        return self._mudar("dominio", f"{cat}:{domain}", value, True, f"Liberar {domain}")

    def definir_protecao(self, active: bool) -> dict[str, Any]:
        return self._mudar("protecao", "protecao", active, not active, "Desligar a proteção")

    def cancelar_pendencia(self, id_: str) -> None:
        with self._trava:
            pend = _read(self._pendencias, [])
            restantes = [p for p in pend if p["id"] != id_]
            if len(restantes) == len(pend):
                raise NotFound(id_)
            _write(self._pendencias, restantes)

    def para_dispositivo(self) -> dict[str, Any]:
        """Regras já montadas para o app Android aplicar sem precisar pensar."""
        with self._trava:
            cfg = self._ler_config()
        return {
            "regras": cfg["regras"],
            "apps": {p: a["categoria"] for p, a in cfg["apps"].items() if p not in APPS_EXEMPT},
            "nomes": {p: a["nome"] for p, a in cfg["apps"].items()},
            "dominios": {
                c: sorted({*DOMAINS_DEFAULT[c], *cfg["dominios"].get(c, [])}) for c in CATEGORIES
            },
            "palavras": WORDS_DEFAULT,
            "apps_isentos": list(APPS_EXEMPT),
            "dominios_isentos": list(DOMAINS_EXEMPT),
            "protecao": cfg["protecao"],
            "dns": cfg.get("dns") or DNS_DEFAULT,
        }

    # --- sincronização dos aparelhos ---

    def sincronizar(self, dados: dict[str, Any]) -> dict[str, Any]:
        disp = dados["dispositivo"]
        id_ = str(disp["id"])[:64]
        now = self._agora().isoformat(timespec="seconds")
        with self._trava:
            everything = _read(self._dispositivos, {})
            everything[id_] = {
                "nome": str(disp.get("nome") or id_)[:80],
                "visto_em": now,
                "estado": {k: bool(v) for k, v in (disp.get("estado") or {}).items()},
            }
            _write(self._dispositivos, everything)
            for day in dados.get("dias") or []:
                d = date.fromisoformat(day["data"]).isoformat()
                file = self.raiz / "uso" / f"{d}.json"
                current = _read(file, {"dispositivos": {}, "eventos": []})
                current["dispositivos"][id_] = {
                    "apps": [
                        {
                            "pacote": a["pacote"],
                            "nome": a.get("nome") or a["pacote"],
                            "categoria": a.get("categoria") or "outros",
                            "minutos": round(float(a.get("minutos") or 0), 1),
                            "aberturas": int(a.get("aberturas") or 0),
                        }
                        for a in day.get("apps") or []
                        if a["pacote"] not in APPS_EXEMPT
                    ],
                    "outros_min": round(float(day.get("outros_min") or 0), 1),
                    "por_hora": {
                        c: [round(float(x), 1) for x in v][:24]
                        for c, v in (day.get("por_hora") or {}).items()
                    },
                }
                _write(file, current)
            for e in dados.get("eventos") or []:
                if e.get("tipo") not in KINDS_EVENT:
                    continue
                when = datetime.fromisoformat(e["quando"])
                file = self.raiz / "uso" / f"{when.date().isoformat()}.json"
                current = _read(file, {"dispositivos": {}, "eventos": []})
                if any(x["id"] == e["id"] for x in current["eventos"]):
                    continue
                current["eventos"].append(
                    {
                        "id": str(e["id"])[:40],
                        "quando": when.isoformat(timespec="seconds"),
                        "tipo": e["tipo"],
                        "categoria": e.get("categoria") or "",
                        "pacote": e.get("pacote") or "",
                        "dispositivo": id_,
                    }
                )
                _write(file, current)
        return self.para_dispositivo()

    def dispositivos(self) -> list[dict[str, Any]]:
        with self._trava:
            everything = _read(self._dispositivos, {})
        return [{"id": k, **v} for k, v in sorted(everything.items())]

    # --- resumo e análise ---

    def resumo(self, de: str, ate: str) -> dict[str, Any]:
        d1, d2 = date.fromisoformat(de), date.fromisoformat(ate)
        if d2 < d1 or (d2 - d1).days > 366:
            raise Invalid("Período inválido")
        by_day: dict[str, dict[str, float]] = {}
        apps: dict[str, dict[str, Any]] = {}
        by_hour: dict[str, list[float]] = {}
        events: dict[str, int] = {}
        d = d1
        while d <= d2:
            day = d.isoformat()
            data = _read(self.raiz / "uso" / f"{day}.json", {"dispositivos": {}, "eventos": []})
            cats: dict[str, float] = {}
            for u in data["dispositivos"].values():
                for a in u["apps"]:
                    cats[a["categoria"]] = cats.get(a["categoria"], 0) + a["minutos"]
                    x = apps.setdefault(
                        a["pacote"],
                        {
                            "nome": a["nome"],
                            "categoria": a["categoria"],
                            "minutos": 0.0,
                            "aberturas": 0,
                        },
                    )
                    x["minutos"] += a["minutos"]
                    x["aberturas"] += a["aberturas"]
                if u.get("outros_min"):
                    cats["outros"] = cats.get("outros", 0) + u["outros_min"]
                for c, hours in u.get("por_hora", {}).items():
                    total = by_hour.setdefault(c, [0.0] * 24)
                    for i, v in enumerate(hours):
                        total[i] += v
            if cats:
                by_day[day] = {c: round(v, 1) for c, v in cats.items()}
            for e in data["eventos"]:
                key = f"{e['tipo']}:{e['categoria']}" if e["categoria"] else e["tipo"]
                events[key] = events.get(key, 0) + 1
            d += timedelta(days=1)
        items = sorted(
            ({"pacote": p, **a, "minutos": round(a["minutos"], 1)} for p, a in apps.items()),
            key=lambda a: -a["minutos"],
        )
        return {
            "de": d1.isoformat(),
            "ate": d2.isoformat(),
            "por_dia": by_day,
            "apps": items,
            "por_hora": {c: [round(v, 1) for v in h] for c, h in by_hour.items()},
            "eventos": events,
        }

    def analises(self) -> list[dict[str, Any]]:
        with self._trava:
            return list(_read(self._analises, []))

    def guardar_analise(self, analise: dict[str, Any]) -> dict[str, Any]:
        with self._trava:
            _write(self._analises, [analise, *_read(self._analises, [])][:20])
        return analise
