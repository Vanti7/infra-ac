# Workflow d'exécution — Déploiement Dedibox `aetheriscloud`

> Runbook dérivé de [`plan-deploiement-dedibox.md`](./plan-deploiement-dedibox.md). Une checklist par phase, dans l'ordre. Ne pas cocher une étape tant que sa **validation** n'est pas vérifiée — c'est elle qui garantit que la phase suivante part sur une base saine.

**Légende** : `[ ]` à faire · `⚠` point de non-retour / prudence · `✅` critère de validation de la phase

---

## Phase 0 — Préparation

- [ ] Créer le repo GitHub privé `infra-dedibox`, activer branch protection sur `main`
- [ ] Générer la clé age (`age-keygen -o ~/.config/sops/age/keys.txt`) — ⚠ ne jamais commiter, copie offline + coffre
- [ ] Créer `.sops.yaml` avec la clé publique age
- [ ] DNS Gandi : créer `teleport`, `sso`, `kube` (A → IP dedibox) et `*.apps` (A → IP dedibox)
- [ ] Générer un Personal Access Token Gandi limité au domaine (cert-manager + lego)
- [ ] Poste d'admin : installer `terraform`, `ansible`, `kubectl`, `kubectl-oidc_login` (krew), `tsh`, `sops`, `age`, `helm`
- [ ] Vérifier l'accès à la console Dedibox (mode rescue / KVM) comme filet de sécurité

**✅ Validation** : `dig +short sso.aetheriscloud.fr` renvoie l'IP · repo clonable · `sops -e` chiffre un fichier test

---

## Phase 1 — Socle Proxmox, réseau, entrée unique

### 1.1 Installation
- [ ] Installer Proxmox VE 9 via console Dedibox, 2 SSD en miroir ZFS
- [ ] Capper l'ARC ZFS à 3 Go (`/etc/modprobe.d/zfs.conf`), `update-initramfs -u && reboot`
- [ ] Basculer sur le repo no-subscription, appliquer les mises à jour

### 1.2 Réseau interne NATé
- [ ] Configurer `vmbr1` (10.42.0.1/24) dans `/etc/network/interfaces`
- [ ] Activer `ip_forward` + règles MASQUERADE NAT

### 1.3 WireGuard
- [ ] `apt install wireguard`
- [ ] Configurer `wg0.conf` (10.99.0.1/24, port 51820, peer pfSense)
- [ ] Côté pfSense : peer symétrique + `PersistentKeepalive = 25` + règles restreignant l'accès au seul poste d'admin

### 1.4 Firewall
- [ ] Politique DROP par défaut sur le PVE firewall
- [ ] Autoriser uniquement : tcp/443 (any), udp/51820 (any), tcp/22+8006 (depuis 10.99.0.0/24), tcp+udp/53 (depuis 10.42.0.0/24 si résolveur local)
- [ ] SSHd : `PasswordAuthentication no`, clé uniquement

### 1.5 HAProxy (routage SNI)
- [ ] `apt install haproxy`
- [ ] Configurer `frontend fe443` (inspect SNI, passthrough TCP) + backends `bk_teleport`/`bk_sso`/`bk_kubeapi`/`bk_ingress`
- [ ] ⚠ Tester la bascule firewall/HAProxy **avant** de couper l'accès direct — garder la console KVM ouverte pendant ce test

**✅ Validation** : `nmap -Pn <IP>` depuis l'extérieur ne montre que 443 · UI PVE joignable uniquement via WG · `wg show` montre le handshake pfSense

---

## Phase 2 — Provisioning IaC

### 2.1 Accès API Proxmox pour Terraform
- [ ] Créer `terraform@pve`, rôle `PVEAdmin` (à restreindre ensuite)
- [ ] Générer le token API (`--privsep=0`) → stocké en variable d'env, jamais en clair dans le repo

### 2.2 Terraform (provider `bpg/proxmox`)
- [ ] Importer l'image Debian 13 genericcloud en template cloud-init
- [ ] Déclarer les 3 VMs (10.42.0.11/.21/.22) et 2 LXC (10.42.0.5/.6) dans `terraform/`
- [ ] Configurer cloud-init (clé SSH, user `admin`, pas de mot de passe)
- [ ] `terraform init && terraform plan && terraform apply`

