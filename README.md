# Solumia

A local-first, all-in-one platform for projects, routines, finances, studies, health and content
production. Language models run on your own GPU (near-zero cost per token), a small VPS exposes
the API over HTTPS, and the data syncs between PC, laptop, tablet and phone. Notes are plain
Markdown with YAML frontmatter, compatible with Obsidian.

## How it fits together

```
 Flutter app (phone, tablet, desktop)       OpenAI-compatible clients
        │ HTTPS (JWT)                               │ HTTPS (API key)
        ▼                                           ▼
 ┌─────────────────────────────────────────────────────────────┐
 │ VPS: nginx (TLS) → backend (FastAPI)                        │
 │   /v1/* OpenAI-compatible · /api/* domains · /sync          │
 │   PostgreSQL, scheduler, push notifications                 │
 └──────────────────────────────▲──────────────────────────────┘
                                │ WebSocket opened by the worker
 ┌──────────────────────────────┴──────────────────────────────┐
 │ PC with GPU: worker (llama.cpp, job executor),              │
 │ video pipeline, Obsidian vault, media storage               │
 └─────────────────────────────────────────────────────────────┘
```

The full design and its decisions are in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Repository layout

| Path | What it is |
|---|---|
| `plataforma/backend` | FastAPI backend that runs on the VPS |
| `plataforma/worker` | Worker on the GPU PC; connects to the backend over WebSocket |
| `plataforma/shared` | WebSocket protocol and shared schemas |
| `plataforma/app` | Main Flutter app (Android, Linux, web) that joins every module |
| `plataforma/app_core`, `plataforma/app_notas` | Shared Flutter packages: API client, theme, notes |
| `modulos/<module>` | One domain each (`backend/`, `worker/`, `app/` when it has code) |
| `configurador` | Desktop installer and control panel (see below) |
| `infra` | Docker Compose, nginx configs and operational scripts |
| `docs` | Architecture, configurator design and gateway docs |

Domain modules: files, business (YouTube video pipeline), studies, health, routines, design
(whiteboard), electronics (circuit CAD), code (remote Claude Code), finances and dashboard.

## Getting started

The **configurator** installs and operates everything without a terminal: account, VPS (domain,
TLS, firewall, SSH hardening), folders, the GPU worker and the apps for each device.

```bash
configurador/empacotar_deb
sudo apt install ./configurador/build/solumia-configurador_*_amd64.deb
```

It installs to `/opt/solumia-configurador` and adds an entry to the app menu. Later
updates come from the **Update** button on its home screen. Details in
[`configurador/README.md`](configurador/README.md).

## Development

| Task | Command |
|---|---|
| Python dependencies (uv workspace) | `uv sync` |
| Flutter dependencies (pub workspace) | `flutter pub get` at the repository root |
| Lint and tests for what changed | `infra/scripts/verificar [paths]` |
| Run the backend locally | `infra/scripts/run_gateway.sh` |
| Run the worker | `infra/scripts/run_worker.sh` |
| Build the app | `cd plataforma/app && flutter build linux` (or `apk`) |

The video pipeline (`modulos/empreendimento/esteira`) has its own virtualenv and its own
`CLAUDE.md`.

## Releases

Apps are published as GitHub Releases. The configurator only downloads them after verifying a
GPG-signed `SHA256SUMS.txt` against the pinned release key:

```
401962C4ED4FA05AE568116E68F5115E5B50B880   Solumia Release Signing Key
```

- **CI:** pushing a tag `vX.Y.Z` runs [`.github/workflows/release.yml`](.github/workflows/release.yml),
  which builds the Android APK and the Linux AppImage, signs the checksums and publishes the release.
- **From a PC:** `infra/scripts/release_local X.Y.Z` does the same when GitHub Actions is unavailable.
- **Keys:** `infra/scripts/setup_release_keys` creates the signing key, the Android keystore, an
  encrypted backup and the repository secrets. Run it on your own PC, never on the VPS.

To verify a download by hand:

```bash
gpg --import release-signing-key.asc
gpg --verify SHA256SUMS.txt.asc SHA256SUMS.txt
sha256sum --check --ignore-missing SHA256SUMS.txt
```

## Security

See [`SECURITY.md`](SECURITY.md) for the security policy and
[`docs/layers/security.md`](docs/layers/security.md) for the security architecture.

## License

[MIT](LICENSE) © 2026 Thiago Benevide
