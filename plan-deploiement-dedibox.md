# Plan de déploiement — Infra Dedibox `aetheriscloud`

**Cible** : Dedibox Start-2-L (Xeon D-1531 6C/12T, 32 Go, 2×250 Go SSD) hébergeant une plateforme k3s multi-tenant (namespaces clients), un bastion Teleport et un IdP Keycloak, sous Proxmox VE 9.

**Principes** : un seul port exposé (443, routage SNI), management uniquement via WireGuard, infra autonome vis-à-vis du homelab, tout en IaC/GitOps, secrets chiffrés au repos.

## Décisions actées

| Sujet | Choix | Raison |
|---|---|---|
| Hyperviseur | Proxmox VE 9 (image Scaleway), ZFS mirror | Standard maîtrisé, snapshots, PBS |
| Kubernetes | k3s — 1 server (tainté) + 2 agents | Multi-nœuds léger, netpol intégrées |
| IdP | Keycloak seul (pas d'annuaire) | Surface minimale ; fédération LDAP ajoutable plus tard |
| Bastion | Teleport Community, users locaux + WebAuthn | OIDC/SAML = Enterprise ; SSO Keycloak réservé à l'API k8s et aux apps |
| Accès clients | OIDC apiserver + kubelogin, RBAC par groupes Keycloak | Kubernetes vanilla, gratuit, granulaire |
| GitOps | ArgoCD local + repo GitHub privé + SOPS/age | Zéro dépendance homelab, blast radius séparé |
| Monitoring | kube-prometheus-stack (scrape aussi hôte/CT) | Natif k8s, alertes par tenant |
| Certificats | cert-manager + DNS-01 Gandi (wildcard `*.apps`) | Multi-replica propre ; Teleport gère son ACME, Keycloak via lego |
| Backups | PBS homelab via WireGuard + dumps applicatifs | DR complet single-box |
| CMDB | NetBox (app plateforme, non exposée) | Tenants natifs = clients, API-first, inventaire Ansible dynamique |
| DNS interne | unbound/hosts généré par Ansible depuis NetBox | Suffisant à 6 machines ; évolutif `netbox-dns` + PowerDNS |
| Portail client | Dév maison (OIDC Keycloak, GitOps-driven) | Tickets + self-service namespaces, zéro credential kube |

## Plan d'adressage

| Machine | Type | IP | vCPU / RAM / disque |
|---|---|---|---|
| Hôte PVE | — | IP publique + `vmbr1` 10.42.0.1/24 + `wg0` 10.99.0.1/24 | ~2 Go + ARC 3 Go |
| teleport | LXC | 10.42.0.5 | 2 / 2 Go / 10 Go |
| iam (Keycloak+PG) | LXC | 10.42.0.6 | 2 / 3 Go / 20 Go |
| k3s-server | VM | 10.42.0.11 | 2 / 3 Go / 30 Go |
| k3s-w1 | VM | 10.42.0.21 | 4 / 8 Go / 60 Go |
| k3s-w2 | VM | 10.42.0.22 | 4 / 8 Go / 60 Go |

**DNS publics (Gandi)** → IP de la dedibox : `teleport`, `sso`, `kube`, `*.apps` (.aetheriscloud.fr). Aucun DNS public pour l'admin (PVE, Keycloak admin, ArgoCD) : accès via WireGuard uniquement.

## Arborescence du repo (GitHub privé `infra-dedibox`)

```
infra-dedibox/
├── terraform/            # provider bpg/proxmox : template cloud-init, VMs, LXC
├── ansible/
│   ├── inventory.yml
│   └── roles/            # base, haproxy, wireguard, keycloak, teleport, k3s-server, k3s-agent
├── kubernetes/
│   ├── bootstrap/        # install ArgoCD + app-of-apps
│   ├── platform/         # traefik, cert-manager, monitoring, teleport-kube-agent, netbox
│   └── tenants/          # 1 values file par client (chart onboarding-client)
└── .sops.yaml
```

Le portail client (Phase 11) vit dans son propre repo `client-portal`.

---

# Phase 0 — Préparation (½ journée)

1. Créer le repo GitHub privé, activer branch protection sur `main`.
2. Générer la clé age et configurer SOPS :
   ```bash
   age-keygen -o ~/.config/sops/age/keys.txt   # NE JAMAIS commiter ; copie offline + coffre
   ```
   `.sops.yaml` :
   ```yaml
   creation_rules:
     - path_regex: .*\.secret\.(yaml|env)$
       age: <clé publique age1...>
   ```
3. DNS Gandi : créer `teleport`, `sso`, `kube` (A → IP dedibox) et `*.apps` (A → IP dedibox). Générer un **Personal Access Token Gandi** limité au domaine (pour cert-manager et lego).
4. Poste d'admin : `terraform`, `ansible`, `kubectl`, `kubectl-oidc_login` (krew), `tsh`, `sops`, `age`, `helm`.
5. Garder sous la main la console Dedibox (mode rescue / KVM) : c'est le filet de sécurité si le firewall te sort.

**Validation** : `dig +short sso.aetheriscloud.fr` renvoie l'IP ; repo clonable ; `sops -e` chiffre un fichier test.

---

# Phase 1 — Socle Proxmox, réseau, entrée unique (½ journée)

## 1.1 Installation

- Console Dedibox → Installer → **Proxmox VE 9**, les 2 SSD en **miroir ZFS**.
- Post-install :
  ```bash
  # Cap ARC à 3 Go (sinon ZFS mange la RAM des VMs)
  echo "options zfs zfs_arc_max=3221225472" > /etc/modprobe.d/zfs.conf
  update-initramfs -u && reboot
  # Repo no-subscription + MàJ
  ```

## 1.2 Réseau interne NATé

`/etc/network/interfaces` — ajout :

```
auto vmbr1
iface vmbr1 inet static
    address 10.42.0.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s 10.42.0.0/24 -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s 10.42.0.0/24 -o vmbr0 -j MASQUERADE
```

## 1.3 WireGuard (management + backups)

```bash
apt install wireguard
```

`/etc/wireguard/wg0.conf` :

```
[Interface]
Address    = 10.99.0.1/24
ListenPort = 51820
PrivateKey = <clé hôte>

[Peer]                       # pfSense homelab
PublicKey  = <clé pfSense>
AllowedIPs = 10.99.0.2/32, <LAN homelab>/24
```

Côté pfSense : peer symétrique + `PersistentKeepalive = 25`, règles n'autorisant **que ton poste d'admin** vers 10.99.0.1 et 10.42.0.0/24.

## 1.4 Firewall (PVE firewall, politique DROP)

Règles hôte — tout le reste est refusé :

| Sens | Source | Dest/port | Usage |
|---|---|---|---|
| IN | any | tcp/443 | HAProxy (seule exposition) |
| IN | any | udp/51820 | WireGuard |
| IN | 10.99.0.0/24 | tcp/22, tcp/8006 | SSH + UI PVE via WG uniquement |
| IN | 10.42.0.0/24 | tcp/53, udp/53 (si résolveur local) | VMs |

SSHd : `PasswordAuthentication no`, clé uniquement.

## 1.5 HAProxy — routage SNI passthrough

```bash
apt install haproxy
```

`/etc/haproxy/haproxy.cfg` :

```
global
    log /dev/log local0

defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 5s
    timeout client  1h        # sessions tsh/websocket longues
    timeout server  1h

frontend fe443
    bind :443
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    use_backend bk_teleport if { req_ssl_sni -i teleport.aetheriscloud.fr }
    use_backend bk_sso      if { req_ssl_sni -i sso.aetheriscloud.fr }
    use_backend bk_kubeapi  if { req_ssl_sni -i kube.aetheriscloud.fr }
    default_backend bk_ingress

backend bk_teleport
    server teleport 10.42.0.5:443 check

backend bk_sso
    server iam 10.42.0.6:443 check

backend bk_kubeapi
    server k3s 10.42.0.11:6443 check

backend bk_ingress
    server w1 10.42.0.21:443 check
    server w2 10.42.0.22:443 check
```

Chaque backend termine son propre TLS — HAProxy ne voit jamais de clair.

**Validation** : depuis l'extérieur, `nmap -Pn <IP>` ne montre que 443 ; UI PVE joignable **uniquement** via WG ; `wg show` montre le handshake pfSense.

---

# Phase 2 — Provisioning IaC (1 journée)

## 2.1 Accès API Proxmox pour Terraform

```bash
pveum user add terraform@pve
pveum aclmod / -user terraform@pve -role PVEAdmin      # à restreindre ensuite
pveum user token add terraform@pve iac --privsep=0     # token → variable d'env, jamais en clair dans le repo
```

## 2.2 Template cloud-init + machines (Terraform, provider `bpg/proxmox`)

1. Importer l'image **Debian 13 genericcloud** en template (disque + cloud-init drive).
2. Déclarer dans `terraform/` : 3 VMs (clones du template, IP statiques 10.42.0.11/.21/.22, qemu-guest-agent) et 2 LXC Debian non privilégiés (10.42.0.5/.6).
3. Cloud-init : ta clé SSH, user `admin`, pas de mot de passe.

```bash
terraform init && terraform plan && terraform apply
```

## 2.3 Ansible — socle commun

`inventory.yml` par groupes (`k3s_server`, `k3s_agents`, `teleport`, `iam`). Rôle `base` sur tout le monde : hardening sshd, unattended-upgrades, chrony, node_exporter (bind 10.42.0.x:9100), outils de base.

**Validation** : `terraform apply` idempotent (0 changement au 2e run) ; `ansible all -m ping` OK ; les 5 machines sortent sur Internet via le NAT.

---

# Phase 3 — IAM : Keycloak (½–1 journée)

Dans le CT `iam` (rôle Ansible `keycloak`) :

## 3.1 Socle

- `postgresql` (apt), base + user `keycloak`.
- Keycloak distribution officielle dans `/opt/keycloak` + OpenJDK 21, unité systemd, `kc.sh build` avec `db=postgres`.
- Certificat `sso.aetheriscloud.fr` via **lego** (DNS-01 Gandi) + timer systemd de renouvellement.
- **nginx** en frontal local (termine TLS, proxifie Keycloak en HTTP loopback) avec verrouillage des surfaces d'admin :

```nginx
# admin console + realm master : uniquement WG / réseau interne
location ~ ^/(admin|realms/master) {
    allow 10.99.0.0/24;
    allow 10.42.0.0/24;
    deny  all;
    proxy_pass http://127.0.0.1:8080;
}
location / { proxy_pass http://127.0.0.1:8080; }
```

## 3.2 Configuration du realm `infra`

| Élément | Réglage |
|---|---|
| Realm | `infra` (le realm `master` ne sert qu'au bootstrap, jamais exposé) |
| Sécurité | Brute force detection **ON** ; MFA obligatoire (WebAuthn ou TOTP en required action) |
| Groupes | `infra-admins` (toi), `client-<nom>` (un par client) |
| Client `kubernetes` | **public**, PKCE S256, redirect `http://localhost:8000` et `http://localhost:18000` (kubelogin) |
| Client `argocd` | confidentiel, redirect vers l'URL interne ArgoCD |
| Mapper | claim `groups` (group membership, full path OFF) dans l'ID token des deux clients |
| User | `vanti` ∈ `infra-admins`, MFA enrôlée |

**Validation** : `curl https://sso.aetheriscloud.fr/realms/infra/.well-known/openid-configuration` OK depuis l'extérieur ; `https://sso.../admin` → **403** depuis l'extérieur, OK via WG ; login MFA fonctionnel.

---

# Phase 4 — Bastion Teleport (½ journée)

CT `teleport` (rôle Ansible `teleport`, paquet Community) — `/etc/teleport.yaml` :

```yaml
version: v3
teleport:
  data_dir: /var/lib/teleport
auth_service:
  enabled: true
  cluster_name: dedibox.aetheriscloud.fr
  authentication:
    type: local
    second_factor: webauthn
    webauthn:
      rp_id: teleport.aetheriscloud.fr
proxy_service:
  enabled: true
  public_addr: teleport.aetheriscloud.fr:443
  acme:                       # TLS-ALPN-01 : traverse le passthrough SNI
    enabled: true
    email: admin@aetheriscloud.fr
ssh_service:
  enabled: true
```

Config v3 ⇒ TLS routing par défaut : SSH, kube et web multiplexés sur le seul 443.

```bash
tctl users add vanti --roles=editor,access --logins=admin,root
tctl tokens add --type=node --ttl=1h        # jeton d'enrôlement des agents
```

Agents SSH (via Ansible) sur les 5 machines internes (`ssh_service` + jeton). L'hôte PVE reste hors Teleport : WG only, empreinte minimale sur l'hyperviseur.

Optionnel mais confortable : `app_service` pour publier l'UI PVE et ArgoCD derrière l'auth Teleport au lieu du port-forward WG.

**Validation** : `tsh login --proxy=teleport.aetheriscloud.fr` (WebAuthn) ; `tsh ssh admin@k3s-w1` ; la session apparaît enregistrée dans l'UI.

---

# Phase 5 — Cluster k3s (½ journée)

Rôles Ansible `k3s-server` / `k3s-agent`, **version pinnée** (`INSTALL_K3S_VERSION`, dernière stable testée).

Server — `/etc/rancher/k3s/config.yaml` :

```yaml
disable: [traefik, servicelb]
node-taint: ["node-role.kubernetes.io/control-plane=true:NoSchedule"]
tls-san: [kube.aetheriscloud.fr, 10.42.0.11]
secrets-encryption: true
kube-apiserver-arg:
  - oidc-issuer-url=https://sso.aetheriscloud.fr/realms/infra
  - oidc-client-id=kubernetes
  - oidc-username-claim=preferred_username
  - oidc-username-prefix=oidc:
  - oidc-groups-claim=groups
  - oidc-groups-prefix=oidc:
```

Agents :

```yaml
server: https://10.42.0.11:6443
token: <node-token du server>
```

Kubeconfig admin : récupérer `/etc/rancher/k3s/k3s.yaml` via WG, `server: https://10.42.0.11:6443` (l'admin passe par le WG, jamais par l'entrée publique).

**Validation** : `kubectl get nodes` → 3 Ready ; `kubectl describe node k3s-server | grep Taint` → taint présent ; `kubectl get --raw /readyz` → ok.

---

# Phase 6 — GitOps et plateforme (1 journée)

## 6.1 Bootstrap ArgoCD

```bash
helm install argocd argo/argo-cd -n argocd --create-namespace -f kubernetes/bootstrap/values.yaml
```

Values clés : pas de Service exposé publiquement (UI via WG/port-forward ou Teleport app access), **SSO OIDC → Keycloak** (client `argocd`), RBAC :

```yaml
server.rbacConfig:
  policy.csv: |
    g, oidc:infra-admins, role:admin
  policy.default: role:readonly
```

Connecter le repo GitHub (deploy key lecture seule) + **app-of-apps** pointant `kubernetes/platform/`.

## 6.2 Apps plateforme (tout déclaré dans le repo, déployé par ArgoCD)

| App | Rôle | Points de config |
|---|---|---|
| traefik | Ingress | Deployment 2 replicas sur les workers, `hostPort: 443`, ingressClass par défaut |
| cert-manager (+ webhook Gandi) | Certificats | ClusterIssuer DNS-01, **wildcard `*.apps.aetheriscloud.fr`** en default cert Traefik |
| kube-prometheus-stack | Monitoring | Rétention 10 j, ressources cappées, scrape statique des node_exporter hôte/CT (10.42.0.1/.5/.6), Alertmanager → mail/ntfy |
| teleport-kube-agent | Accès kube admin | Helm chart, jeton `--type=kube`, → `tsh kube login` pour toi |
| sops-secrets / helm-secrets | Secrets GitOps | La clé age privée n'existe que comme Secret dans le cluster (créée à la main, hors Git) |
| netbox | CMDB | Chart communautaire (PG + Redis inclus), non exposé publiquement — déploiement et modélisation en Phase 10 |

## 6.3 Organisation des namespaces

Convention : un namespace par composant plateforme, préfixe `aetheris-` pour l'interne, `cust-` pour les clients, et un label commun `aetheriscloud.fr/tier` consommé par les netpol, le RBAC et les requêtes Prometheus.

| Namespace | Contenu | Tier | PSA |
|---|---|---|---|
| kube-system | composants k3s (coredns, metrics-server, réseau) | platform | géré par k3s |
| traefik | ingress | platform | privileged (hostPort) |
| argocd / cert-manager / netbox / teleport-agent | un namespace par composant | platform | baseline |
| monitoring | kube-prometheus-stack | platform | privileged (node-exporter) |
| aetheris-apps | apps internes aetheriscloud | internal | restricted + bundle tenant allégé |
| portal | portail client (tenant isolé, Phase 11) | internal | restricted |
| cust-* | namespaces clients | tenant | restricted |

Pas de namespace fourre-tout type `aetheris-core` : PSA et Secrets sont scopés au namespace — regrouper imposerait `privileged` à tout le monde et rendrait les secrets mutuellement lisibles. Le regroupement se fait par label, pas par namespace.

**Validation** : toutes les apps ArgoCD `Healthy/Synced` ; déployer un `whoami` de test → `https://whoami.apps.aetheriscloud.fr` en TLS wildcard valide ; alerte test Alertmanager reçue ; `tsh kube login dedibox` fonctionne.

---

# Phase 7 — Multi-tenancy et onboarding client (½ journée)

## 7.1 Chart `onboarding-client` (dans `kubernetes/tenants/`)

Un values file par client, générant :

1. **Namespace** `cust-<nom>` avec labels PSA :
   ```yaml
   pod-security.kubernetes.io/enforce: restricted
   pod-security.kubernetes.io/warn: restricted
   ```
2. **RBAC** — le cœur de l'accès granulaire :
   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: client-edit
     namespace: cust-acme
   subjects:
     - kind: Group
       name: "oidc:client-acme"        # groupe Keycloak
       apiGroup: rbac.authorization.k8s.io
   roleRef:
     kind: ClusterRole
     name: edit                         # jamais admin ni cluster-admin
     apiGroup: rbac.authorization.k8s.io
   ```
3. **ResourceQuota** :
   ```yaml
   spec:
     hard:
       requests.cpu: "2"
       requests.memory: 4Gi
       limits.cpu: "3"
       limits.memory: 6Gi
       pods: "30"
       persistentvolumeclaims: "5"
       requests.storage: 20Gi
   ```
4. **LimitRange** (defaults + max par conteneur — sinon la quota bloque les pods sans requests).
5. **NetworkPolicies** : `default-deny` (Ingress+Egress) puis allow intra-namespace, allow DNS vers kube-system, allow Ingress depuis le namespace Traefik. Exemple deny :
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata: { name: default-deny, namespace: cust-acme }
   spec:
     podSelector: {}
     policyTypes: [Ingress, Egress]
   ```

## 7.2 Procédure d'onboarding (par client)

1. Keycloak : groupe `client-<nom>`, user(s) avec MFA en required action.
2. Repo : `kubernetes/tenants/<nom>.values.yaml` → PR → merge → ArgoCD applique.
3. Livrer au client le kubeconfig type :
   ```yaml
   clusters:
     - name: dedibox
       cluster: { server: https://kube.aetheriscloud.fr }
   users:
     - name: oidc
       user:
         exec:
           apiVersion: client.authentication.k8s.io/v1
           command: kubectl
           args: [oidc-login, get-token,
             --oidc-issuer-url=https://sso.aetheriscloud.fr/realms/infra,
             --oidc-client-id=kubernetes,
             --oidc-use-pkce]
   ```

**Validation (client fictif `cust-test`)** : `kubectl auth can-i --list -n cust-test` montre les droits `edit` ; `kubectl get ns` → **interdit** ; `kubectl get pods -n kube-system` → **interdit** ; déploiement sans requests → bloqué par la quota puis corrigé par le LimitRange ; un pod `cust-test` ne joint pas un pod d'un autre namespace (netpol) ; pod privilégié → rejeté par PSA.

Quand le pattern devient répétitif (>2-3 clients) : passer à **Capsule** (CRD `Tenant`, namespaces self-service, quotas/registries imposés par tenant).

---

# Phase 8 — Backups & DR (½ journée)

1. **PBS homelab** ajouté comme storage PVE (via WG) : job quotidien VMs + CT, mode snapshot avec qemu-guest-agent (fsfreeze), rétention 7 j / 4 sem.
2. **Dumps applicatifs** (timers systemd, fichiers inclus dans le backup du CT/VM) :
   - `pg_dump` Keycloak → `/var/backups/keycloak/`
   - copie de la base k3s : `sqlite3 /var/lib/rancher/k3s/server/db/state.db ".backup /var/backups/k3s-state.db"`
3. **Hors-site** : la clé age, le token Gandi et un export du realm Keycloak dans un coffre (pass/Vaultwarden homelab + copie offline).
4. **Runbook DR** (à tester, pas juste à écrire) — ordre de reconstruction :
   `réinstall PVE → Phase 1 (réseau/FW/HAProxy) → terraform apply → restore PBS des CT teleport+iam → ansible k3s → argocd bootstrap → sync`.
   Les workloads clients reviennent par GitOps ; seuls les PV stateful se restaurent depuis PBS.

**Validation** : restore réel d'un CT sur le homelab (test trimestriel) ; restore d'un fichier depuis un backup VM ; dump Keycloak réimporté sur un Keycloak jetable.

---

# Phase 9 — Durcissement final & exploitation (continu)

- **Scan externe** : `nmap -Pn -p- <IP>` → seul 443/tcp (et 51820/udp silencieux). Re-scan après chaque changement HAProxy/FW.
- **Audit accès** : revue mensuelle des RoleBindings (`kubectl-who-can` / `rakkess`), des users Keycloak et des sessions Teleport.
- **kube-bench** one-shot après l'install, corriger le raisonnable.
- **Mises à jour** : PVE mensuel (fenêtre annoncée aux clients) ; k3s mineure après test ; **Renovate** sur le repo GitHub pour les bumps charts/images en PR.
- **Rotation** : token PVE Terraform, jetons d'enrôlement Teleport (TTL courts), secrets clients au départ d'un client (supprimer groupe Keycloak + values file → ArgoCD prune le namespace).
- **Alertes minimales** : zpool degraded, disque > 80 %, cert < 15 j, backup PBS en échec (côté homelab), quota tenant > 90 %, node NotReady.

---

# Phase 10 — CMDB NetBox (½ journée)

## 10.1 Préalable : IP clientes réelles jusqu'à Traefik

En passthrough TCP, Traefik voit **toutes** les connexions publiques avec l'IP source de HAProxy (10.42.0.1) — impossible de distinguer interne/externe, donc pas d'`ipAllowList` fiable. Activer le PROXY protocol :

```
backend bk_ingress
    server w1 10.42.0.21:443 check send-proxy-v2
    server w2 10.42.0.22:443 check send-proxy-v2
```

Côté Traefik (values) : `entryPoints.websecure.proxyProtocol.trustedIPs: ["10.42.0.1/32"]`.
Double bénéfice : vraies IP dans les logs/rate-limits, et middlewares d'allowlist fiables pour les apps internes.

## 10.2 Déploiement

- Chart NetBox dans `kubernetes/platform/` (PostgreSQL + Redis inclus), PV local-path + `nodeSelector`, ressources cappées.
- Ingress `netbox.aetheriscloud.fr` **sans DNS public** (résolution côté homelab/WG uniquement) + middleware Traefik `ipAllowList` (10.99.0.0/24, 10.42.0.0/24) + **SSO OIDC Keycloak** (python-social-auth) — trois couches, MFA héritée du realm.

## 10.3 Modélisation initiale

1. Prefixes : `10.42.0.0/24` (interne), `10.99.0.0/24` (WG), IP publique.
2. L'hôte + les 5 VM/CT, IP primaires, cluster « dedibox ».
3. Tenants : `interne` + un par client ; custom field `namespace` ; tag `managed-by:ansible`.
4. Services : sso/443, teleport/443, kube/6443, apps/443.

## 10.4 Consommation par l'automatisation

- Inventaire Ansible **dynamique** (supprimer l'inventaire statique après validation) :

```yaml
# ansible/inventory/netbox.yml
plugin: netbox.netbox.nb_inventory
api_endpoint: https://netbox.aetheriscloud.fr
token: "{{ lookup('env', 'NETBOX_TOKEN') }}"
group_by: [tenants, tags, sites]
compose:
  ansible_host: primary_ip4
```

- Job CI `sync-netbox` (GitHub Action) : à chaque merge sur `tenants/`, un script pynetbox crée/met à jour le tenant + custom field `namespace`.
- DNS interne : rôle Ansible `dns-interne` générant la conf unbound/hosts **depuis l'inventaire NetBox**. Évolution si le besoin grossit : plugin `netbox-dns` + PowerDNS synchronisé.

**Validation** : `ansible-inventory --list` reflète NetBox ; retirer une machine de NetBox la fait disparaître de l'inventaire ; playbook `base` rejoué sans diff ; la fiche tenant montre machines + namespace + IP en un écran.

---

# Phase 11 — Portail client : tickets + self-service (dév, itératif)

Repo séparé `client-portal` (Flask/FastAPI + PostgreSQL). Le portail **orchestre** des APIs — il ne détient aucun credential Kubernetes.

```
Client ──OIDC Keycloak──► Portail (public, via Traefik)
                             │  lit  : API NetBox (assets, quotas du tenant)
                             │  écrit: tickets (module maison)
                             └─ "nouveau namespace" ─► PR sur tenants/<client>.values.yaml
                                                         │ token Git scoped + CI (helm template, kubeconform)
                                                         ▼
                                              merge (manuel au début) ─► ArgoCD ─► webhook retour
                                                         └─► statut portail + sync NetBox
```

## 11.1 Sécurité (non négociable)

- Client OIDC `portal` (confidentiel) dans le realm `infra` — même identité que kubectl, MFA héritée.
- Secrets détenus : token GitHub fine-grained (repo `infra-dedibox`, contenu uniquement), token NetBox à permissions objet, SMTP/ntfy. **Aucun kubeconfig.**
- Le portail est déployé **comme un tenant de plus** : namespace `portal`, quota, netpol, PSA `restricted`. Compromission = blast radius d'un tenant + deux tokens révocables.
- Rate limiting Traefik sur `/api` ; le values file est généré depuis un schéma validé, jamais depuis du texte libre client.

## 11.2 Contrat d'API minimal

| Endpoint | Rôle |
|---|---|
| `GET /me` | Identité + tenant (claims OIDC) |
| `GET/POST /tickets`, `POST /tickets/{id}/messages` | ITSM minimal |
| `GET /namespaces` | Assets du tenant (lecture NetBox) |
| `POST /namespaces` | Génère le values, ouvre la PR, renvoie l'URL de suivi |
| `POST /quotas/requests` | Demande d'augmentation → PR sur le values existant |

## 11.3 Jalons

1. **M1** — auth OIDC + lecture NetBox (vitrine du tenant).
2. **M2** — tickets (CRUD + notifications mail/ntfy).
3. **M3** — self-service namespace via PR, merge manuel.
4. **M4** — auto-merge si CI verte (après période de confiance) ; petit catalogue d'apps (values Helm générés).

**Validation** : parcours client fictif de bout en bout — login portail, ticket, demande de namespace, merge, namespace `Synced` dans ArgoCD, visible dans NetBox et le portail, kubectl OIDC fonctionnel dessus.

---

# Annexe — Matrice des flux

| Source | Destination | Port | Usage |
|---|---|---|---|
| Internet | hôte:443 | tcp | HAProxy → SNI (teleport/sso/kube/apps) |
| Internet | hôte:51820 | udp | WireGuard |
| Poste admin (via WG) | hôte:22/8006, 10.42.0.0/24 | tcp | Management |
| HAProxy | 10.42.0.5:443 / .6:443 / .11:6443 / .21-.22:443 | tcp | Backends |
| PVE | PBS homelab:8007 | tcp (via WG) | Backups |
| VMs/CT | Internet | 443 sortant | Paquets, images, ACME |
| Cluster | 10.42.0.6:443 (sso) | tcp | Vérification tokens OIDC |
| Poste admin (WG) | NetBox / ArgoCD (ingress interne) | tcp/443 | Administration (ipAllowList + OIDC) |
| Portail (pod) | NetBox (ClusterIP) | tcp | Lecture assets tenant |
| Portail (pod) | api.github.com | tcp/443 sortant | PR sur `tenants/` |

# Annexe — Checklist de mise en service client

- [ ] Groupe + user(s) Keycloak, MFA enrôlée
- [ ] Values file mergé, app ArgoCD Synced
- [ ] `kubectl auth can-i --list` vérifié avec un token du client
- [ ] Quota/LimitRange/netpol/PSA testés
- [ ] Kubeconfig + doc kubelogin livrés
- [ ] Contact + fenêtre de maintenance communiqués