### 2.3 Ansible — socle commun
- [ ] Écrire `inventory.yml` (groupes `k3s_server`, `k3s_agents`, `teleport`, `iam`)
- [ ] Rôle `base` : hardening sshd, unattended-upgrades, chrony, node_exporter, outils de base

**✅ Validation** : `terraform apply` idempotent (0 changement au 2e run) · `ansible all -m ping` OK · les 5 machines sortent sur Internet via le NAT

---

## Phase 3 — IAM : Keycloak

### 3.1 Socle
- [ ] Installer PostgreSQL + base/user `keycloak` sur le CT `iam`
- [ ] Installer Keycloak (`/opt/keycloak`, OpenJDK 21, unité systemd, `kc.sh build --db=postgres`)
- [ ] Certificat `sso.aetheriscloud.fr` via lego (DNS-01 Gandi) + timer de renouvellement
- [ ] nginx en frontal : TLS + proxy loopback, verrouillage `/admin` et `/realms/master` au réseau interne/WG

### 3.2 Realm `infra`
- [ ] Créer le realm `infra` (ne jamais exposer `master`)
- [ ] Activer brute force detection + MFA obligatoire (WebAuthn/TOTP)
- [ ] Créer les groupes `infra-admins` et `client-<nom>`
- [ ] Client `kubernetes` : public, PKCE S256, redirects kubelogin
- [ ] Client `argocd` : confidentiel, redirect ArgoCD
- [ ] Mapper claim `groups` (full path OFF) sur les deux clients
- [ ] Créer l'utilisateur `vanti` dans `infra-admins`, enrôler MFA

**✅ Validation** : `.well-known/openid-configuration` accessible depuis l'extérieur · `/admin` → 403 depuis l'extérieur, OK via WG · login MFA fonctionnel

---

## Phase 4 — Bastion Teleport

- [ ] Installer Teleport Community sur le CT `teleport`, config v3 (`/etc/teleport.yaml`)
- [ ] Activer `auth_service` (local, webauthn), `proxy_service` (ACME TLS-ALPN-01), `ssh_service`
- [ ] `tctl users add vanti --roles=editor,access --logins=admin,root`
- [ ] Générer un jeton d'enrôlement (`tctl tokens add --type=node --ttl=1h`)
- [ ] Déployer `ssh_service` via Ansible sur les 5 machines internes (PVE reste hors Teleport)
- [ ] Optionnel : `app_service` pour publier UI PVE / ArgoCD derrière l'auth Teleport

**✅ Validation** : `tsh login --proxy=teleport.aetheriscloud.fr` (WebAuthn) · `tsh ssh admin@k3s-w1` · session visible dans l'UI

---

## Phase 5 — Cluster k3s

- [ ] Rôle Ansible `k3s-server` : version pinnée, `disable: [traefik, servicelb]`, taint control-plane, `tls-san`, `secrets-encryption: true`, flags OIDC apiserver
- [ ] Rôle Ansible `k3s-agent` sur w1/w2 (server + token)
- [ ] Récupérer le kubeconfig admin via WG (`server: https://10.42.0.11:6443`)

**✅ Validation** : `kubectl get nodes` → 3 Ready · taint présent sur `k3s-server` · `kubectl get --raw /readyz` → ok

---

## Phase 6 — GitOps et plateforme

### 6.1 Bootstrap ArgoCD
- [ ] `helm install argocd argo/argo-cd -n argocd --create-namespace -f kubernetes/bootstrap/values.yaml`
- [ ] Pas de Service exposé publiquement, SSO OIDC → Keycloak (client `argocd`)
- [ ] RBAC : `infra-admins` → `role:admin`, défaut `role:readonly`
- [ ] Connecter le repo GitHub (deploy key lecture seule) + app-of-apps → `kubernetes/platform/`

