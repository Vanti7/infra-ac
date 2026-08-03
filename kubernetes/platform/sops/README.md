# sops-secrets

La clé age privée existe uniquement comme Secret Kubernetes (`sops-age-key`,
namespace `sops`), créée à la main hors Git :

```
kubectl -n sops create secret generic sops-age-key \
  --from-file=keys.txt=~/.config/sops/age/keys.txt
```

## Pourquoi pas de plugin helm-secrets/CMP pour l'instant

Le plan prévoit `sops-secrets/helm-secrets` pour déchiffrer des values Helm
chiffrées à la volée dans ArgoCD (nécessite un Config Management Plugin sur
le repo-server). On ne l'a pas mis en place : chaque appli de la Phase 6 qui
avait besoin d'un secret (mot de passe DB Gitea, client secret OIDC ArgoCD,
token Gandi, jeton de join Teleport...) l'a reçu via un Secret Kubernetes
créé hors Git et référencé directement (`existingSecret`, `secretKeyRef`),
sans jamais avoir besoin de déchiffrer un fichier de values. Construire le
CMP maintenant ajouterait de la plomberie inutilisée.

À réévaluer si un futur besoin exige vraiment un fichier de values chiffré
dans le repo (par ex. values par tenant en Phase 7, si le volume rend le
pattern "un Secret par valeur" impraticable).
