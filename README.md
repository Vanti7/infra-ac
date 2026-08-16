# infra-ac

Infrastructure-as-code d'**aetheriscloud** : plateforme d'hébergement k3s
multi-tenant sur une seule Dedibox (Proxmox VE), un seul port public (443/tcp),
tout le reste derrière WireGuard.

## Architecture en 10 lignes

- **Hôte** : Proxmox VE (`stargate-px1`), HAProxy en TCP passthrough (routage
  par SNI, un seul port public), WireGuard pour toute la gestion.
- **Identité** : Keycloak (LXC `iam`) comme IdP OIDC/SAML unique pour toutes
  les apps ; Teleport (LXC `teleport`) pour l'accès bastion (SSH/kube/apps
  admin), comptes locaux + WebAuthn.
- **Cluster** : k3s 3 nœuds (1 control-plane taintée + 2 agents), ArgoCD en
  app-of-apps (`kubernetes/platform/`), secrets chiffrés SOPS/age + ksops
  (`kubernetes/secrets/`).
- **Plateforme** : Traefik (ingress public), cert-manager (Let's Encrypt DNS-01
  Gandi), Harbor (registre privé), Gitea, NetBox (CMDB), monitoring
  (Prometheus/Grafana/Alertmanager), Zabbix (supervision hors cluster),
  portail client maison.
- **Tenants** : un namespace par client (`cust-<nom>`), quotas + RBAC +
  NetworkPolicy via un chart Helm piloté par `ApplicationSet`.

## Prérequis

- Un compte Dedibox/Online avec accès Proxmox VE
- Un domaine géré chez Gandi (DNS + ACME DNS-01)
- `terraform`, `ansible` (voir [`ansible/README.md`](ansible/README.md) pour
  les variables requises), `sops`/`age`, `kubectl`, `helm`

## Ordre de déploiement

Détail complet phase par phase dans
[`plan-deploiement-dedibox.md`](plan-deploiement-dedibox.md) (cible) et
[`workflow-deploiement-dedibox.md`](workflow-deploiement-dedibox.md) (ce qui a
réellement été fait, écarts compris) :

1. Proxmox + réseau + entrée unique (HAProxy/WireGuard)
2. Provisioning Terraform (VM/LXC)
3. Keycloak (IAM)
4. Teleport (bastion)
5. k3s + ArgoCD
6. Plateforme GitOps (`kubernetes/platform/`)
7. Multi-tenancy (`kubernetes/tenants/`)
8. Backups & DR — **non fait**, bloqué sur le NAS maison
9. Durcissement & exploitation continue

Reconstruction complète (perte totale) : voir
[`disaster-recovery.md`](disaster-recovery.md). Tâches courantes une fois le
cluster debout : voir [`exploitation.md`](exploitation.md).

## Variables requises

Voir [`ansible/README.md`](ansible/README.md) — secrets chiffrés
(`ansible/group_vars/all/secrets.sops.yaml`, SOPS/age) et variables en clair
(`ansible/group_vars/`).

## État de l'audit

[`audit-infra-ac.md`](audit-infra-ac.md) : écarts identifiés par sévérité,
annotés au fil de leur remédiation.

## Licence

Propriétaire — tous droits réservés. Pas de licence open source, ce repo
décrit l'infra privée d'une activité commerciale.
