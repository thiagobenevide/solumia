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

from saude.treinos import Invalido, NaoEncontrado, _gravar, _ler

ESPERA = timedelta(hours=24)
MODOS = ("livre", "limite", "bloqueado")
CATEGORIAS = {
    "redes_sociais": "Redes sociais",
    "videos": "Vídeos",
    "compras": "Compras",
    "noticias": "Notícias",
    "navegadores": "Navegadores",
    "adulto": "Conteúdo adulto",
    "vpn": "VPN e contorno",
}
APPS_ISENTOS = ("com.whatsapp", "com.whatsapp.w4b")
DOMINIOS_ISENTOS = ("whatsapp.com", "whatsapp.net", "wa.me")
# DNS de família da Cloudflare: além da nossa lista, já barra conteúdo adulto e malware
DNS_PADRAO = "1.1.1.3"

APPS_PADRAO: dict[str, tuple[str, str]] = {
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

DOMINIOS_PADRAO: dict[str, list[str]] = {
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
PALAVRAS_PADRAO: dict[str, list[str]] = {
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

NOITE = {"inicio": "22:00", "fim": "07:00"}
REGRAS_PADRAO: dict[str, dict[str, Any]] = {
    "redes_sociais": {"modo": "limite", "limite_min": 30, "horarios": [NOITE]},
    "videos": {"modo": "limite", "limite_min": 30, "horarios": [NOITE]},
    "compras": {"modo": "limite", "limite_min": 15, "horarios": []},
    "noticias": {"modo": "limite", "limite_min": 15, "horarios": []},
    "navegadores": {"modo": "livre", "limite_min": 0, "horarios": []},
    "adulto": {"modo": "bloqueado", "limite_min": 0, "horarios": []},
    "vpn": {"modo": "bloqueado", "limite_min": 0, "horarios": []},
}

TIPOS_EVENTO = ("busca", "bloqueio", "violacao", "instalacao")


def _config_padrao() -> dict[str, Any]:
    return {
        "regras": {
            c: {**r, "horarios": [dict(h) for h in r["horarios"]]} for c, r in REGRAS_PADRAO.items()
        },
        "apps": {p: {"nome": n, "categoria": c} for p, (n, c) in APPS_PADRAO.items()},
        "dominios": {c: [] for c in CATEGORIAS},
        "protecao": True,
        "dns": DNS_PADRAO,
    }


def _hora(valor: str) -> str:
    try:
        h, m = (int(x) for x in valor.split(":"))
    except ValueError as e:
        raise Invalido(f"Horário inválido: {valor}") from e
    if not (0 <= h < 24 and 0 <= m < 60):
        raise Invalido(f"Horário inválido: {valor}")
    return f"{h:02d}:{m:02d}"


def _categoria(c: str) -> str:
    if c not in CATEGORIAS:
        raise Invalido(f"Categoria desconhecida: {c}")
    return c


def _dominio(d: str) -> str:
    d = d.strip().lower().removeprefix("https://").removeprefix("http://").split("/")[0]
    d = d.removeprefix("www.").strip(".")
    if not d or "." not in d or " " in d:
        raise Invalido(f"Domínio inválido: {d}")
    if any(d == i or d.endswith("." + i) for i in DOMINIOS_ISENTOS):
        raise Invalido("WhatsApp é isento: é o seu trabalho")
    return d


def validar_regra(dados: dict[str, Any]) -> dict[str, Any]:
    modo = dados.get("modo", "livre")
    if modo not in MODOS:
        raise Invalido("modo: livre, limite ou bloqueado")
    limite = int(dados.get("limite_min") or 0)
    if not 0 <= limite <= 1440:
        raise Invalido("limite_min: de 0 a 1440")
    if modo == "limite" and limite <= 0:
        raise Invalido("Com limite, informe os minutos por dia")
    horarios = []
    for h in dados.get("horarios") or []:
        par = {"inicio": _hora(h["inicio"]), "fim": _hora(h["fim"])}
        if par["inicio"] == par["fim"]:
            raise Invalido("Horário com início igual ao fim")
        if par not in horarios:
            horarios.append(par)
    return {"modo": modo, "limite_min": limite, "horarios": horarios}


def afrouxa(antiga: dict[str, Any], nova: dict[str, Any]) -> bool:
    """A regra nova libera mais que a antiga? (então espera 24 h)"""
    if MODOS.index(nova["modo"]) < MODOS.index(antiga["modo"]):
        return True
    if antiga["modo"] == nova["modo"] == "limite" and nova["limite_min"] > antiga["limite_min"]:
        return True
    if nova["modo"] == "bloqueado":
        return False
    return any(h not in nova["horarios"] for h in antiga["horarios"])


class Consumo:
    def __init__(self, raiz: str | Path, agora: Callable[[], datetime] | None = None) -> None:
        self.raiz = Path(raiz).expanduser()
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
        cfg = _ler(self._config, None) or _config_padrao()
        pend = _ler(self._pendencias, [])
        agora = self._agora().isoformat()
        vencidas = [p for p in pend if p["libera_em"] <= agora]
        if vencidas or not self._config.exists():
            for p in vencidas:
                self._aplicar(cfg, p["tipo"], p["alvo"], p["valor"])
            _gravar(self._config, cfg)
            _gravar(self._pendencias, [p for p in pend if p["libera_em"] > agora])
        return cfg

    @staticmethod
    def _aplicar(cfg: dict[str, Any], tipo: str, alvo: str, valor: Any) -> None:
        if tipo == "regra":
            cfg["regras"][alvo] = valor
        elif tipo == "app":
            if valor is None:
                cfg["apps"].pop(alvo, None)
            else:
                cfg["apps"][alvo] = valor
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
        self, tipo: str, alvo: str, valor: Any, frouxo: bool, descricao: str
    ) -> dict[str, Any]:
        """Aplica já (apertar) ou agenda para daqui a 24 h (afrouxar)."""
        with self._trava:
            cfg = self._ler_config()
            if not frouxo:
                self._aplicar(cfg, tipo, alvo, valor)
                _gravar(self._config, cfg)
                return {"aplicado": True, "pendencia": None}
            agora = self._agora()
            pend = [
                p
                for p in _ler(self._pendencias, [])
                if not (p["tipo"] == tipo and p["alvo"] == alvo)
            ]
            nova = {
                "id": uuid.uuid4().hex[:12],
                "tipo": tipo,
                "alvo": alvo,
                "valor": valor,
                "descricao": descricao,
                "pedido_em": agora.isoformat(timespec="seconds"),
                "libera_em": (agora + ESPERA).isoformat(timespec="seconds"),
            }
            _gravar(self._pendencias, [*pend, nova])
            return {"aplicado": False, "pendencia": nova}

    def config(self) -> dict[str, Any]:
        with self._trava:
            cfg = self._ler_config()
            pend = _ler(self._pendencias, [])
        return {
            **cfg,
            "categorias": CATEGORIAS,
            "dominios_padrao": DOMINIOS_PADRAO,
            "apps_isentos": list(APPS_ISENTOS),
            "pendencias": pend,
        }

    def definir_regra(self, categoria: str, dados: dict[str, Any]) -> dict[str, Any]:
        cat = _categoria(categoria)
        nova = validar_regra(dados)
        with self._trava:
            antiga = self._ler_config()["regras"][cat]
            return self._mudar(
                "regra", cat, nova, afrouxa(antiga, nova), f"Afrouxar {CATEGORIAS[cat]}"
            )

    def definir_app(self, pacote: str, nome: str, categoria: str) -> dict[str, Any]:
        pacote = pacote.strip()
        if not pacote or " " in pacote:
            raise Invalido("Pacote inválido")
        if pacote in APPS_ISENTOS:
            raise Invalido("WhatsApp é isento: é o seu trabalho")
        cat = _categoria(categoria)
        with self._trava:
            atual = self._ler_config()["apps"].get(pacote)
            valor = {"nome": nome.strip() or pacote, "categoria": cat}
            # trocar a categoria de um app já vigiado pode tirá-lo de um bloqueio
            frouxo = atual is not None and atual["categoria"] != cat
            return self._mudar("app", pacote, valor, frouxo, f"Mudar {valor['nome']} de categoria")

    def remover_app(self, pacote: str) -> dict[str, Any]:
        with self._trava:
            atual = self._ler_config()["apps"].get(pacote)
            if atual is None:
                raise NaoEncontrado(pacote)
            return self._mudar("app", pacote, None, True, f"Deixar de vigiar {atual['nome']}")

    def incluir_dominio(self, categoria: str, dominio: str) -> dict[str, Any]:
        cat, dom = _categoria(categoria), _dominio(dominio)
        valor = {"categoria": cat, "dominio": dom, "acao": "incluir"}
        return self._mudar("dominio", f"{cat}:{dom}", valor, False, "")

    def remover_dominio(self, categoria: str, dominio: str) -> dict[str, Any]:
        cat = _categoria(categoria)
        with self._trava:
            if dominio not in self._ler_config()["dominios"][cat]:
                raise NaoEncontrado(dominio)
        valor = {"categoria": cat, "dominio": dominio, "acao": "remover"}
        return self._mudar("dominio", f"{cat}:{dominio}", valor, True, f"Liberar {dominio}")

    def definir_protecao(self, ativa: bool) -> dict[str, Any]:
        return self._mudar("protecao", "protecao", ativa, not ativa, "Desligar a proteção")

    def cancelar_pendencia(self, id_: str) -> None:
        with self._trava:
            pend = _ler(self._pendencias, [])
            restantes = [p for p in pend if p["id"] != id_]
            if len(restantes) == len(pend):
                raise NaoEncontrado(id_)
            _gravar(self._pendencias, restantes)

    def para_dispositivo(self) -> dict[str, Any]:
        """Regras já montadas para o app Android aplicar sem precisar pensar."""
        with self._trava:
            cfg = self._ler_config()
        return {
            "regras": cfg["regras"],
            "apps": {p: a["categoria"] for p, a in cfg["apps"].items() if p not in APPS_ISENTOS},
            "nomes": {p: a["nome"] for p, a in cfg["apps"].items()},
            "dominios": {
                c: sorted({*DOMINIOS_PADRAO[c], *cfg["dominios"].get(c, [])}) for c in CATEGORIAS
            },
            "palavras": PALAVRAS_PADRAO,
            "apps_isentos": list(APPS_ISENTOS),
            "dominios_isentos": list(DOMINIOS_ISENTOS),
            "protecao": cfg["protecao"],
            "dns": cfg.get("dns") or DNS_PADRAO,
        }

    # --- sincronização dos aparelhos ---

    def sincronizar(self, dados: dict[str, Any]) -> dict[str, Any]:
        disp = dados["dispositivo"]
        id_ = str(disp["id"])[:64]
        agora = self._agora().isoformat(timespec="seconds")
        with self._trava:
            todos = _ler(self._dispositivos, {})
            todos[id_] = {
                "nome": str(disp.get("nome") or id_)[:80],
                "visto_em": agora,
                "estado": {k: bool(v) for k, v in (disp.get("estado") or {}).items()},
            }
            _gravar(self._dispositivos, todos)
            for dia in dados.get("dias") or []:
                d = date.fromisoformat(dia["data"]).isoformat()
                arq = self.raiz / "uso" / f"{d}.json"
                atual = _ler(arq, {"dispositivos": {}, "eventos": []})
                atual["dispositivos"][id_] = {
                    "apps": [
                        {
                            "pacote": a["pacote"],
                            "nome": a.get("nome") or a["pacote"],
                            "categoria": a.get("categoria") or "outros",
                            "minutos": round(float(a.get("minutos") or 0), 1),
                            "aberturas": int(a.get("aberturas") or 0),
                        }
                        for a in dia.get("apps") or []
                        if a["pacote"] not in APPS_ISENTOS
                    ],
                    "outros_min": round(float(dia.get("outros_min") or 0), 1),
                    "por_hora": {
                        c: [round(float(x), 1) for x in v][:24]
                        for c, v in (dia.get("por_hora") or {}).items()
                    },
                }
                _gravar(arq, atual)
            for e in dados.get("eventos") or []:
                if e.get("tipo") not in TIPOS_EVENTO:
                    continue
                quando = datetime.fromisoformat(e["quando"])
                arq = self.raiz / "uso" / f"{quando.date().isoformat()}.json"
                atual = _ler(arq, {"dispositivos": {}, "eventos": []})
                if any(x["id"] == e["id"] for x in atual["eventos"]):
                    continue
                atual["eventos"].append(
                    {
                        "id": str(e["id"])[:40],
                        "quando": quando.isoformat(timespec="seconds"),
                        "tipo": e["tipo"],
                        "categoria": e.get("categoria") or "",
                        "pacote": e.get("pacote") or "",
                        "dispositivo": id_,
                    }
                )
                _gravar(arq, atual)
        return self.para_dispositivo()

    def dispositivos(self) -> list[dict[str, Any]]:
        with self._trava:
            todos = _ler(self._dispositivos, {})
        return [{"id": k, **v} for k, v in sorted(todos.items())]

    # --- resumo e análise ---

    def resumo(self, de: str, ate: str) -> dict[str, Any]:
        d1, d2 = date.fromisoformat(de), date.fromisoformat(ate)
        if d2 < d1 or (d2 - d1).days > 366:
            raise Invalido("Período inválido")
        por_dia: dict[str, dict[str, float]] = {}
        apps: dict[str, dict[str, Any]] = {}
        por_hora: dict[str, list[float]] = {}
        eventos: dict[str, int] = {}
        d = d1
        while d <= d2:
            dia = d.isoformat()
            dados = _ler(self.raiz / "uso" / f"{dia}.json", {"dispositivos": {}, "eventos": []})
            cats: dict[str, float] = {}
            for u in dados["dispositivos"].values():
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
                for c, horas in u.get("por_hora", {}).items():
                    soma = por_hora.setdefault(c, [0.0] * 24)
                    for i, v in enumerate(horas):
                        soma[i] += v
            if cats:
                por_dia[dia] = {c: round(v, 1) for c, v in cats.items()}
            for e in dados["eventos"]:
                chave = f"{e['tipo']}:{e['categoria']}" if e["categoria"] else e["tipo"]
                eventos[chave] = eventos.get(chave, 0) + 1
            d += timedelta(days=1)
        lista = sorted(
            ({"pacote": p, **a, "minutos": round(a["minutos"], 1)} for p, a in apps.items()),
            key=lambda a: -a["minutos"],
        )
        return {
            "de": d1.isoformat(),
            "ate": d2.isoformat(),
            "por_dia": por_dia,
            "apps": lista,
            "por_hora": {c: [round(v, 1) for v in h] for c, h in por_hora.items()},
            "eventos": eventos,
        }

    def analises(self) -> list[dict[str, Any]]:
        with self._trava:
            return list(_ler(self._analises, []))

    def guardar_analise(self, analise: dict[str, Any]) -> dict[str, Any]:
        with self._trava:
            _gravar(self._analises, [analise, *_ler(self._analises, [])][:20])
        return analise
