# syntax=docker/dockerfile:1
FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# /api/arquivos: LibreOffice converts DOCX/PPTX to PDF; poppler generates the thumbnails.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libreoffice-writer libreoffice-impress libreoffice-calc poppler-utils fonts-dejavu \
    && rm -rf /var/lib/apt/lists/*


COPY plataforma/shared/pyproject.toml ./shared/pyproject.toml
COPY plataforma/shared/src ./shared/src
COPY modulos/saude/backend/pyproject.toml ./saude/pyproject.toml
COPY modulos/saude/backend/src ./saude/src
COPY modulos/estudos/backend/pyproject.toml ./estudos/pyproject.toml
COPY modulos/estudos/backend/src ./estudos/src
COPY modulos/rotinas/backend/pyproject.toml ./rotinas/pyproject.toml
COPY modulos/rotinas/backend/src ./rotinas/src
COPY modulos/design/backend/pyproject.toml ./design/pyproject.toml
COPY modulos/design/backend/src ./design/src
COPY modulos/eletronica/backend/pyproject.toml ./eletronica/pyproject.toml
COPY modulos/eletronica/backend/src ./eletronica/src
COPY modulos/codigo/backend/pyproject.toml ./codigo/pyproject.toml
COPY modulos/codigo/backend/src ./codigo/src
COPY modulos/financas/backend/pyproject.toml ./financas/pyproject.toml
COPY modulos/financas/backend/src ./financas/src
COPY modulos/painel/backend/pyproject.toml ./painel/pyproject.toml
COPY modulos/painel/backend/src ./painel/src
COPY modulos/concursos/backend/pyproject.toml ./concursos/pyproject.toml
COPY modulos/concursos/backend/src ./concursos/src
COPY modulos/empreendimento/youtube/pyproject.toml ./youtube/pyproject.toml
COPY modulos/empreendimento/youtube/src ./youtube/src
COPY plataforma/backend/pyproject.toml ./backend/pyproject.toml
COPY plataforma/backend/src ./backend/src
RUN pip install --no-cache-dir ./shared ./saude ./estudos ./rotinas ./design ./eletronica ./codigo ./financas ./painel ./concursos ./youtube ./backend

RUN useradd --create-home --uid 1000 gateway
USER gateway
# Created by the app user: the agent-data volume inherits the owner (otherwise it is born as root and cannot write).
RUN mkdir -p /home/gateway/agent-data

EXPOSE 48080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:48080/health', timeout=3)" || exit 1

# --proxy-headers: the real IP (login lockout) comes from nginx; the port is only published on 127.0.0.1.
CMD ["uvicorn", "backend.main:app", "--host", "0.0.0.0", "--port", "48080", "--proxy-headers", "--forwarded-allow-ips", "*", "--no-server-header"]