### 6.2 Apps plateforme (via ArgoCD)
- [ ] traefik (2 replicas, `hostPort: 443`, ingressClass par défaut)
- [ ] cert-manager + webhook Gandi (ClusterIssuer DNS-01, wildcard `*.apps`)
- [ ] kube-prometheus-stack (rétention 10j, scrape node_exporter hôte/CT, Alertmanager → mail/ntfy)
- [ ] teleport-kube-agent (jeton `--type=kube`)
- [ ] sops-secrets/helm-secrets (clé age privée créée à la main dans le cluster, hors Git)
- [ ] netbox (déploiement complet en Phase 10)

### 6.3 Namespaces
- [ ] Appliquer la convention de nommage/labels (`aetheris-`, `cust-`, `aetheriscloud.fr/tier`)
- [ ] Vérifier les PSA par namespace (platform/internal/tenant)

**✅ Validation** : toutes les apps ArgoCD `Healthy/Synced` · `whoami` de test accessible en TLS wildcard valide · alerte test Alertmanager reçue · `tsh kube login dedibox` fonctionne

---

## Phase 7 — Multi-tenancy et onboarding client

### 7.1 Chart `onboarding-client`
- [ ] Template namespace `cust-<nom>` avec labels PSA `restricted`
- [ ] Template RoleBinding groupe Keycloak → ClusterRole `edit` (jamais admin/cluster-admin)
- [ ] Template ResourceQuota (cpu/mémoire/pods/PVC/storage)
- [ ] Template LimitRange (defaults + max par conteneur)
- [ ] Template NetworkPolicies (default-deny + allow intra-ns + DNS + ingress Traefik)

### 7.2 Onboarding d'un client test (`cust-test`)
- [ ] Créer groupe `client-test` + user(s) MFA dans Keycloak
- [ ] Créer `kubernetes/tenants/test.values.yaml` → PR → merge → sync ArgoCD
- [ ] Livrer le kubeconfig type (exec plugin oidc-login)

**✅ Validation** : `kubectl auth can-i --list -n cust-test` montre `edit` · `kubectl get ns` interdit · `kubectl get pods -n kube-system` interdit · quota/LimitRange déclenchés correctement · netpol isole le namespace · pod privilégié rejeté par PSA

> 📌 Rappel : au-delà de 2-3 clients, évaluer la bascule vers **Capsule**.

---

## Phase 8 — Backups & DR

- [ ] Ajouter PBS homelab comme storage PVE (via WG), job quotidien VMs+CT (snapshot + qemu-guest-agent), rétention 7j/4sem
- [ ] Timer systemd `pg_dump` Keycloak
- [ ] Timer systemd backup SQLite `k3s-state.db`
- [ ] Copier hors-site : clé age, token Gandi, export realm Keycloak (coffre + copie offline)
- [ ] Rédiger le runbook DR détaillé (ordre de reconstruction)
- [ ] ⚠ **Tester réellement** le DR — pas seulement le documenter

**✅ Validation** : restore réel d'un CT sur le homelab (test trimestriel) · restore d'un fichier depuis backup VM · dump Keycloak réimporté sur instance jetable

---

## Phase 9 — Durcissement final & exploitation (continu)

Tâches récurrentes à planifier (pas un one-shot) :

- [ ] Scan externe `nmap -Pn -p- <IP>` après chaque changement HAProxy/FW
- [ ] Revue mensuelle : RoleBindings (`kubectl-who-can`/`rakkess`), users Keycloak, sessions Teleport
- [ ] `kube-bench` one-shot après l'install initiale
- [ ] Planifier MàJ PVE mensuelles (fenêtre annoncée), k3s mineure après test, Renovate sur le repo
- [ ] Politique de rotation : token Terraform PVE, jetons Teleport (TTL courts), purge secrets au départ d'un client
- [ ] Configurer les alertes minimales (zpool degraded, disque >80%, cert <15j, backup PBS en échec, quota tenant >90%, node NotReady)

---

## Phase 10 — CMDB NetBox

### 10.1 Préalable : PROXY protocol
- [ ] Activer `send-proxy-v2` sur `bk_ingress` (HAProxy)
- [ ] Configurer `proxyProtocol.trustedIPs` côté Traefik

