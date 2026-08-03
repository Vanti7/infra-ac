# cert-manager-webhook-gandi — image maison

Le webhook cert-manager pour le DNS-01 Gandi n'a pas d'implémentation officielle
maintenue par Gandi ni par jetstack : uniquement des forks communautaires
indépendants du template `cert-manager/webhook-example`. L'image publique la
plus utilisée (`bwolf/cert-manager-webhook-gandi` sur Docker Hub) date de 2021.

Plutôt que de faire tourner ce binaire non maintenu avec le token API Gandi
en secret cluster-wide, on a revu le code source et construit notre propre
image.

## Source

- Repo : https://github.com/bwolf/cert-manager-webhook-gandi (tag `release-v0.2.0`)
- Revue : `main.go` implémente l'interface `webhook.Solver` standard de
  cert-manager (Present/CleanUp), lit le token Gandi depuis un Secret
  Kubernetes référencé par le ClusterIssuer (pas de valeur en dur).
  `gandiclient.go` n'appelle que `https://api.gandi.net/v5/livedns` (API
  officielle, la même que `lego` utilise déjà pour Keycloak) — aucune
  télémétrie, aucun appel tiers.

## Build

Buildé le 2026-08-03 via `podman` sur `k3s-w1` (pas de Docker sur le poste
d'admin macOS) :

```
git clone --depth 1 --branch release-v0.2.0 \
  https://github.com/bwolf/cert-manager-webhook-gandi.git
# Dockerfile patché : ajout de -buildvcs=false au go build
# (le bind-mount readonly de podman casse la détection VCS de Go)
podman build --target=image --build-arg GO_VERSION=1.23 \
  --build-arg TARGETOS=linux --build-arg TARGETARCH=amd64 \
  --build-arg TARGETPLATFORM=linux/amd64 \
  -t cert-manager-webhook-gandi:0.2.0-aetheris .
```

## Bug corrigé : schéma d'authentification Gandi

Le code d'origine (2021) envoie `Authorization: Apikey <token>` — c'était le
schéma des anciennes API Keys Gandi. Les Personal Access Tokens actuels
(ceux que le plan demande de générer, Phase 0) exigent `Authorization: Bearer
<token>` ; avec `Apikey`, Gandi répond **403 Forbidden sur tout**, y compris
un token parfaitement valide (diagnostiqué en comparant un test `curl` en
`Apikey` vs `Bearer` sur le même enregistrement que `lego` gère déjà avec
succès pour Keycloak). Patch dans `gandiclient.go` (`doRequest`) :
`Apikey %s` → `Bearer %s`. Retaggé `0.2.1-aetheris` pour forcer le re-pull
(les nœuds avaient déjà mis en cache `0.2.0-aetheris`).

## Registre

Poussée vers Harbor (`kubernetes/platform/harbor/`), projet `aetheriscloud` :
`10.42.0.11:30002/aetheriscloud/cert-manager-webhook-gandi:0.2.1-aetheris`

(Initialement poussée vers le registre Gitea le temps de la Phase 6 — Gitea
garde son rôle Git, Harbor a pris le rôle de registre de conteneurs juste
après, l'utilisateur ayant plusieurs autres apps à héberger.)

Les nœuds k3s ont `/etc/rancher/k3s/registries.yaml` (rôles Ansible
`k3s-adm`/`k3s-agent`) configuré pour accepter Gitea et Harbor en plain HTTP
(pas de TLS en interne, accès WG/cluster uniquement).
