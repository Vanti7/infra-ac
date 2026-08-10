# Audit `infra-ac` & cahier de reconstruction

> **Objet** : audit de l'existant (repo `Vanti7/infra-ac`, 42 commits, phases 0→7 + 10) et spécification pour une reconstruction propre.
> **Usage prévu** : document de référence à fournir à Claude Code comme contexte de départ. Les écarts sont identifiés (`C1`…`M20`) pour être cités directement dans les prompts (« corrige `C4` », « implémente le lot 2 »).
> **Date de l'audit** : 2026-08-10 — état du repo au commit `e4c1dd8`.

---

## 0. Comment utiliser ce document avec Claude Code

Ordre recommandé :

1. Ouvrir le nouveau repo, y déposer ce fichier en `docs/audit-et-cahier-des-charges.md`.
2. Lui faire lire **§2 (architecture cible)** + **§5 (règles d'ingénierie)** avant toute écriture de code — ce sont les invariants.
3. Travailler **lot par lot** (§4). Un lot = une PR. Ne pas passer au lot suivant tant que ses critères d'acceptation ne sont pas vérifiés **sur la machine**, pas sur le papier.
4. Le §3 (registre des écarts) sert de check-list de non-régression : chaque écart doit être soit corrigé, soit explicitement assumé avec sa raison écrite dans le repo.

Trois règles à imposer à l'agent dès le premier prompt :

- **Rien ne rentre dans le cluster qui ne soit pas dans Git** (secrets compris, chiffrés). Si une étape exige un `kubectl create secret` manuel, c'est un bug de conception, pas une étape.
- **Aucune nouvelle fonctionnalité tant que le lot « survie » (lot 1) n'est pas terminé.** L'infra actuelle est fonctionnellement riche et opérationnellement nue ; c'est exactement l'erreur à ne pas reproduire.
- **Toute déviation par rapport au plan est documentée avec sa cause racine.** C'est déjà la pratique du repo actuel (`workflow-deploiement-dedibox.md`) et c'est sa plus grande qualité — à conserver telle quelle.

---

## 1. État des lieux — ce qui existe aujourd'hui

### 1.1 Architecture physique et réseau

| Élément | Réalité |
|---|---|
| Support | Une seule Dedibox START-2-L (Xeon D-1531 6C/12T, 32 Go, 2×250 Go SSD), Proxmox VE 9, nœud `stargate-px1` |
| Disques | **LVM mono-disque sur `sda`** + pool ZFS **mono-disque** `local-zfs` sur `sdb`. Pas de RAID (déviation Phase 1.1) |
| Entrée publique | **Un seul port : 443/tcp.** HAProxy en TCP passthrough, routage par SNI. 51820/udp pour WireGuard |
| Management | WireGuard uniquement (10.99.0.0/24), 3 peers (Mac, PC boulot, téléphone). Pas de peer homelab/pfSense |
| Réseau interne | `vmbr1` 10.42.0.0/24, NAT MASQUERADE vers `vmbr0` |
| Firewall | iptables manuel + `netfilter-persistent` (le firewall PVE natif a été abandonné : il force le `/24` public en ipset trusted) |

Routage SNI HAProxy → backends :

```
teleport.aetheriscloud.fr        → 10.42.0.5:443   (CT teleport)
*.teleport.aetheriscloud.fr      → 10.42.0.5:443
*.teleport.cluster.local         → 10.42.0.5:443   (SNI hex du client gRPC tsh)
sso.aetheriscloud.fr             → 10.42.0.6:443   (CT iam, nginx → Keycloak)
kube.aetheriscloud.fr            → 10.42.0.11:6443 (apiserver k3s)
défaut (*.apps, apex, harbor…)   → 10.42.0.21/.22:443 (Traefik, send-proxy-v2)
```

### 1.2 Machines

| Nom | Type | IP | Rôle |
|---|---|---|---|
| `stargate-px1` | hôte PVE | publique + 10.42.0.1 + 10.99.0.1 | hyperviseur, firewall, HAProxy, WireGuard, NAT |
| `teleport` | LXC | 10.42.0.5 | bastion Teleport Community v18 (auth+proxy+ssh, ACME TLS-ALPN-01, `proxy_listener_mode: multiplex`) |
| `iam` | LXC | 10.42.0.6 | PostgreSQL 17 + Keycloak 26.7.0 + nginx (TLS via lego, PROXY protocol) |
| `k3s-adm` | VM | 10.42.0.11 | k3s server v1.36.2+k3s1, tainté, OIDC apiserver |
| `k3s-w1` | VM | 10.42.0.21 | agent |
| `k3s-w2` | VM | 10.42.0.22 | agent |

k3s : `disable: [traefik, servicelb]`, `secrets-encryption: true`, `cluster-cidr: 10.44.0.0/16`, `service-cidr: 10.43.0.0/16` (le défaut `10.42.0.0/16` entrait en collision avec le réseau physique).

### 1.3 Chaîne d'outillage

- **Terraform** (`bpg/proxmox` ~0.66) : template Debian 13 genericcloud, 3 VM clonées, 2 LXC (avec `remote-exec` pour créer `admin` et désactiver root).
- **Ansible** : rôles `base`, `keycloak`, `teleport`, `teleport-agent`, `k3s-adm`, `k3s-agent`. Inventaire statique.
- **ArgoCD** : installé hors GitOps par `helm install`, app-of-apps sur `kubernetes/platform/` (`directory.recurse: true`), ApplicationSet git-generator sur `kubernetes/tenants/*.values.yaml`.

### 1.4 Applications déployées

| App | Exposition | Auth |
|---|---|---|
| Traefik | hostPort 443 sur les 2 workers, PROXY protocol | — |
| cert-manager + webhook Gandi **maison** | — | — |
| kube-prometheus-stack | Grafana via Teleport app | OIDC Keycloak |
| teleport-kube-agent (`kube,app`) | — | Teleport local + WebAuthn |
| Vault | via Teleport app | OIDC Keycloak |
| Gitea | via Teleport app | OIDC Keycloak |
| Harbor | `harbor.aetheriscloud.fr` (Traefik, cert LE) | OIDC Keycloak, **projet public** |
| NetBox | `netbox.aetheriscloud.fr` (Traefik, cert LE) | OIDC Keycloak |
| Portail (FastAPI maison) | `aetheriscloud.fr` | OIDC Keycloak |
| docs-public / docs-internal (Docusaurus) | `docs.aetheriscloud.fr` / Teleport app | — / Teleport |
| `whoami` (test) | `whoami.apps.aetheriscloud.fr` | **aucune** |

### 1.5 Ce qui n'a jamais été fait

- **Phase 8 — backups & DR** : intégralement. Aucun PBS, aucun dump, aucune copie hors-site, aucun runbook testé.
- **Phase 9 — durcissement/exploitation** : intégralement. Pas de kube-bench, pas de Renovate, pas de revue d'accès, pas d'alerte configurée.
- **Phase 10.4** : inventaire Ansible dynamique NetBox, job CI `sync-netbox`, rôle `dns-interne`.
- **Phase 11** : vrai portail client (tickets, self-service namespace).

### 1.6 Ce qui est objectivement bon et à reprendre tel quel

À ne **pas** jeter lors de la reconstruction :

1. **Le modèle d'exposition** : un seul port public, routage SNI, tout le reste derrière WireGuard. C'est propre et ça a tenu.
2. **La discipline documentaire** : chaque déviation tracée avec cause racine et diagnostic. Collision flannel `10.42.0.0/16`, SNI hexadécimal du gRPC Teleport, `lookup` Helm inopérant sous `helm template`, `existingSecret` vs `existingSecretName`, kube-router qui n'unit pas plusieurs NetworkPolicy — ce sont des heures de debug capitalisées, à reporter dans le nouveau repo.
3. **Le chart `onboarding-client`** : namespace + RBAC par groupe OIDC + ResourceQuota + LimitRange + NetworkPolicy consolidée, piloté par ApplicationSet. Le design est bon, il manque juste 2 règles (cf. `I8`).
4. **Keycloak comme IdP unique** avec `oidc-groups-prefix=oidc:` sur l'apiserver. Cohérent de bout en bout.
5. **Le webhook Gandi rebuild + patché** (`Apikey` → `Bearer`) : à garder, mais à publier ailleurs que sur Harbor (cf. `C4`).

---

## 2. Architecture cible — invariants à respecter

Ce qui ne change pas :

- Un seul port public (443/tcp) + WireGuard. Aucune surface d'admin sur DNS public.
- Keycloak = IdP unique. Teleport garde ses comptes locaux (OIDC = Enterprise, non négociable sans licence).
- Terraform pour le provisioning Proxmox, Ansible pour la configuration système, ArgoCD pour tout ce qui vit dans le cluster.
- k3s multi-nœuds (1 server tainté + 2 agents).

Ce qui change :

| Sujet | Avant | Cible |
|---|---|---|
| Visibilité du repo | public | **privé** |
| Disques | mono-disque, pas de RAID | **RAID1 (ZFS mirror)** dès l'installation |
| Secrets | ~10 `kubectl create secret` manuels | **SOPS/age, tout dans Git chiffré** |
| ArgoCD | `helm install` manuel | **self-managed** (`Application` qui se gère elle-même) |
| Hôte PVE | 100 % manuel | **rôles Ansible** `haproxy`, `wireguard`, `firewall`, `base-pve` |
| Backups | néant | **PBS + dumps applicatifs + hors-site, testés** |
| Alerting | néant | **route Alertmanager active dès le lot 1** |
| Images maison | Harbor uniquement | **registre externe (ghcr.io) pour les images de bootstrap** |
| Validation | néant | **CI obligatoire sur PR** |
| `AppProject` | `default` partout | **projets dédiés** `platform` / `tenants` avec restrictions |

---

## 3. Registre des écarts

Sévérité : **C** = critique (bloque la reconstruction ou expose l'infra), **I** = important (dette structurelle), **M** = mineur (à traiter au passage).

### C — Critiques

| ID | Écart | Preuve | Remédiation |
|---|---|---|---|
| **C1** | **Le repo est public** alors que tout le design suppose « privé » (le plan et la Phase 0 le disent explicitement). Publie : IP publique, règles firewall exactes, plan d'adressage, quelles surfaces sont protégées et lesquelles ne le sont pas, comptes admin, absence de backups, emplacement des clés d'unseal Vault. Aucun secret n'est committé (historique complet vérifié) — donc pas de rotation urgente, mais la carte d'attaque est publiée. | `gh repo view` → `Public` ; clone anonyme réussi | `gh repo edit <repo> --visibility private`. Séparer runbook interne (privé) et doc publique. |
| **C2** | **Aucun backup + aucune redondance disque.** Cumul de la déviation Phase 1.1 (pas de RAID) et de la Phase 8 jamais démarrée. Une panne de disque = perte totale : base Keycloak, `state.db` k3s, tous les PV (Gitea, Harbor, NetBox, Vault). | Phase 8 : 6 cases non cochées ; workflow §1.1 | RAID1 ZFS à la réinstallation. PBS via WG + timers `pg_dump` / `sqlite3 .backup`. Restore testé, pas seulement documenté. |
| **C3** | **Le GitOps n'est pas reproductible.** ~10 secrets créés hors Git à la main (`gitea-db-secret`, `grafana-oidc-secret`, `harbor-admin-secret`, `netbox-superuser`, `gandi-credentials`, `teleport-kube-agent-join-token`, `sops-age-key`, `portal-secrets`, `argocd-secret`, `gitea-oauth-keycloak`). SOPS est configuré mais **inutilisé**. ArgoCD lui-même est hors GitOps. Le repo seul ne permet pas de reconstruire. | `platform/sops/README.md` ; `existingSecret` partout | SOPS + `helm-secrets` via CMP ArgoCD, ou `sops-secrets-operator`. ArgoCD self-managed. |
| **C4** | **Dépendance circulaire au cold start.** L'image `cert-manager-webhook-gandi` est tirée de `harbor.aetheriscloud.fr` en HTTPS, dont le certificat est émis par le ClusterIssuer qui a besoin de ce webhook. Le fallback plain-HTTP a été retiré de `registries.yaml` au passage de Harbor derrière Traefik. Cluster neuf → deadlock : pas de webhook, pas de cert, pas de pull. Même problème pour le portail et les docs. | `platform/cert-manager/webhook-gandi-application.yaml` + `group_vars/k3s_cluster.yml` | Publier les images de bootstrap sur `ghcr.io` (public, gratuit), **ou** conserver un mirror interne de secours dans `registries.yaml`. |
| **C5** | **Vault est un piège opérationnel.** Standalone, storage `file`, pas d'auto-unseal → scellé à chaque redémarrage de pod/nœud, unseal manuel 3/5. Clés + root token dans `secrets/vault_init.json` sur le poste d'admin, non sauvegardé. Contient déjà les configs WireGuard. Apporte peu face à SOPS + Secrets k8s. | `platform/vault/application.yaml` ; workflow Phase 6.2 | **Décision à trancher** (§4.0). Si conservé : auto-unseal + backup du storage + clés hors-ligne. Sinon : retirer, SOPS suffit. |

### I — Importantes

| ID | Écart | Preuve | Remédiation |
|---|---|---|---|
| **I6** | **Zéro NetworkPolicy sur les namespaces plateforme.** Les tenants sont isolés, la plateforme ne l'est pas du tout. Un pod compromis (docs, portail, scanner Trivy de Harbor) atteint l'apiserver, Keycloak (10.42.0.6), Vault et l'hôte PVE (10.42.0.1). Asymétrie incohérente pour une infra multi-tenant. | aucun `kind: NetworkPolicy` sous `platform/` | Default-deny par namespace plateforme + allow explicites. Bloquer l'egress vers 10.42.0.1 et 10.99.0.0/24 depuis les pods. |
| **I7** | **Le monitoring ne monitore rien.** Pas de `storageSpec` → Prometheus en `emptyDir`, la `retention: 10d` est fictive. Grafana : persistance désactivée par défaut. Alertmanager : **aucune route de notification**. Conséquence directe : rien ne préviendra de `C2`. | `platform/monitoring/application.yaml` | `storageSpec` sur Prometheus + persistance Grafana + route Alertmanager (mail/ntfy) **dans le même lot**. |
| **I8** | **Prometheus ne peut pas scraper les tenants.** La netpol tenant n'autorise en ingress que l'intra-namespace et `traefik`. Le « alertes par tenant » du plan ne fonctionnera jamais. | `tenants/onboarding-client/templates/networkpolicy.yaml` | Ajouter `namespaceSelector: kubernetes.io/metadata.name: monitoring` en ingress. Décider aussi si les tenants ont droit à un egress Internet (aujourd'hui : non, jamais documenté). |
| **I9** | **Aucun garde-fou sur `main`.** Pas de branch protection (assumé : GitHub Free sur repo privé), **et** aucune CI, **et** en face `automated` + `prune: true` + `selfHeal: true` + `directory.recurse: true` + tous les `Application` en `project: default`. Un push malheureux est appliqué en secondes, avec suppression. | `bootstrap/app-of-apps.yaml`, absence de `.github/` | CI obligatoire (§5.2) + `AppProject` restrictifs + envisager GitHub Pro (4 $/mois) pour la branch protection. |
| **I10** | **Stockage `local-path` partout**, PV épinglés au nœud, aucun `nodeSelector`/affinity déclaré. Perte d'un worker = Gitea, Harbor, NetBox, Postgres, Vault non replanifiables. Le tout sur un disque VM de 60 Go. | aucun `storageClass`/affinity dans les values | Assumer explicitement (mono-box, pas de HA possible) **et** épingler volontairement les workloads stateful + surveiller le remplissage. Sinon : Longhorn (coûteux à 3 nœuds sur une seule machine physique — probablement pas le bon choix ici). |
| **I11** | **Harbor : projet public + exposition publique.** Le projet `aetheriscloud` a été rendu public au motif que « le vrai périmètre est le réseau (WG/cluster) ». Depuis le passage derrière Traefik, Harbor est joignable d'Internet : pull et énumération anonymes possibles. La justification est caduque. | workflow Phase 6.2 + `platform/harbor/application.yaml` | Repasser le projet en privé + `imagePullSecrets`, ou restreindre Harbor au réseau interne. |
| **I12** | **Ansible non rejouable en l'état.** 4 variables obligatoires ne sont définies ni documentées nulle part : `gandi_api_token`, `keycloak_admin_password`, `keycloak_db_password`, `teleport_join_token` (+ `k3s_token` à `""`). Pas d'`ansible-vault`, pas de README. Aucun `no_log: true` sur les tâches qui les manipulent. | `comm` entre variables utilisées et définies | `ansible-vault` ou SOPS + `README` listant les variables requises + `no_log: true`. |
| **I13** | **L'hôte PVE est 100 % manuel.** Le composant le plus critique (unique point d'entrée, firewall, HAProxy, WireGuard, NAT, node_exporter) n'a aucun code. Les rôles `haproxy` et `wireguard` prévus au plan n'ont jamais été écrits ; le seul « IaC » de cette couche, ce sont des blocs de code dans un `.md`. | `ansible/roles/` : 6 rôles, aucun pour l'hôte | Rôles `base-pve`, `firewall`, `wireguard`, `haproxy`. C'est le prérequis d'un DR réel. |

### M — Mineures

| ID | Écart | Remédiation |
|---|---|---|
| **M14** | **Aucune probe** `liveness`/`readiness` sur aucun déploiement maison. Le portail expose `/healthz` qui n'est utilisé nulle part. | Ajouter les probes ; rolling update aveugle sinon. |
| **M15** | **`whoami` de test toujours en production** et publiquement joignable ; il renvoie tous les headers et l'IP du pod. | Supprimer `platform/traefik/whoami-test.yaml` après validation. |
| **M16** | **Portail — `python-jose==3.3.0`** : CVE-2024-33663 (confusion d'algorithme), CVE-2024-33664 (DoS). Flow OIDC sans `nonce` ni PKCE. Groupes figés dans la session : révoquer un groupe Keycloak reste sans effet jusqu'à expiration (14 j par défaut de `SessionMiddleware`). | `authlib` ou `pyjwt` ≥ à jour ; ajouter `nonce` + PKCE ; `max_age` de session court + rafraîchissement des claims. |
| **M17** | **Builds non reproductibles** : pas de lockfile npm committé (`npm install`, pas `npm ci`), images de base flottantes, 3 images maison buildées à la main via podman sur `k3s-w1`. Aucun scan avant push. | Pipeline de build (GitHub Actions ou Gitea Actions) + `npm ci` + digests épinglés + scan Trivy. |
| **M18** | **Gitea n'a plus de rôle clair** depuis que Harbor a repris le registre, et il est derrière Teleport `app_service` → `git clone`/`push` en CLI impossibles (session navigateur requise). C'est un Postgres + un pod de plus à sauvegarder. | Décision à trancher (§4.0) : lui donner un accès CLI réel, ou le retirer. |
| **M19** | `bootstrap/values.yaml` : `global.domain: localhost:8080` résiduel, incohérent avec `configs.cm.url`. ArgoCD étant hors GitOps, ce fichier peut avoir divergé du cluster réel. | Corrigé de fait par `C3` (ArgoCD self-managed). |
| **M20** | **Pas de README à la racine**, pas de LICENSE. Un repo d'infra sans point d'entrée. | `README.md` : architecture en 10 lignes, prérequis, ordre de déploiement, variables requises. |

---

## 4. Plan de reconstruction

### 4.0 Décisions à trancher **avant** d'écrire une ligne

Ces quatre points changent la structure du reste. À arbitrer en premier :

| Décision | Options | Recommandation |
|---|---|---|
| **Vault** (`C5`) | (a) retirer, SOPS seul — (b) garder avec auto-unseal + backup | **(a)**. SOPS/age couvre les secrets GitOps, Keycloak couvre l'identité, Teleport couvre l'accès. Vault en standalone `file` mono-opérateur ajoute une dépendance fragile pour un bénéfice nul aujourd'hui. À réintroduire le jour où il y a un vrai besoin (secrets dynamiques, PKI interne, secrets applicatifs par tenant). |
| **Gitea** (`M18`) | (a) retirer — (b) garder avec accès CLI direct (NodePort/ingress hors Teleport) | **(a) si le repo reste sur GitHub**. Le doublon Git n'a de sens que pour lever la dépendance à GitHub — or le bootstrap ArgoCD reste sur GitHub par choix explicite. Un composant stateful de moins à sauvegarder. |
| **Registre d'images** (`C4`, `I11`) | (a) Harbor privé + `imagePullSecrets` — (b) ghcr.io pour tout — (c) ghcr.io pour le bootstrap + Harbor privé pour le reste | **(c)**. Casse la circularité sans perdre Harbor (scan Trivy, quotas par projet, replication) qui reste utile pour le multi-tenant. |
| **RAID** (`C2`) | (a) réinstaller en ZFS mirror — (b) rester mono-disque + backups | **(a)**. Reconstruction = la seule fenêtre où c'est gratuit. 2×250 Go en mirror = 250 Go utiles, largement suffisant vu le remplissage actuel. |

### 4.1 Lot 1 — Survie (à faire avant tout le reste)

Objectif : que la perte d'un disque ou d'une VM soit un incident, pas une fin.

- Réinstallation Proxmox en **ZFS mirror** sur les 2 SSD.
- Rôles Ansible `base-pve`, `firewall`, `wireguard`, `haproxy` — l'hôte entièrement en code (`I13`).
- PBS (homelab via WG) en storage PVE, job quotidien VM+CT, rétention 7 j / 4 sem.
- Timers systemd : `pg_dump` Keycloak, `sqlite3 .backup` du `state.db` k3s.
- Copie hors-site : clé age, token Gandi, export du realm Keycloak.
- **Restore réellement testé** : un CT restauré sur le homelab, un fichier extrait d'un backup VM, un dump Keycloak réimporté sur une instance jetable.

**Critères d'acceptation** : `terraform destroy` d'une VM puis reconstruction complète par `terraform apply` + `ansible-playbook` sans intervention manuelle · un restore PBS réussi et horodaté dans le runbook · `zpool status` = mirror ONLINE.

### 4.2 Lot 2 — Socle GitOps reproductible

Objectif : le repo suffit à reconstruire le cluster.

- SOPS opérationnel : tous les secrets chiffrés dans Git, plus aucun `kubectl create secret` dans le runbook (`C3`).
- ArgoCD **self-managed** (`Application` argocd → `kubernetes/platform/argocd/`).
- `AppProject` `platform` et `tenants` avec `sourceRepos`, `destinations` et `clusterResourceWhitelist` restreints (`I9`).
- Images de bootstrap (webhook Gandi, portail, docs) sur `ghcr.io` (`C4`).
- Ordre de bootstrap documenté et **testé sur cluster vierge**, CRD comprises (le problème `helm template` vs `crds/` est connu, cf. workflow actuel).

**Critères d'acceptation** : depuis un k3s neuf, `kubectl apply -f bootstrap/` + la clé age → cluster complet `Healthy/Synced` sans aucune commande manuelle intermédiaire.

### 4.3 Lot 3 — Observabilité réelle

- `storageSpec` Prometheus + persistance Grafana (`I7`).
- Route Alertmanager fonctionnelle (mail ou ntfy) + **alerte de test reçue**.
- Alertes minimales : `zpool degraded`, disque > 80 %, certificat < 15 j, échec de backup PBS, `node NotReady`, quota tenant > 90 %, `Prometheus target down`.
- Netpol autorisant le scrape des tenants (`I8`).

**Critères d'acceptation** : couper volontairement `node_exporter` sur un nœud → alerte reçue sur le canal réel en moins de 5 min.

### 4.4 Lot 4 — Durcissement

- NetworkPolicy default-deny sur tous les namespaces plateforme (`I6`).
- Harbor en projet privé + `imagePullSecrets` (`I11`).
- `ansible-vault`/SOPS + `no_log` + README des variables (`I12`).
- Suppression de `whoami` (`M15`), probes partout (`M14`), portail à jour (`M16`).
- `kube-bench` one-shot, `nmap -Pn -p-` externe, revue des RoleBindings.

**Critères d'acceptation** : `nmap` externe ne montre que 443/tcp · un pod de test dans `docs-public` ne joint ni 10.42.0.1, ni 10.42.0.6, ni l'apiserver.

### 4.5 Lot 5 — Industrialisation

- CI sur PR (§5.2).
- Renovate pour les bumps de charts et d'images.
- Pipeline de build des images maison avec scan (`M17`).
- Inventaire Ansible dynamique depuis NetBox (Phase 10.4 jamais faite).
- README racine (`M20`).

### 4.6 Lot 6 — Fonctionnel

Seulement maintenant : portail client (tickets, self-service namespace), catalogue d'apps, onboarding d'un vrai client.

---

## 5. Règles d'ingénierie à imposer au nouveau repo

### 5.1 Definition of done (par composant)

Un composant n'est « fait » que si les 7 points sont vrais :

1. Déclaré en Git, déployé par ArgoCD (ou Ansible pour la couche système), **jamais à la main**.
2. Ses secrets sont chiffrés dans Git, pas créés hors bande.
3. Il a des `requests`/`limits`, des probes, et une persistance explicite (ou l'absence de persistance est un choix écrit).
4. Il est couvert par une NetworkPolicy.
5. Ses données sont dans le périmètre de backup, et le restore a été testé au moins une fois.
6. Il a au moins une alerte qui se déclenche quand il tombe.
7. Sa raison d'être tient en une ligne dans le README. Si ce n'est pas le cas, il ne doit pas exister (cf. Vault et Gitea).

### 5.2 CI minimale (bloquante sur PR)

```yaml
# .github/workflows/validate.yml — squelette
jobs:
  validate:
    steps:
      - terraform fmt -check && terraform validate
      - ansible-lint
      - helm template <chaque chart> | kubeconform -strict -summary
      - gitleaks detect --no-git -v
      - sops --decrypt --extract '' <un secret> > /dev/null   # la clé age de CI valide le déchiffrement
```

Rationale : aujourd'hui `prune: true` + `selfHeal: true` + zéro validation, c'est le combo qui fait disparaître un namespace client un dimanche soir.

### 5.3 Conventions à conserver

- Namespaces : un par composant plateforme, préfixe `cust-` pour les clients, label `aetheriscloud.fr/tier` = `platform` / `internal` / `tenant`.
- PSA : `restricted` par défaut, `baseline` pour la plateforme, `privileged` uniquement pour `traefik` (hostPort). Toute exception est justifiée en commentaire.
- RBAC tenant : `ClusterRole edit` lié au groupe Keycloak `oidc:client-<nom>`. **Jamais `admin`, jamais `cluster-admin`.**
- Versions de charts et d'images **épinglées** (déjà le cas — à maintenir), bumps par PR Renovate.

### 5.4 Pièges déjà rencontrés — à ne pas redécouvrir

À reporter tels quels dans le nouveau repo, ils coûtent chacun plusieurs heures :

| Piège | Détail |
|---|---|
| CIDR pods k3s | Le défaut `10.42.0.0/16` englobe le réseau physique 10.42.0.0/24 → flannel écrase la route entre nœuds. Forcer `cluster-cidr: 10.44.0.0/16`. |
| SNI Teleport | Le client gRPC de `tsh` utilise `<hex(cluster)>.teleport.cluster.local` → règle HAProxy `req_ssl_sni -m end -i .teleport.cluster.local` obligatoire. |
| Teleport v3 | `version: v3` seul n'active pas le TLS routing : il faut `proxy_listener_mode: multiplex` **et** `web_listen_addr: 0.0.0.0:443`. |
| PROXY protocol | En passthrough TCP, toute source apparaît comme 10.42.0.1 → tout `allow/deny` par IP est inopérant sans `send-proxy-v2` + `set_real_ip_from`/`trustedIPs`. Vaut pour nginx **et** Traefik. |
| `helm template` vs `crds/` | ArgoCD utilise `helm template`, qui ignore le dossier `crds/`. CRD à poser en amont (`--server-side` pour Prometheus : > 262144 octets). |
| Fonction Helm `lookup` | Ne fonctionne que sous `install`/`upgrade`, jamais sous `template` → tout mécanisme de chart « réutilise le mot de passe existant » régénère un mot de passe à chaque sync ArgoCD. Toujours `existingSecret`. |
| kube-router (netpol k3s) | N'unit pas correctement plusieurs objets `NetworkPolicy` ciblant les mêmes pods. Une seule policy consolidée par cible. |
| Traefik + hostPort | Avec 2 workers et `hostPort: 443`, le `maxSurge: 1` par défaut bloque le rolling update. `maxSurge: 0` / `maxUnavailable: 1`. |
| Traefik chart | La clé est `service.spec.type`, pas `service.type`. |
| LXC non privilégiés | Pas de `CAP_SYS_TIME` (chrony inutile) ; `resolv.conf` pointe vers un stub systemd-resolved inactif → toute résolution DNS échoue. Fixer `initialization.dns.servers` côté Terraform. |
| lego 5.x | Flags **après** la sous-commande, `--accept-tos` obligatoire (sinon prompt bloquant silencieux), variable `GANDIV5_PERSONAL_ACCESS_TOKEN`. |
| PAT Gandi | `Authorization: Bearer`, pas `Apikey` (le fork 2021 du webhook utilise `Apikey` → 403 sur tout). |
| Firewall PVE natif | Ajoute automatiquement le `/24` public en ipset trusted sur SSH/8006. Incompatible avec un modèle « WG only » → iptables manuel. |
| Wildcard + apex ACME | `*.apps` et `apps` partagent le même `_acme-challenge.apps` ; le webhook Gandi (une valeur par rrset) fait échouer les deux. |

---

## 6. Prompt de démarrage suggéré pour Claude Code

```
Contexte : docs/audit-et-cahier-des-charges.md (lis-le en entier avant de commencer).
On reconstruit l'infra décrite en §1 en corrigeant les écarts du §3.

Contraintes non négociables :
- §2 (invariants) et §5.1 (definition of done) s'appliquent à chaque composant.
- On travaille lot par lot (§4). Un lot = une PR. Pas de lot N+1 avant validation
  des critères d'acceptation du lot N sur la machine réelle.
- Aucun secret créé hors Git. Si une étape l'exige, c'est un défaut de conception :
  signale-le au lieu de le contourner.
- Chaque déviation par rapport à ce document est tracée avec sa cause racine dans
  docs/journal.md, au format du workflow actuel.

Commence par le §4.0 : présente-moi les 4 décisions à trancher avec ton analyse,
et attends mon arbitrage avant d'écrire quoi que ce soit.
```

---

## Annexe — récapitulatif des écarts

| ID | Sévérité | Résumé | Lot |
|---|---|---|---|
| C1 | Critique | Repo public | immédiat |
| C2 | Critique | Aucun backup, aucune redondance disque | 1 |
| C3 | Critique | GitOps non reproductible (secrets hors Git) | 2 |
| C4 | Critique | Dépendance circulaire cert-manager ↔ Harbor | 2 |
| C5 | Critique | Vault fragile (unseal manuel, clés non sauvegardées) | 4.0 |
| I6 | Important | Aucune netpol sur la plateforme | 4 |
| I7 | Important | Monitoring sans persistance ni alerting | 3 |
| I8 | Important | Prometheus ne peut pas scraper les tenants | 3 |
| I9 | Important | Aucun garde-fou sur `main` (CI, AppProject, branch protection) | 2 / 5 |
| I10 | Important | `local-path` : PV épinglés, pas de replanification | 4.0 |
| I11 | Important | Harbor public et exposé publiquement | 4 |
| I12 | Important | Ansible non rejouable (4 variables non documentées) | 4 |
| I13 | Important | Hôte PVE 100 % manuel | 1 |
| M14 | Mineur | Aucune probe | 4 |
| M15 | Mineur | `whoami` de test en production | 4 |
| M16 | Mineur | `python-jose` vulnérable, OIDC sans nonce/PKCE | 4 |
| M17 | Mineur | Builds non reproductibles | 5 |
| M18 | Mineur | Gitea sans rôle clair, inutilisable en CLI | 4.0 |
| M19 | Mineur | `bootstrap/values.yaml` résiduel | 2 |
| M20 | Mineur | Pas de README ni LICENSE | 5 |
