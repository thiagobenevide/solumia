"""Health › Consumption: control of the use of social networks, videos, shopping, news, adult
content and VPN on the Android devices (phone and tablets).

The devices enforce the rules (the Android app: accessibility Watcher, DNS filter through a local
VPN and uninstall protection) and send the usage aggregated per app and per hour. Searches never
arrive here as text: the device classifies them and sends only the category.

Lock rule: tightening applies immediately; loosening (allowing a category, raising a limit,
removing a schedule, app, domain or the protection) becomes a pending change that only applies
24 h later and can be cancelled.

Files in the folder: `config.json`, `pendencias.json`, `dispositivos.json`, `uso/<dia>.json` and
`analises.json`. WhatsApp is exempt (work) and never enters the rules.
"""

import threading
import uuid
from collections.abc import Callable
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Any

from health.workouts import Invalid, NotFound, _read, _write

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
# Cloudflare family DNS: besides our list, it already blocks adult content and malware
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
    # DNS over HTTPS and VPN providers: without them the filter cannot be bypassed
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

# the device matches searches against these words and keeps only the category, never the text
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


def _hour(value: str) -> str:
    try:
        h, m = (int(x) for x in value.split(":"))
    except ValueError as e:
        raise Invalid(f"Horário inválido: {value}") from e
    if not (0 <= h < 24 and 0 <= m < 60):
        raise Invalid(f"Horário inválido: {value}")
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


def loosens(old: dict[str, Any], new: dict[str, Any]) -> bool:
    """Does the new rule allow more than the old one? (then it waits 24 h)"""
    if MODES.index(new["modo"]) < MODES.index(old["modo"]):
        return True
    if old["modo"] == new["modo"] == "limite" and new["limite_min"] > old["limite_min"]:
        return True
    if new["modo"] == "bloqueado":
        return False
    return any(h not in new["horarios"] for h in old["horarios"])


