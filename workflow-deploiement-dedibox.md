# Workflow d'exécution — Déploiement Dedibox `aetheriscloud`

> Runbook dérivé de [`plan-deploiement-dedibox.md`](./plan-deploiement-dedibox.md). Une checklist par phase, dans l'ordre. Ne pas cocher une étape tant que sa **validation** n'est pas vérifiée — c'est elle qui garantit que la phase suivante part sur une base saine.

**Légende** : `[ ]` à faire · `⚠` point de non-retour / prudence · `✅` critère de validation de la phase

---

## Phase 0 — Préparation

- [x] Créer le repo GitHub privé — renommé `infra-ac` (au lieu de `infra-dedibox`), poussé sur `main`. Branch protection **non activée** : GitHub Free ne le permet pas sur un repo privé (nécessite Pro) — skip assumé pour l'instant, à revoir si upgrade ou passage en public
- [x] Clé age générée dans `~/.config/sops/age/keys.txt` (clé publique `age1ely0mwdy8jawc5zag2td3masfa3xp4hnxv07rzeslykfrr8gqdesv2uexy`) — sauvegardée hors-machine dans une note Bitwarden
- [x] `.sops.yaml` créé à la racine du repo avec la clé publique
- [x] `SOPS_AGE_KEY_FILE` ajouté à `~/.zshrc` (sops sur macOS ne cherche pas `~/.config/sops/age/keys.txt` par défaut sans cette variable, contrairement à Linux)
- [x] DNS Gandi : `teleport`, `sso`, `kube`, `*.apps` créés → `51.15.191.67`, vérifiés par `dig` (le record `teleport` préexistant vers une autre IP a été remplacé, confirmé intentionnel)
- [x] Personal Access Token Gandi obtenu et vérifié (API 200)
- [x] Poste d'admin : `terraform` (Homebrew), `ansible` (venv Python — Homebrew est parti sur une compilation LLVM de plusieurs heures pour une dépendance Rust transitive, tué et contourné), `kubectl`/`helm`/`sops`/`age`/`gh`/`tsh`/`tctl` (binaires officiels téléchargés directement, sans compilation). `kubectl-oidc_login` (krew) à faire en Phase 7
- [ ] Vérifier l'accès à la console Dedibox (mode rescue / KVM) comme filet de sécurité

**✅ Validation** : `dig +short sso.aetheriscloud.fr` renvoie l'IP · repo clonable · `sops -e` chiffre un fichier test

---

## Phase 1 — Socle Proxmox, réseau, entrée unique

### 1.1 Installation
- [x] Installer Proxmox VE 9 via console Dedibox, 2 SSD en miroir ZFS — confirmé : PVE 9.2.6 sur `stargate-px1`. Accès SSH root par clé dédiée opérationnel (mot de passe root refusé par design — `PermitRootLogin prohibit-password`, valeur par défaut)
- [x] ⚠ **Déviation constatée** : l'install n'était pas en ZFS RAID1 comme prévu — LVM mono-disque sur `sda`, `sdb` (disque identique, 238G) totalement vierge, aucun RAID (ni mdadm, ni ZFS). Décision : garder LVM sur `sda`, créer un pool ZFS mono-disque `local-zfs` sur `sdb` (storage PVE `images,rootdir`) — pas de redondance disque, rattrapable via IaC si réinstall un jour
- [x] Capper l'ARC ZFS à 3 Go — appliqué live (`/sys/module/zfs/parameters/zfs_arc_max`) + persistant (`/etc/modprobe.d/zfs.conf`), pas de reboot nécessaire (OS pas sur ZFS)
- [x] Repo no-subscription activé (`pve-enterprise` désactivé), `apt-get update` OK — correctif au passage : apt tentait IPv6 (absent sur l'hôte, link-local seulement) → `Acquire::ForceIPv4` ajouté. `dist-upgrade` : système déjà à jour

### 1.2 Réseau interne NATé
- [x] `vmbr1` (10.42.0.1/24) configuré dans `/etc/network/interfaces`, appliqué via `ifreload -a` (ifupdown2, pas de reboot)
- [x] `ip_forward=1` + MASQUERADE NAT actifs et vérifiés (`iptables -t nat -L POSTROUTING`)

### 1.3 WireGuard
- [x] ⚠ **Déviation** : pas de peer pfSense/homelab pour l'instant — ce Mac (poste d'admin) a son propre peer direct (`10.99.0.3/32`), plus simple et opérationnel immédiatement. Le peer pfSense (homelab, pour PBS Phase 8) sera ajouté quand on y arrivera.
- [x] `wireguard` installé, `wg0.conf` configuré (10.99.0.1/24, port 51820, peer Mac), `wg-quick@wg0` actif
- [x] Client Mac : app WireGuard officielle (App Store) + config importée (clé générée via Python/cryptography, `wg`/`wg-quick` Homebrew étant cassé — checksum invalide sur la dépendance `wireguard-go`)
- [x] Tunnel vérifié : `ping 10.99.0.1` et `ping 10.42.0.1` OK depuis le Mac