### 10.2 Déploiement
- [ ] Déployer le chart NetBox (PG+Redis inclus), PV local-path, ressources cappées
- [ ] Ingress `netbox.aetheriscloud.fr` sans DNS public + `ipAllowList` (10.99.0.0/24, 10.42.0.0/24) + SSO OIDC Keycloak

### 10.3 Modélisation
- [ ] Créer les prefixes (10.42.0.0/24, 10.99.0.0/24, IP publique)
- [ ] Créer l'hôte + les 5 VM/CT avec IP primaires, cluster « dedibox »
- [ ] Créer les tenants NetBox (`interne` + un par client), custom field `namespace`, tag `managed-by:ansible`
- [ ] Créer les services (sso/443, teleport/443, kube/6443, apps/443)

### 10.4 Automatisation
- [ ] Basculer l'inventaire Ansible en dynamique (plugin `netbox.netbox.nb_inventory`), supprimer l'inventaire statique
- [ ] Créer le job CI `sync-netbox` (GitHub Action, déclenché sur merge `tenants/`)
- [ ] Rôle Ansible `dns-interne` générant unbound/hosts depuis NetBox

**✅ Validation** : `ansible-inventory --list` reflète NetBox · retrait d'une machine → disparaît de l'inventaire · playbook `base` rejoué sans diff · fiche tenant complète en un écran

---

## Phase 11 — Portail client (itératif)

### Sécurité (prérequis non négociable avant M1)
- [ ] Créer le client OIDC `portal` (confidentiel) dans le realm `infra`
- [ ] Provisionner uniquement les secrets nécessaires : token GitHub fine-grained (repo `infra-dedibox`, contenu), token NetBox scoping objet, SMTP/ntfy — ⚠ aucun kubeconfig
- [ ] Déployer le portail comme un tenant (`namespace: portal`, quota, netpol, PSA restricted)
- [ ] Rate limiting Traefik sur `/api`

### M1 — Vitrine
- [ ] Auth OIDC + `GET /me`
- [ ] Lecture NetBox (`GET /namespaces`)

### M2 — Tickets
- [ ] CRUD tickets + notifications mail/ntfy

### M3 — Self-service namespace (merge manuel)
- [ ] `POST /namespaces` génère le values file + ouvre la PR
- [ ] CI sur la PR : `helm template` + `kubeconform`

### M4 — Auto-merge & catalogue
- [ ] Auto-merge si CI verte (après période de confiance)
- [ ] Petit catalogue d'apps (values Helm générés)

**✅ Validation** : parcours client complet — login portail → ticket → demande namespace → merge → `Synced` ArgoCD → visible NetBox+portail → kubectl OIDC fonctionnel

---

## Checklist de mise en service — par nouveau client

À rejouer intégralement à chaque onboarding (cf. Phase 7.2) :

- [ ] Groupe + user(s) Keycloak, MFA enrôlée
- [ ] Values file mergé, app ArgoCD `Synced`
- [ ] `kubectl auth can-i --list` vérifié avec un token du client
- [ ] Quota/LimitRange/netpol/PSA testés
- [ ] Kubeconfig + doc kubelogin livrés
- [ ] Contact + fenêtre de maintenance communiqués

---

## Dépendances entre phases

```
Phase 0 (préparation)
   └─► Phase 1 (réseau/FW/HAProxy)  ⚠ point de non-retour réseau
        └─► Phase 2 (Terraform+Ansible socle)
             ├─► Phase 3 (Keycloak)
             ├─► Phase 4 (Teleport)
             └─► Phase 5 (k3s) ──requiert Keycloak pour l'OIDC apiserver
                  └─► Phase 6 (ArgoCD + plateforme) ──requiert Keycloak pour SSO ArgoCD
                       └─► Phase 7 (onboarding client)
                       └─► Phase 10 (NetBox) ──requiert Phase 6 (cluster + Traefik)
                            └─► Phase 11 (portail) ──requiert NetBox + Keycloak + repo tenants/
Phase 8 (backups/DR) ──parallélisable dès que Phase 2 est stable
Phase 9 (durcissement) ──continu, démarre après Phase 6
```
