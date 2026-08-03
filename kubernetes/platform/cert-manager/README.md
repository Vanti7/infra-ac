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

## Registre

Poussée vers le registre Gitea interne (Phase 6, `kubernetes/platform/gitea/`) :
`10.42.0.11:30300/gitea_admin/cert-manager-webhook-gandi:0.2.0-aetheris`

Les nœuds k3s ont `/etc/rancher/k3s/registries.yaml` (rôles Ansible
`k3s-adm`/`k3s-agent`) configuré pour accepter ce registre en plain HTTP
(pas de TLS en interne, accès WG/cluster uniquement).