### 1.4 Firewall
- [x] ⚠ **Déviation** : le firewall natif PVE a été essayé mais abandonné — il ajoute automatiquement tout le `/24` public de l'hôte à un ipset "management" trusted sur SSH/8006 (anti-lockout by design, non désactivable proprement), ce qui contredit l'objectif "WG uniquement". Basculé sur **iptables manuel**, persisté via `netfilter-persistent` (`/etc/iptables/rules.v4`)
- [x] Politique DROP par défaut, testée en conditions réelles : SSH/8006 publics → timeout confirmé ; SSH/8006 via WG (`10.99.0.1`) → OK ; 443 ouvert au firewall (rien n'écoute encore, normal avant HAProxy)
- [x] Règles : tcp/443 (any), udp/51820 (any), tcp/22+8006 (10.99.0.0/24), tcp+udp/53 + icmp (10.42.0.0/24 et 10.99.0.0/24)
- [x] SSHd : `PasswordAuthentication no` forcé explicitement dans `sshd_config`, `sshd -t` validé, `systemctl reload ssh` OK

### 1.5 HAProxy (routage SNI)
- [x] `haproxy` installé, config `haproxy -c` validée, service actif
- [x] `frontend fe443` (inspect SNI, passthrough TCP) + backends `bk_teleport`/`bk_sso`/`bk_kubeapi`/`bk_ingress` en place — backends DOWN pour l'instant (VMs/CT pas encore déployées, normal)
- [x] Bascule firewall/HAProxy testée en conditions réelles avant de couper l'accès direct (voir 1.4) — pas eu besoin de la console KVM

**✅ Validation** : port 443 accepte les connexions TCP depuis l'extérieur (SNI routing actif, handshake TLS échoue faute de backend — attendu) · 22/8006 confirmés bloqués en externe, OK via WG · pas de `nmap` local disponible sur ce Mac pour le scan `-p-` complet, vérifié port par port à la place (22, 443, 8006, 51820)

---

## Phase 2 — Provisioning IaC

### 2.1 Accès API Proxmox pour Terraform
- [x] `terraform@pve` créé, rôle `PVEAdmin`
- [x] Token API généré (`terraform@pve!iac`, `--privsep=0`) — stocké dans `secrets/proxmox_api_token.txt` (gitignored), testé via `curl` sur `https://10.99.0.1:8006` (WG) → OK

### 2.2 Terraform (provider `bpg/proxmox`)
- [x] Code écrit puis **appliqué avec succès** : template Debian 13 genericcloud, 3 VMs (`k3s-adm` 10.42.0.11, `k3s-w1` 10.42.0.21, `k3s-w2` 10.42.0.22), 2 LXC (`teleport` 10.42.0.5, `iam` 10.42.0.6)
- [x] Cloud-init user `admin` + clé SSH sur les VMs (natif). Sur les LXC, le provider n'expose pas de champ `username` pour `user_account` (clé injectée dans `root` par défaut) → ajout d'un provisioner `remote-exec` qui crée `admin` (sudo NOPASSWD), copie la clé, puis désactive `PermitRootLogin` — comportement identique aux VMs
- [x] `terraform init/validate/plan/apply` tous OK. Ajustements en cours de route : nom de nœud PVE réel (`stargate-px1`, pas `pve`), token `terraform@pve` sans `Sys.Modify` (→ rôle custom `TerraformAdmin`), storage `local` sans content-type `import` (→ ajouté), mauvais nom de fichier template LXC (version `13.0-1` obsolète → `13.6-1`), extension de fichier invalide pour l'image qcow2 (`.qcow2.img` → `.qcow2`)
- [x] Renommage `k3s-server` → `k3s-adm` (Terraform, Ansible, docs)

### 2.3 Ansible — socle commun
- [x] `inventory.yml` écrit (groupes `k3s_server`, `k3s_agents`, `teleport`, `iam`), YAML validé
- [x] Rôle `base` **joué avec succès sur les 5 machines** : hardening sshd, unattended-upgrades, node_exporter partout ; chrony sur les 3 VMs seulement (les LXC non privilégiés n'ont pas `CAP_SYS_TIME` — `adjtimex` refusé, et de toute façon inutile car ils partagent l'horloge du noyau hôte — rôle rendu conditionnel via `is_container`)
- [x] `ansible all -m ping` OK sur les 5 machines · rejeu idempotent confirmé (2e passage : `failed=0` partout)

**✅ Validation** : `terraform apply` idempotent (0 changement au 2e run) · `ansible all -m ping` OK · les 5 machines sortent sur Internet via le NAT

---

## Phase 3 — IAM : Keycloak

### 3.1 Socle
- [x] Rôle Ansible `keycloak` écrit et joué avec succès : PostgreSQL 17 + base/user `keycloak`, OpenJDK 21, Keycloak 26.7.0 dans `/opt/keycloak` (symlink versionné), `kc.sh build --db=postgres`, admin bootstrap via `kc.sh bootstrap-admin user --password:env=...` (syntaxe Keycloak 26, différente de `--password`)
- [x] Certificat `sso.aetheriscloud.fr` obtenu via lego 5.3.1 (DNS-01 `gandiv5`) + timer systemd quotidien (`lego run --renew-days 30 --deploy-hook "systemctl reload nginx"`, lego 5.x n'a plus de sous-commande `renew` séparée)
- [x] nginx en frontal : TLS + proxy loopback, verrouillage `/admin` et `/realms/master` au réseau interne/WG — **avec PROXY protocol** (voir déviation ci-dessous)
- [x] ⚠ **Déviation/fix important** : en TCP passthrough, HAProxy masque la vraie IP cliente (tout arrive avec la source `10.42.0.1`), donc le `allow/deny` nginx ne servait à rien — `/admin` était accessible depuis l'extérieur malgré la config. Le plan n'anticipait ce problème que pour `bk_ingress` (Phase 10.1) ; appliqué aussi à `bk_sso` : `send-proxy-v2` sur le backend HAProxy + `listen 443 ssl proxy_protocol` et `set_real_ip_from`/`real_ip_header` côté nginx. Revérifié : externe → 403, via WG → 302 (OK)
- [x] Bugs lego 5.x rencontrés et corrigés : flags placés après la sous-commande (`lego run --path ...`, pas `lego --path ... run`), `--accept-tos` obligatoire sinon prompt interactif qui bloque silencieusement (`Y/n` jamais répondu → tourne jusqu'au timeout), variable d'env `GANDIV5_PERSONAL_ACCESS_TOKEN` (pas `GANDI_V5_API_KEY`)
- [x] Bug résolution DNS trouvé sur les LXC : `resolv.conf` pointe vers `127.0.0.1` (stub systemd-resolved) mais le service est inactif dans le conteneur → `connection refused` sur toute requête DNS stricte (a bloqué lego pendant 20 min de retry avant diagnostic). Contourné pour lego via `--dns.resolvers 8.8.8.8:53,1.1.1.1:53` ; fix racine appliqué (`initialization.dns.servers` sur les 2 LXC via Terraform, reboot déclenché automatiquement, `resolv.conf` propre confirmé, tous les services repartis)
- [x] Ansible : `allow_world_readable_tmpfiles` ajouté à `ansible.cfg` (le `become_user: postgres` depuis macOS générait un chmod ACL invalide sur Linux)

### 3.2 Realm `infra`
- [x] Realm `infra` créé via l'API admin (master jamais exposé, confirmé 403 externe)
- [x] Brute force protection activée (`bruteForceProtected: true`, `failureFactor: 5`) + `CONFIGURE_TOTP` mis en required action par défaut (MFA obligatoire pour tout nouvel utilisateur)
- [x] Groupe `infra-admins` créé (`client-<nom>` sera créé à l'onboarding, Phase 7)
- [x] Client `kubernetes` : public, PKCE S256, redirects `localhost:8000`/`localhost:18000`
- [x] Client `argocd` : confidentiel — redirect `https://argocd.aetheriscloud.fr/auth/callback` en placeholder, à ajuster Phase 6 selon l'URL réelle
- [x] Mapper `groups` (oidc-group-membership-mapper, full path off) ajouté sur les deux clients
- [x] Utilisateur `vanti` créé, ajouté à `infra-admins`, mot de passe temporaire défini, `CONFIGURE_TOTP` en attente — ⚠ **enrôlement MFA à finir manuellement** (nécessite un vrai navigateur + authenticator, pas scriptable via l'API admin par design Keycloak)

**✅ Validation** : `.well-known/openid-configuration` (`infra`) → 200 externe confirmé · `/admin` → 403 externe confirmé, 302 via WG confirmé · login MFA : **en attente que l'utilisateur complète l'enrôlement**

---

## Phase 4 — Bastion Teleport

- [x] Teleport Community installé sur le CT `teleport` via le dépôt apt officiel (codename `trixie` fonctionne directement), rôle Ansible `teleport` écrit et joué
- [x] `auth_service` (local, webauthn), `proxy_service` (ACME TLS-ALPN-01), `ssh_service` activés — cert Let's Encrypt obtenu, valide jusqu'au 1 nov 2026
- [x] ⚠ **Déviations/fixes** : (1) `web_listen_addr: 0.0.0.0:443` obligatoire — Teleport écoute sur 3080 par défaut, `public_addr` seul ne suffit pas à faire écouter sur 443 ; (2) `proxy_listener_mode: multiplex` obligatoire sous `auth_service` — `version: v3` seul n'active pas le TLS routing comme supposé par le plan, sans ça les agents tentent le port legacy 3024 (bloqué par le firewall) pour le tunnel retour
- [x] `tctl users add vanti --roles=editor,access --logins=admin,root` → lien d'invitation généré (1h, à finir par l'utilisateur)
- [x] Jeton d'enrôlement généré (`tctl tokens add --type=node --ttl=1h`)
- [x] `ssh_service` déployé via Ansible (rôle `teleport-agent`) sur les 4 machines restantes (`k3s-adm`, `k3s-w1`, `k3s-w2`, `iam`) — les 5 machines apparaissent dans `tctl nodes ls`
- [ ] Optionnel : `app_service` pour publier UI PVE / ArgoCD — pas fait, reporté
- [x] ⚠ **Bug HAProxy trouvé en conditions réelles** : le client gRPC de `tsh` (étape `ConnectToRootCluster`, post-MFA) utilise un SNI spécial encodé — `<hex(nom du cluster)>.teleport.cluster.local` (ex: `64656469626f782e...` = hex de `dedibox.aetheriscloud.fr`) — au lieu de `teleport.aetheriscloud.fr`. La règle HAProxy ne matchait que le nom exact, donc ce trafic tombait sur `default_backend bk_ingress` (rien n'écoute) → `EOF` immédiat côté client. Diagnostiqué via `tsh login -d` + `GRPC_GO_LOG_VERBOSITY_LEVEL=99` (a révélé le SNI exact utilisé), confirmé par décodage hex. Fix : règle HAProxy supplémentaire `use_backend bk_teleport if { req_ssl_sni -m end -i .teleport.cluster.local }`
- [x] Diagnostic secondaire (non bloquant, gardé pour info) : WebAuthn natif (`tsh`) échoue toujours avec "no security keys found"/"touch ID not available" sur ce Mac — pas de clé FIDO2 physique et le binding Touch ID ne fonctionne pas depuis le binaire extrait du bundle `.app`. Fallback navigateur (`BROWSER` mode) fonctionne et suffit

**✅ Validation** : `tsh login --proxy=teleport.aetheriscloud.fr --user=vanti` (MFA via navigateur) → **confirmé fonctionnel par l'utilisateur**

---

## Phase 5 — Cluster k3s

- [x] Rôle Ansible `k3s-adm` écrit et joué : `INSTALL_K3S_VERSION` pinnée (`v1.36.2+k3s1`, dernière stable au moment du run), `disable: [traefik, servicelb]`, taint control-plane, `tls-san` (`kube.aetheriscloud.fr`, `10.42.0.11`), `secrets-encryption: true`, flags OIDC apiserver (`oidc-issuer-url` → realm `infra` déjà en place Phase 3, `oidc-client-id=kubernetes`, claims username/groups avec préfixe `oidc:`)
- [x] Rôle Ansible `k3s-agent` sur w1/w2 (config.yaml avec `server`/`token`, token partagé généré une fois via `openssl rand -hex 32` → `secrets/k3s_token.txt`, gitignored)
- [x] Kubeconfig admin récupéré via Ansible (`fetch` + réécriture de l'URL `127.0.0.1` → `https://10.42.0.11:6443`) → `secrets/kubeconfig/admin.yaml` (gitignored), accessible uniquement via WG
- [x] ⚠ **Bug de rôle trouvé et corrigé** : la tâche de déploiement de `config.yaml` était conditionnée à tort par `when: <already installed>` (pensée pour éviter un redémarrage inutile au premier install), ce qui skippait complètement le dépôt du fichier de config **avant** le tout premier `k3s-install.sh`. Conséquence sur `k3s-adm` : le server a démarré avec un token auto-généré (pas le nôtre) et sans aucune des options voulues (taint, disable traefik/servicelb, OIDC, secrets-encryption). Sur les agents, l'installeur k3s exige `--token` explicitement → échec bruyant (`Error: --token is required`), ce qui a permis de détecter le bug avant qu'il ne passe inaperçu côté serveur. Fix : dépôt du `config.yaml` inconditionnel (toujours avant l'install), le handler de redémarrage reste sans condition (redémarrage surnuméraire au premier install, sans impact)
- [x] ⚠ **Collision de plages IP trouvée en conditions réelles** : le CIDR pods par défaut de k3s (`10.42.0.0/16`) englobe exactement notre réseau physique VM/LXC (`10.42.0.0/24`, vmbr1). Flannel a installé sur chaque nœud une route `10.42.0.0/24 via ... dev flannel.1` qui **écrasait** la route physique vers les autres nœuds du même réseau — symptôme : les agents tournaient en boucle des heures sur `Failed to validate connection to cluster ... failed to get CA certs: context deadline exceeded`, alors que le serveur écoutait bien sur `:6443` et que SSH (venant du Mac via WG, jamais des nœuds entre eux) fonctionnait sans problème, masquant la panne. Diagnostiqué via `ip route` sur un agent bloqué. Fix : `cluster-cidr: 10.44.0.0/16` et `service-cidr: 10.43.0.0/16` explicites dans `config.yaml` du server (hors de toute plage déjà utilisée : 10.42.0.0/24 physique, 10.99.0.0/24 WG) — server et les 2 agents réinstallés proprement (`k3s-uninstall.sh`/`k3s-agent-uninstall.sh`) après correctif, routes confirmées propres (`10.42.0.0/24 dev eth0` direct, plus de route flannel bidon)

**✅ Validation** : `kubectl get nodes` → 3 Ready (`k3s-adm`, `k3s-w1`, `k3s-w2`) confirmé · taint `node-role.kubernetes.io/control-plane=true:NoSchedule` présent sur `k3s-adm` confirmé · `kubectl get --raw /readyz` → `ok` confirmé

---

## Phase 6 — GitOps et plateforme

### 6.1 Bootstrap ArgoCD
- [x] ArgoCD bootstrappé via `helm install` (hors GitOps, cf. `kubernetes/bootstrap/values.yaml`), pas de Service public (`server.insecure: true`, accès par `kubectl port-forward` uniquement, même modèle que les autres surfaces admin de ce projet)
- [x] SSO OIDC → Keycloak (client `argocd`, mapper `groups` déjà attaché au client). RBAC : `g, oidc:infra-admins, role:admin` / défaut `role:readonly`
- [x] ⚠ **Déviation** : scope OIDC `groups` retiré de `requestedScopes` (`invalid_scope` — Keycloak n'expose pas de client scope nommé `groups` ; le mapper étant attaché directement au client, il s'applique de toute façon sans avoir besoin d'être demandé comme scope)
- [x] ⚠ **Blocage mdp Keycloak** (sans lien avec ArgoCD) : le compte `vanti` refusait son mot de passe pendant le test de login — pas un verrou brute-force (3/5 tentatives). Résolu par reset d'un mot de passe temporaire via l'API admin Keycloak (le mot de passe initial de Phase 3 avait été changé pendant l'enrôlement MFA, désynchronisé de `secrets/keycloak_vanti_temp_password.txt`)
- [x] Repo GitHub connecté via deploy key lecture seule (`argocd-readonly`) + app-of-apps (`kubernetes/bootstrap/app-of-apps.yaml` → `kubernetes/platform/`, `directory.recurse: true`)
- [x] ⚠ **Rattrapage git** : tout le travail des Phases 1-5 (terraform/, ansible/, .sops.yaml) n'était encore que local — committé et poussé en une fois avant de démarrer le GitOps (ArgoCD a besoin du repo à jour pour exister)

### 6.2 Apps plateforme (via ArgoCD)
- [x] **traefik** : 2 replicas, `hostPort: 443` (`ports.websecure.hostPort`), ingressClass par défaut (défaut du chart). ⚠ Déviations : (1) l'override `service.type: ClusterIP` ne prenait pas — la clé réelle du chart est `service.spec.type`, pas `service.type` (Service resté `LoadBalancer`, `<pending>` indéfiniment, servicelb désactivé) ; (2) `updateStrategy` par défaut (`maxSurge: 1`) bloquait le rolling update — avec seulement 2 workers et `hostPort: 443`, le 3ᵉ pod (transition) n'a nulle part où se scheduler → `maxSurge: 0` / `maxUnavailable: 1`
- [x] **PROXY protocol bout-en-bout sur l'ingress public** (dette explicitement notée en Phase 3 pour la Phase 10.1, traitée maintenant puisque l'ingress devient réel) : `send-proxy-v2` ajouté aux deux serveurs de `backend bk_ingress` côté HAProxy (édition manuelle du host, comme le reste de la config HAProxy) + `ports.web/websecure.proxyProtocol.trustedIPs: ["10.42.0.1/32"]` côté Traefik. Vérifié : `X-Forwarded-For` montre bien l'IP publique réelle du client sur `whoami`, pas `10.42.0.1`
- [x] **cert-manager + webhook Gandi + ClusterIssuer + wildcard `*.apps.aetheriscloud.fr`** — validé en HTTPS externe (`openssl s_client`/`curl`, `SSL certificate verify ok`), `TLSStore` Traefik par défaut. Chaîne de déviations rencontrées, dans l'ordre :
  - Le webhook cert-manager pour Gandi n'a pas d'implémentation officielle maintenue (forks communautaires uniquement, image la plus utilisée datant de 2021) → décision utilisateur : **construire notre propre image** après revue du code source (voir `kubernetes/platform/cert-manager/README.md`). Buildée via `podman` sur `k3s-w1` (pas de Docker sur le poste macOS), poussée vers un registre **Gitea** auto-hébergé déployé pour l'occasion (voir plus bas)
  - Bug de compatibilité corrigé dans le fork : le code (2021) envoie `Authorization: Apikey <token>` — les Personal Access Tokens Gandi actuels exigent `Authorization: Bearer <token>`. Avec `Apikey`, Gandi répond 403 sur absolument tout (y compris `user-info`), ce qui a d'abord semblé être un token expiré/révoqué avant diagnostic comparatif (`Apikey` vs `Bearer` sur un enregistrement déjà géré avec succès par `lego`)
  - `helm template` (utilisé par ArgoCD) ignore silencieusement le dossier `crds/` natif de Helm : bootstrap manuel une fois (`kubectl apply` de l'Application cert-manager + webhook), pattern identique à Keycloak/Teleport pour les CRDs qu'ArgoCD ne peut pas installer lui-même en une seule passe (race de validation atomique : le ClusterIssuer/Certificate référençant des CRD inexistantes bloque tout le batch de sync `platform`, pas juste eux)
  - SAN apex `apps.aetheriscloud.fr` retirée du Certificate : elle partage le même enregistrement `_acme-challenge.apps` que le wildcard, et cette implémentation simple du webhook (une valeur par rrset, pas d'union) fait échouer les deux challenges qui se marchent dessus. Pas requis par le plan de toute façon
- [x] **kube-prometheus-stack** : rétention 10j (défaut du chart), ressources cappées. `nodeExporter` du chart désactivé (conflit `hostNetwork:9100` avec le node_exporter déjà déployé par Ansible sur les 5 hôtes/CT) → scrape statique à la place. Même bug de CRD `helm template`-vs-`crds/` que cert-manager (`kubectl apply --server-side` requis en plus : les CRD Prometheus/Alertmanager dépassent la limite de 262144 octets de l'annotation `kubectl apply` classique) + operator à redémarrer une fois les CRD posées (son cache de découverte API était déjà chargé sans elles). ⚠ **node_exporter manquant trouvé sur l'hôte PVE lui-même** (10.42.0.1) : jamais installé (seules les 5 machines Ansible-managées l'ont) — installé manuellement (même méthode que le rôle `base`), et règle iptables `tcp/9100` depuis `10.42.0.0/24` ajoutée **avant** le DROP catch-all (une première tentative avait été ajoutée après par erreur, donc jamais évaluée). Alertmanager déployé **sans route de notification** — mail/ntfy différé, décision explicite de l'utilisateur
- [x] **teleport-kube-agent** : rôle `kube` uniquement (pas `app`/`discovery`, hors scope), jeton de join créé hors Git dans un Secret pré-existant. `kube_server` `dedibox` confirmé `healthy` côté `tctl`
- [x] **sops-secrets** : clé age privée en Secret Kubernetes (`sops-age-key`, namespace `sops`), créée hors Git. Pas de plugin helm-secrets/CMP ArgoCD (voir `kubernetes/platform/sops/README.md`) : aucune appli de la Phase 6 n'en a eu besoin, chacune a reçu ses secrets via un Secret K8s dédié référencé directement (`existingSecret`/`secretKeyRef`) — à réévaluer si un futur besoin (ex. values par tenant, Phase 7) rend ce pattern impraticable
- [ ] netbox (déploiement complet en Phase 10, inchangé)
- [x] **Hors plan initial, ajouté à la demande de l'utilisateur en cours de phase** :
  - **Gitea** (Git auto-hébergé) : décision explicite de le faire tourner **comme workload k3s/ArgoCD** plutôt qu'en CT LXC dédié (pattern pourtant déjà établi pour Keycloak/Teleport) — risque de dépendance circulaire GitOps déjà identifié en mémoire de session et explicitement soumis à l'utilisateur avant de trancher. Mitigation : le bootstrap ArgoCD (`kubernetes/platform/`) reste sourcé depuis GitHub indéfiniment, jamais re-pointé vers Gitea sans décision explicite séparée. PostgreSQL dédié minimal (pas le sous-chart Bitnami bundlé, qui exige un mot de passe en clair dans les values Helm) + `strategy: Recreate` (RWO unique + verrou LevelDB des queues, le rolling update par défaut fait chevaucher ancien/nouveau pod)
  - **Harbor** (registre de conteneurs — a remplacé l'usage initial du registre intégré Gitea) : décision explicite de l'utilisateur, plusieurs apps à héberger justifient les fonctionnalités Harbor (scan Trivy, projets/quotas, replication) plutôt qu'un registre minimal. NodePort (pas ClusterIP/ingress — même raison que Gitea : containerd résout côté hôte, pas côté pod, un nom de Service cluster-interne est inutilisable pour un pull d'image), TLS désactivé en interne (WG/cluster uniquement). Projet `aetheriscloud` rendu **public** (pas de secret de pull par pod) : le vrai périmètre de sécurité ici est déjà le réseau (WG/cluster-only), pas l'auth applicative — cohérent avec le reste de cette infra. Mot de passe admin via Secret créé hors Git. `registries.yaml` Ansible étendu pour accepter Gitea et Harbor en plain HTTP sur les 3 nœuds k3s
  - **HashiCorp Vault** : mode standalone (storage `file`, pas de Consul/HA), TLS désactivé en interne (WG/port-forward uniquement). Initialisé/unscellé (5 clés, seuil 3) — clés + root token dans `secrets/vault_init.json`, **à déplacer vers un stockage hors-ligne** (cf. Phase 8). Auth OIDC Keycloak configurée et **validée par l'utilisateur**. KV v2 activé, confs WireGuard (phone/work-pc) stockées sous `secret/wireguard/`
  - **2 peers WireGuard supplémentaires** (PC boulot `10.99.0.4`, téléphone `10.99.0.5`) — configs générées, QR code pour le téléphone (scan direct, jamais transféré sur le réseau), fichier `.conf` pour le PC boulot à transférer par un canal contrôlé par l'utilisateur
  - **Portail self-service WG** (Keycloak SSO+MFA, exposé publiquement pour permettre le tout premier accès d'un appareil neuf sans device déjà connecté) : **différé à une session dédiée**, décision explicite de l'utilisateur — c'est un vrai développement (petite app + gestion dynamique des peers WG + restriction SSH forcée côté hôte PVE), pas un simple déploiement de chart

### 6.3 Namespaces
- [x] Convention appliquée : `aetheriscloud.fr/tier` (`platform`/`internal`) sur tous les namespaces créés en Phase 6, PSA cohérente avec le tableau du plan (`traefik`=privileged pour le hostPort ; `monitoring`=**baseline** et non privileged comme prévu au plan — déviation assumée, le `nodeExporter` du chart qui aurait justifié `privileged` est désactivé, cf. ci-dessus ; le reste = baseline ; `aetheris-apps`=restricted)
- [x] ⚠ **Trouvé en revue** : le namespace `argocd` (créé par le `helm install` initial, avant l'existence même du concept de convention de labels dans cette session) n'avait **aucun** label — corrigé (`tier=platform`, PSA baseline), vérifié sans impact sur les pods déjà en place avant de committer

**✅ Validation** :
- [x] Toutes les apps ArgoCD `Healthy/Synced` (`cert-manager`, `cert-manager-webhook-gandi`, `gitea`, `monitoring`, `teleport-kube-agent`, `traefik`, `vault`) — ⚠ l'app-of-apps racine `platform` reste bloquée en health `Progressing` de façon persistante (survit à un `hard refresh` et à un redémarrage complet de `argocd-application-controller`) alors qu'**aucune** ressource individuelle de son arbre ne rapporte de health non-Healthy ; tout indique une caractéristique connue d'ArgoCD avec le pattern app-of-apps (les `Application` enfants gérées comme ressources brutes par une `Application` parente ne bénéficient pas d'un health check natif et semblent par défaut compter comme non-résolues côté parent) plutôt qu'un vrai problème — chaque appli enfant vérifiée individuellement fonctionne
- [x] `whoami.apps.aetheriscloud.fr` en TLS wildcard valide (`SSL certificate verify ok`, `X-Forwarded-For` = IP cliente réelle)
- [ ] Alerte test Alertmanager reçue — non applicable pour l'instant (pas de route de notification configurée, décision différée)
- [x] `kube_server` `dedibox` `healthy` côté Teleport (`tctl get kube_server`) — `tsh kube login dedibox` **pas encore testé côté client** (nécessite un test interactif de l'utilisateur, comme `tsh ssh` en Phase 4)

---

## Phase 7 — Multi-tenancy et onboarding client

> ⚠ **Version légère mise en place en avance de phase**, à la demande explicite de l'utilisateur ("Met en place une vitrine, on fera évoluer si trop de client à moyen/long terme") pendant les travaux de Phase 6. Le chart et l'ApplicationSet sont réels et fonctionnels ; ce qui reste en `[ ]` (kubeconfig livré à un vrai client, revue au-delà d'un client de test) attend simplement l'arrivée d'un premier vrai client.

### 7.1 Chart `onboarding-client`
- [x] Template namespace `cust-<nom>` avec labels PSA `restricted` (+ `aetheriscloud.fr/tier: tenant`)
- [x] Template RoleBinding groupe Keycloak (`oidc:client-<nom>`) → ClusterRole `edit` (jamais admin/cluster-admin)
- [x] Template ResourceQuota (cpu/mémoire/pods/PVC/storage — valeurs du plan par défaut, surchageables par client via values)
- [x] Template LimitRange (defaults + max par conteneur)
- [x] Template NetworkPolicy — ⚠ **déviation** : le plan décrit 4 policies séparées (default-deny + 3 allow) ; **une seule** consolidée à la place. Trouvé en validant le client de test : kube-router (moteur netpol de k3s) n'unit pas correctement plusieurs objets `NetworkPolicy` ciblant les mêmes pods — même le trafic intra-namespace censé être autorisé se faisait refuser (`connection refused`). Un seul objet combinant toutes les règles fonctionne correctement
- [x] **Hors plan** : `kubernetes/bootstrap/tenants-appset.yaml`, un `ApplicationSet` (générateur git `files` sur `kubernetes/tenants/*.values.yaml`) plutôt qu'une Application par client créée à la main — ajouter un client = ajouter un fichier de values, ArgoCD fait le reste

### 7.2 Onboarding d'un client test (`cust-test`)
- [x] Groupe `client-test` + user `cust-test-user` (MFA en required action) créés dans Keycloak
- [x] `kubernetes/tenants/test.values.yaml` créé → poussé directement sur `main` (pas de vraie PR, solo pour l'instant) → sync ArgoCD automatique
- [ ] Livrer le kubeconfig type (exec plugin oidc-login) — pas fait, pas de vrai client pour l'instant

**✅ Validation** (testée avec `--as-group=oidc:client-test`, admin kubectl) :
- [x] `kubectl auth can-i --list -n cust-test` montre `edit` (pods/services/deployments/... en create/delete/get/list/patch/update/watch)
- [x] `kubectl auth can-i list namespaces` / `list pods -n kube-system` → **interdit**, confirmé
- [x] LimitRange déclenché correctement : un pod sans requests explicites reçoit automatiquement `requests: {cpu:100m, memory:128Mi}` / `limits: {cpu:500m, memory:512Mi}`
- [x] Pod privilégié → rejeté par PSA `restricted` (confirmé : `privileged`, `allowPrivilegeEscalation`, capabilities, `runAsNonRoot`, `seccompProfile` tous exigés)
- [x] Netpol isole le namespace : intra-namespace autorisé, cross-namespace (`aetheris-apps` → `cust-test`) refusé, egress DNS vers `kube-system` fonctionnel — revalidé après le fix de consolidation ci-dessus (⚠ le premier test avec un pod `nginx:alpine` a d'abord donné un faux négatif : nginx crashait sous PSA restricted — `mkdir /var/cache/nginx/client_temp: Permission denied` — sans rapport avec le netpol ; retesté avec un serveur `busybox httpd`, PSA-compatible)

> 📌 Rappel : au-delà de 2-3 clients, évaluer la bascule vers **Capsule**.

---

## Hors plan — Accès distant : Teleport `app_service` + portail `aetheriscloud.fr`

Décidé en cours de Phase 6/7 à la place du portail self-service WireGuard initialement envisagé (jugé trop sensible : gestion dynamique de peers VPN = surface d'attaque réseau, pas juste applicative).

- [x] `app_service` activé sur `teleport-kube-agent` (rôles `kube,app` — rejoin avec un nouveau token nécessaire, l'agent n'a pas de PVC d'identité donc le rejoin est immédiat au redémarrage du pod) : Vault, ArgoCD, Harbor, Grafana, Gitea proxifiés sous `<nom>.teleport.aetheriscloud.fr`
- [x] DNS wildcard `*.teleport.aetheriscloud.fr` ajouté (Gandi) + règle HAProxy `req_ssl_sni -m end -i .teleport.aetheriscloud.fr` → `bk_teleport`. Vérifié en HTTPS externe : redirection correcte vers la page de login Teleport
- [x] ⚠ **Limite Teleport Community trouvée** : `tctl get oidc` fonctionne (liste vide) mais `tctl create` sur un connecteur OIDC échoue (`OIDC is only available in Teleport Enterprise`) — pas de SSO Keycloak possible sur Teleport lui-même sans licence payante. Décision utilisateur : garder les comptes Teleport locaux (WebAuthn, déjà en place depuis la Phase 4) — un compte par personne ayant besoin d'accéder aux outils, comme `vanti` aujourd'hui. Double authentification donc (Keycloak pour le portail, Teleport local pour l'accès aux outils via `app_service`), assumé
- [x] **Portail `aetheriscloud.fr`** (`apps/portal/`, FastAPI + OIDC Keycloak natif, PAS via Teleport) : dashboard listant les outils accessibles selon le groupe Keycloak de l'utilisateur, plutôt que d'exposer directement les URLs Teleport brutes. Buildé via `podman` sur `k3s-w1` (même méthode que le webhook Gandi), déployé namespace `portal` (tier `internal`, PSA `restricted`). Certificate cert-manager dédié pour l'apex `aetheriscloud.fr` (hors du wildcard `*.apps`, SAN séparée) — routage HAProxy déjà couvert par le `default_backend bk_ingress` existant, aucune règle supplémentaire nécessaire
  - ⚠ Version scoped-down du "Portail client" prévu en Phase 11 du plan, codée directement dans ce repo (`apps/portal/`) plutôt que dans un repo séparé `client-portal` comme prévu — à réévaluer si ça grossit vers le vrai portail multi-tenant (tickets, self-service namespace, NetBox…)
- [x] Client Keycloak `teleport` créé (confidentiel, mapper `groups`) — actuellement inutilisé faute de support OIDC côté Teleport Community, gardé au cas où une bascule Enterprise serait décidée plus tard

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
