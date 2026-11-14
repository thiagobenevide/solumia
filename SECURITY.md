# Security Policy

This is a single-user personal project without a stable release yet. The full security architecture (login,
scopes, headers, tunnel hardening, threat model) is documented in
[docs/layers/security.md](docs/layers/security.md).

## Supported versions

Only the `master` branch receives fixes.

## Reporting a vulnerability

Use GitHub's **private vulnerability reporting** (*Security* tab, *Report a vulnerability*). Do not open a
public issue for exploitable flaws, and do not include keys, tokens or production domains in the report.
Describe the affected component (backend, worker, app, infrastructure), the impact and how to reproduce it.

## Protections in place

- Password login (**scrypt**) with mandatory **TOTP**; **JWT HS256** sessions with generation-based revocation
  ("sign out everywhere").
- Fail-secure: with no key or login configured, the API denies every request. Client keys carry **scopes**.
- Commands executed on the PC (Código module) require a recently entered TOTP code.
- Brute-force protection: nginx `limit_req` plus per-IP lockout in the backend; the real client IP is trusted
  only from Cloudflare's ranges.
- Security headers (CSP, HSTS, `nosniff`, `X-Frame-Options`), CORS without credentials, `no-store` on the API.
- **No open ports at home**: the worker and the tunnel are outbound; the SSH tunnel allows only the reverse
  forward.

## Secrets and `.env` files

- `*.env.example` files are committed with variable names and formats only; `.env`, `.env.prd`, `.env.pc`,
  `google/` and service accounts are **never** committed (`.gitignore`).
- Generate the login values (password hash, TOTP secret, JWT key):
  `.venv/bin/python -m backend.auth.security`. In production, `infra/scripts/instalar_vps` generates and
  reuses the remaining secrets.
- Client key: `python -c "import secrets; print('sk_live_' + secrets.token_urlsafe(32))"`.

## If a secret leaks

1. **Revoke and rotate** it immediately; the old value is compromised even after removal.
2. For sessions, use "sign out everywhere" (bumps the token generation).
3. Purge the secret from history (`git filter-repo` or BFG) before any public push.