class Consumption:
    def __init__(self, root: str | Path, now: Callable[[], datetime] | None = None) -> None:
        self.root = Path(root).expanduser()
        (self.root / "uso").mkdir(parents=True, exist_ok=True)
        self._now = now or (lambda: datetime.now(UTC))
        self._lock = threading.RLock()
        self._config = self.root / "config.json"
        self._pendencias = self.root / "pendencias.json"
        self._devices = self.root / "dispositivos.json"
        self._analyses = self.root / "analises.json"

    # --- configuration and 24 h lock ---

    def _read_config(self) -> dict[str, Any]:
        """Config with the due pending changes already applied."""
        cfg = _read(self._config, None) or _config_default()
        pend = _read(self._pendencias, [])
        now = self._now().isoformat()
        vencidas = [p for p in pend if p["libera_em"] <= now]
        if vencidas or not self._config.exists():
            for p in vencidas:
                self._apply(cfg, p["tipo"], p["alvo"], p["valor"])
            _write(self._config, cfg)
            _write(self._pendencias, [p for p in pend if p["libera_em"] > now])
        return cfg

    @staticmethod
    def _apply(cfg: dict[str, Any], tipo: str, target: str, value: Any) -> None:
        if tipo == "regra":
            cfg["regras"][target] = value
        elif tipo == "app":
            if value is None:
                cfg["apps"].pop(target, None)
            else:
                cfg["apps"][target] = value
        elif tipo == "dominio":
            cat, dom = value["categoria"], value["dominio"]
            if value["acao"] == "incluir":
                if dom not in cfg["dominios"][cat]:
                    cfg["dominios"][cat].append(dom)
            elif dom in cfg["dominios"][cat]:
                cfg["dominios"][cat].remove(dom)
        elif tipo == "protecao":
            cfg["protecao"] = bool(value)

    def _change(
        self, tipo: str, target: str, value: Any, frouxo: bool, description: str
    ) -> dict[str, Any]:
        """Applies now (tighten) or schedules for 24 h from now (loosen)."""
        with self._lock:
            cfg = self._read_config()
            if not frouxo:
                self._apply(cfg, tipo, target, value)
                _write(self._config, cfg)
                return {"aplicado": True, "pendencia": None}
            now = self._now()
            pend = [
                p
                for p in _read(self._pendencias, [])
                if not (p["tipo"] == tipo and p["alvo"] == target)
            ]
            new = {
                "id": uuid.uuid4().hex[:12],
                "tipo": tipo,
                "alvo": target,
                "valor": value,
                "descricao": description,
                "pedido_em": now.isoformat(timespec="seconds"),
                "libera_em": (now + WAIT).isoformat(timespec="seconds"),
            }
            _write(self._pendencias, [*pend, new])
            return {"aplicado": False, "pendencia": new}

    def config(self) -> dict[str, Any]:
        with self._lock:
            cfg = self._read_config()
            pend = _read(self._pendencias, [])
        return {
            **cfg,
            "categorias": CATEGORIES,
            "dominios_padrao": DOMAINS_DEFAULT,
            "apps_isentos": list(APPS_EXEMPT),
            "pendencias": pend,
        }

    def definir_rule(self, categoria: str, dados: dict[str, Any]) -> dict[str, Any]:
        cat = _category(categoria)
        new = validate_rule(dados)
        with self._lock:
            old = self._read_config()["regras"][cat]
            return self._change(
                "regra", cat, new, loosens(old, new), f"Afrouxar {CATEGORIES[cat]}"
            )

    def definir_app(self, package: str, nome: str, categoria: str) -> dict[str, Any]:
        package = package.strip()
        if not package or " " in package:
            raise Invalid("Pacote inválido")
        if package in APPS_EXEMPT:
            raise Invalid("WhatsApp é isento: é o seu trabalho")
        cat = _category(categoria)
        with self._lock:
            current = self._read_config()["apps"].get(package)
            value = {"nome": nome.strip() or package, "categoria": cat}
            # changing the category of an already watched app can take it out of a block
            frouxo = current is not None and current["categoria"] != cat
            label = f"Mudar {value['nome']} de categoria"
            return self._change("app", package, value, frouxo, label)

    def remove_app(self, package: str) -> dict[str, Any]:
        with self._lock:
            current = self._read_config()["apps"].get(package)
            if current is None:
                raise NotFound(package)
            return self._change("app", package, None, True, f"Deixar de vigiar {current['nome']}")

    def include_domain(self, categoria: str, domain: str) -> dict[str, Any]:
        cat, dom = _category(categoria), _domain(domain)
        value = {"categoria": cat, "dominio": dom, "acao": "incluir"}
        return self._change("dominio", f"{cat}:{dom}", value, False, "")

    def remove_domain(self, categoria: str, domain: str) -> dict[str, Any]:
        cat = _category(categoria)
        with self._lock:
            if domain not in self._read_config()["dominios"][cat]:
                raise NotFound(domain)
        value = {"categoria": cat, "dominio": domain, "acao": "remover"}
        return self._change("dominio", f"{cat}:{domain}", value, True, f"Liberar {domain}")

    def definir_protection(self, active: bool) -> dict[str, Any]:
        return self._change("protecao", "protecao", active, not active, "Desligar a proteção")

    def cancel_pendencia(self, id_: str) -> None:
        with self._lock:
            pend = _read(self._pendencias, [])
            restantes = [p for p in pend if p["id"] != id_]
            if len(restantes) == len(pend):
                raise NotFound(id_)
            _write(self._pendencias, restantes)

    def for_dispositivo(self) -> dict[str, Any]:
        """Rules already assembled for the Android app to apply without thinking."""
        with self._lock:
            cfg = self._read_config()
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

    # --- device sync ---

    def sync(self, dados: dict[str, Any]) -> dict[str, Any]:
        disp = dados["dispositivo"]
        id_ = str(disp["id"])[:64]
        now = self._now().isoformat(timespec="seconds")
        with self._lock:
            everything = _read(self._devices, {})
            everything[id_] = {
                "nome": str(disp.get("nome") or id_)[:80],
                "visto_em": now,
                "estado": {k: bool(v) for k, v in (disp.get("estado") or {}).items()},
            }
            _write(self._devices, everything)
            for day in dados.get("dias") or []:
                d = date.fromisoformat(day["data"]).isoformat()
                file = self.root / "uso" / f"{d}.json"
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
                file = self.root / "uso" / f"{when.date().isoformat()}.json"
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
        return self.for_dispositivo()

    def devices(self) -> list[dict[str, Any]]:
        with self._lock:
            everything = _read(self._devices, {})
        return [{"id": k, **v} for k, v in sorted(everything.items())]

    # --- summary and analysis ---

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
            data = _read(self.root / "uso" / f"{day}.json", {"dispositivos": {}, "eventos": []})
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

    def analyses(self) -> list[dict[str, Any]]:
        with self._lock:
            return list(_read(self._analyses, []))

    def store_analysis(self, analysis: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            _write(self._analyses, [analysis, *_read(self._analyses, [])][:20])
        return analysis
