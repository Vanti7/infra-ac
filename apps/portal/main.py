import os
import secrets
import time

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from jose import jwt
from starlette.middleware.sessions import SessionMiddleware

OIDC_ISSUER = os.environ["OIDC_ISSUER"]
OIDC_CLIENT_ID = os.environ["OIDC_CLIENT_ID"]
OIDC_CLIENT_SECRET = os.environ["OIDC_CLIENT_SECRET"]
PUBLIC_URL = os.environ.get("PUBLIC_URL", "https://aetheriscloud.fr")
SESSION_SECRET = os.environ["SESSION_SECRET"]

REDIRECT_URI = f"{PUBLIC_URL}/callback"

# Chaque outil : url, et groupe Keycloak requis pour le voir (None = tout le monde connecté).
TOOLS = [
    {"name": "Vault", "description": "Secrets & configs", "url": "https://vault.teleport.aetheriscloud.fr", "group": "infra-admins"},
    {"name": "ArgoCD", "description": "GitOps / déploiements", "url": "https://argocd.teleport.aetheriscloud.fr", "group": "infra-admins"},
    {"name": "Harbor", "description": "Registre de conteneurs", "url": "https://harbor.teleport.aetheriscloud.fr", "group": "infra-admins"},
    {"name": "Grafana", "description": "Monitoring", "url": "https://grafana.teleport.aetheriscloud.fr", "group": "infra-admins"},
    {"name": "Gitea", "description": "Git", "url": "https://gitea.teleport.aetheriscloud.fr", "group": "infra-admins"},
    {"name": "Teleport", "description": "Accès SSH / Kubernetes (tsh)", "url": "https://teleport.aetheriscloud.fr", "group": None},
]

app = FastAPI()
app.add_middleware(SessionMiddleware, secret_key=SESSION_SECRET, same_site="lax", https_only=True)

_oidc_config_cache = {"data": None, "fetched_at": 0}


async def oidc_config():
    if _oidc_config_cache["data"] is None or time.time() - _oidc_config_cache["fetched_at"] > 3600:
        async with httpx.AsyncClient() as client:
            resp = await client.get(f"{OIDC_ISSUER}/.well-known/openid-configuration")
            resp.raise_for_status()
            _oidc_config_cache["data"] = resp.json()
            _oidc_config_cache["fetched_at"] = time.time()
    return _oidc_config_cache["data"]


async def jwks():
    config = await oidc_config()
    async with httpx.AsyncClient() as client:
        resp = await client.get(config["jwks_uri"])
        resp.raise_for_status()
        return resp.json()


def page(body: str) -> HTMLResponse:
    return HTMLResponse(f"""<!doctype html>
<html><head><meta charset="utf-8"><title>aetheriscloud</title>
<style>
  body {{ font-family: -apple-system, sans-serif; background: #0f1115; color: #eee; margin: 0; padding: 3rem 1.5rem; }}
  .wrap {{ max-width: 720px; margin: 0 auto; }}
  h1 {{ font-weight: 600; }}
  .grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 1rem; margin-top: 2rem; }}
  a.card {{ display: block; background: #1a1d24; border: 1px solid #2a2e37; border-radius: 10px; padding: 1.25rem;
            text-decoration: none; color: #eee; transition: border-color .15s; }}
  a.card:hover {{ border-color: #5b8def; }}
  a.card .name {{ font-size: 1.1rem; font-weight: 600; }}
  a.card .desc {{ color: #9aa0ab; font-size: .9rem; margin-top: .25rem; }}
  .btn {{ display: inline-block; background: #5b8def; color: #fff; padding: .7rem 1.4rem; border-radius: 8px;
          text-decoration: none; font-weight: 600; }}
  .top {{ display: flex; justify-content: space-between; align-items: center; }}
  .muted {{ color: #9aa0ab; font-size: .85rem; }}
</style></head>
<body><div class="wrap">{body}</div></body></html>""")


@app.get("/")
async def index(request: Request):
    user = request.session.get("user")
    if not user:
        return page("""
          <h1>aetheriscloud</h1>
          <p class="muted">Accès aux outils internes.</p>
          <p style="margin-top:2rem"><a class="btn" href="/login">Se connecter</a></p>
        """)

    groups = set(user.get("groups", []))
    cards = "".join(
        f'<a class="card" href="{t["url"]}" target="_blank" rel="noopener">'
        f'<div class="name">{t["name"]}</div><div class="desc">{t["description"]}</div></a>'
        for t in TOOLS
        if t["group"] is None or t["group"] in groups
    )
    return page(f"""
      <div class="top">
        <h1>aetheriscloud</h1>
        <div><span class="muted">{user.get("preferred_username", "")}</span> · <a href="/logout" class="muted">déconnexion</a></div>
      </div>
      <div class="grid">{cards}</div>
    """)


@app.get("/login")
async def login(request: Request):
    config = await oidc_config()
    state = secrets.token_urlsafe(24)
    request.session["oidc_state"] = state
    params = httpx.QueryParams({
        "client_id": OIDC_CLIENT_ID,
        "response_type": "code",
        "scope": "openid profile email",
        "redirect_uri": REDIRECT_URI,
        "state": state,
    })
    return RedirectResponse(f"{config['authorization_endpoint']}?{params}")


@app.get("/callback")
async def callback(request: Request):
    code = request.query_params.get("code")
    state = request.query_params.get("state")
    if not code or not state or state != request.session.get("oidc_state"):
        return RedirectResponse("/")

    config = await oidc_config()
    async with httpx.AsyncClient() as client:
        token_resp = await client.post(config["token_endpoint"], data={
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": REDIRECT_URI,
            "client_id": OIDC_CLIENT_ID,
            "client_secret": OIDC_CLIENT_SECRET,
        })
        token_resp.raise_for_status()
        tokens = token_resp.json()

    keys = await jwks()
    claims = jwt.decode(
        tokens["id_token"],
        keys,
        algorithms=["RS256"],
        audience=OIDC_CLIENT_ID,
        issuer=OIDC_ISSUER,
    )

    request.session["user"] = {
        "sub": claims["sub"],
        "preferred_username": claims.get("preferred_username"),
        "groups": claims.get("groups", []),
    }
    request.session.pop("oidc_state", None)
    return RedirectResponse("/")


@app.get("/logout")
async def logout(request: Request):
    request.session.clear()
    return RedirectResponse("/")


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}
