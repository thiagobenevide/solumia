from starlette.middleware.base import BaseHTTPMiddleware, RequestResponseEndpoint
from starlette.requests import Request
from starlette.responses import Response

# A API só devolve JSON/arquivos: nada de scripts, frames ou cache de respostas autenticadas.
_CABECALHOS = {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
    "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
    "Cross-Origin-Opener-Policy": "same-origin",
}


class CabecalhosSegurancaMiddleware(BaseHTTPMiddleware):
    def __init__(self, app: object, hsts: bool) -> None:
        super().__init__(app)  # type: ignore[arg-type]
        self.hsts = hsts

    async def dispatch(self, request: Request, call_next: RequestResponseEndpoint) -> Response:
        resposta = await call_next(request)
        for nome, valor in _CABECALHOS.items():
            resposta.headers.setdefault(nome, valor)
        if request.url.path.startswith("/api/") or request.url.path.startswith("/v1/"):
            resposta.headers.setdefault("Cache-Control", "no-store")
        if self.hsts:
            resposta.headers["Strict-Transport-Security"] = "max-age=63072000; includeSubDomains"
        return resposta
