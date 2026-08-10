# Reprise après sinistre — aetheriscloud (hors backup)

> Scénario couvert : l'hôte Proxmox (`stargate-px1`, 51.15.191.67) crashe et se corrompt —
> disque mort, réinstallation nécessaire. **La Phase 8 (backups) n'est pas faite** : ce
> document décrit comment reconstruire l'architecture depuis le code, pas comment
> récupérer les données. Tout ce qui n'est que dans une base de données vivante
> (Vault, Gitea, Harbor, NetBox, sessions Keycloak) est considéré perdu — c'est le
> risque explicitement accepté en attendant que le NAS maison soit prêt.
>
> Écrit le 2026-08-04 en auditant l'état réel de la stack (configs live relues sur
> l'hôte, pas juste le plan de déploiement) — corrige au passage plusieurs écarts entre
> ce que `plan-deploiement-dedibox.md` décrit et ce qui tourne réellement.

## 0. Le vrai point de rupture : `secrets/`

Rien de ce qui suit n'est possible sans le dossier `secrets/` de ce repo (gitignored,
**uniquement sur ce Mac**, jamais copié ailleurs). Avant de commencer, vérifier qu'on a
toujours accès à :

- `proxmox_api_token.txt`, `gandi.token` — pour Terraform et le renouvellement TLS
- `ssh/dedibox_root`, `ssh/vm_admin` — accès root à l'hôte et admin aux VM/LXC
- `wg_mac_private.key` (+ la conf WireGuard côté Mac) — sans ça, plus aucun accès admin
  au réseau interne (10.42.0.0/24), ni SSH, ni UI Proxmox, ni Keycloak `/admin`
- `keycloak_admin_password.txt`, `keycloak_db_password.txt`
- `vault_init.json` (token root + 5 clés unseal) — **si ce fichier est perdu en même
  temps que Proxmox, tout ce qui était dans Vault est irrécupérable même en théorie**
- `k3s_token.txt`, `netbox_api_token.txt`, tous les `*_oidc_client_secret.txt`

Si ce Mac est aussi hors service, ce document ne sert à rien : c'est le vrai single
point of failure du projet, plus critique que Proxmox lui-même.

## 1. Ce qui est perdu (rappel)

- Toutes les données Vault (secrets, policies) — nouvelles clés d'unseal à générer
- Tous les dépôts hébergés sur Gitea — **sauf ce repo `infra-ac` lui-même**, qui reste
  sur GitHub (`Vanti7/infra-ac`), indépendant de Proxmox
- Toutes les images Harbor — rebuildables depuis le source pour `portal`
  ([apps/portal/Dockerfile](apps/portal/Dockerfile)), à refaire à la main pour
  `cert-manager-webhook-gandi` (recette documentée dans
  [kubernetes/platform/cert-manager/README.md](kubernetes/platform/cert-manager/README.md),
  mais le code patché n'est pas vendorisé dans ce repo)
- L'IPAM NetBox au-delà de ce que `terraform/netbox.tf` sait recréer (tout ce qui a été
  ajouté à la main par la suite, un vrai tenant client par exemple)
- Les comptes/sessions Keycloak au-delà de la structure du realm (à recréer, cf. §3.6)
- Dashboards Grafana, historique Prometheus/Alertmanager

## 2. Ordre de reconstruction

### 3.1 Réinstallation Proxmox (100% manuel)

Aucun code ne couvre cette étape — réinstallation standard Proxmox VE sur le serveur
physique (ISO officiel), comme la toute première installation. Noter le nom d'hôte
exact : **`stargate-px1`** (les templates cloud-init et plusieurs configs y font
référence).

### 3.2 Réseau hôte (100% manuel — rien dans Ansible/Terraform)

C'est le plus gros trou documentaire trouvé en préparant ce document : toute cette
couche a été faite main sur l'hôte et n'a jamais été reprise en code.

**`/etc/network/interfaces`** (config réelle relue sur l'hôte, diffère légèrement du
brouillon initial du plan — l'interface publique n'y était pas détaillée) :

```
auto lo
iface lo inet loopback

iface eno1 inet manual

auto vmbr0
iface vmbr0 inet static
    address 51.15.191.67
    netmask 255.255.255.0
    hwaddress AC:1F:6B:23:CF:50
    gateway 51.15.191.1
    bridge_ports eno1
    bridge_stp off
    bridge_fd 0

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

`hwaddress` sur `vmbr0` doit correspondre à la MAC réservée par Online/Scaleway pour
cette IP — sinon pas de réseau public du tout. Vérifier dans la console Online si l'IP
publique ou la MAC changent après réinstallation.

`net.ipv4.ip_forward=1` doit aussi être dans `/etc/sysctl.conf` (persistant au reboot,
indépendamment du `post-up` ci-dessus).

**WireGuard** (`/etc/wireguard/wg0.conf`) — la clé privée n'est **pas** dans ce
document (jamais commitée nulle part) ; à régénérer si perdue, ce qui veut dire
reconfigurer les 3 peers ci-dessous :

```
[Interface]
Address    = 10.99.0.1/24
ListenPort = 51820
PrivateKey = <à régénérer avec wg genkey, ou restaurer depuis secrets/wg_mac_*.key
              si le Mac est intact — la clé de l'hôte, elle, n'est nulle part
              ailleurs que sur l'hôte lui-même>

[Peer]                       # poste admin (Mac) — accès direct
PublicKey  = iuNfbVJnDrLRYA6GL0qqjeteXiQEYNedMhHvA+XO2VA=
AllowedIPs = 10.99.0.3/32

[Peer]                       # PC boulot
PublicKey  = OmJ6FdROrMZuBh7PnVfK4tZKnc3/xblEHnCFCxOwb3w=
AllowedIPs = 10.99.0.4/32

[Peer]                       # Téléphone
PublicKey  = E93IwqhPPJCuz292uocKWUmNafRX+dhLXQmAXQOAyTI=
AllowedIPs = 10.99.0.5/32
```

Puis `systemctl enable --now wg-quick@wg0`.

**Pare-feu** — le plan parle du "PVE firewall" mais en réalité **le firewall intégré
Proxmox est désactivé** (`pve-firewall status` → `disabled`) ; le filtrage réel se fait
en `iptables` brut, persisté via `iptables-persistent`
(`/etc/iptables/rules.v4`/`rules.v6`, rechargés au boot par `netfilter-persistent`) :

```
apt install iptables-persistent
```

`/etc/iptables/rules.v4` :

```
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 10.42.0.0/24 -o vmbr0 -j MASQUERADE
COMMIT
*filter
:INPUT DROP [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A INPUT -m conntrack --ctstate INVALID -j DROP
-A INPUT -p tcp --dport 443 -j ACCEPT
-A INPUT -p udp --dport 51820 -j ACCEPT
-A INPUT -s 10.99.0.0/24 -p tcp --dport 22 -j ACCEPT
-A INPUT -s 10.99.0.0/24 -p tcp --dport 8006 -j ACCEPT
-A INPUT -s 10.42.0.0/24 -p tcp --dport 53 -j ACCEPT
-A INPUT -s 10.42.0.0/24 -p udp --dport 53 -j ACCEPT
-A INPUT -s 10.99.0.0/24 -p icmp -j ACCEPT
-A INPUT -s 10.42.0.0/24 -p icmp -j ACCEPT
-A INPUT -s 10.42.0.0/24 -p tcp --dport 9100 -j ACCEPT
-A INPUT -j DROP
COMMIT
```

`sshd_config` : `PasswordAuthentication no` (clé uniquement, `secrets/ssh/dedibox_root`).

**HAProxy** (`apt install haproxy`, `/etc/haproxy/haproxy.cfg`) — version réelle
actuelle, avec le PROXY protocol ajouté en Phase 6/10.1 (absent du brouillon initial
du plan) :

```
global
    log /dev/log local0

defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 5s
    timeout client  1h
    timeout server  1h

frontend fe443
    bind :443
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    use_backend bk_teleport if { req_ssl_sni -i teleport.aetheriscloud.fr }
    use_backend bk_teleport if { req_ssl_sni -m end -i .teleport.cluster.local }
    use_backend bk_teleport if { req_ssl_sni -m end -i .teleport.aetheriscloud.fr }
    use_backend bk_sso      if { req_ssl_sni -i sso.aetheriscloud.fr }
    use_backend bk_kubeapi  if { req_ssl_sni -i kube.aetheriscloud.fr }
    default_backend bk_ingress

backend bk_teleport
    server teleport 10.42.0.5:443 check

backend bk_sso
    server iam 10.42.0.6:443 check send-proxy-v2

backend bk_kubeapi
    server k3s 10.42.0.11:6443 check

backend bk_ingress
    server w1 10.42.0.21:443 check send-proxy-v2
    server w2 10.42.0.22:443 check send-proxy-v2
```

`send-proxy-v2` sur `bk_sso`/`bk_ingress` implique que nginx (Keycloak) et Traefik
attendent un en-tête PROXY protocol — **toute connexion directe à 10.42.0.6 ou
10.42.0.21/.22 qui ne passe pas par ce HAProxy sera rejetée au TLS handshake**
(`Connection reset by peer`, constaté en préparant ce document). Ce n'est pas un bug,
c'est voulu — mais ça veut dire qu'on ne peut plus déboguer Keycloak/Traefik en tapant
l'IP interne directement une fois HAProxy en place.

> Note annexe : `bind9` est installé sur l'hôte (`named`, écoute sur toutes les
> interfaces y compris l'IP publique) mais **totalement vierge de configuration**
> (`named.conf.local` vide) et installé le 2026-07-21, avant le début de ce projet —
> vestige de l'image de base Online/Scaleway, sans rapport avec cette stack. Non
> exploitable depuis l'extérieur (iptables ne laisse passer le port 53 que depuis
> 10.42.0.0/24). Rien à reproduire ici, mais si un futur `apt upgrade`/audit le
> remarque, ce n'est pas une régression.

### 3.3 Terraform — VM/LXC (sans NetBox pour l'instant)

`terraform/netbox.tf` va échouer tant que NetBox n'existe pas (voir §3.7) — scoper le
premier apply aux ressources Proxmox uniquement :

```bash
cd terraform
export TF_VAR_proxmox_api_token=$(cat ../secrets/proxmox_api_token.txt)
terraform init
terraform apply \
  -target=proxmox_download_file.debian_cloud_image \
  -target=proxmox_virtual_environment_vm.debian_template \
  -target=proxmox_download_file.debian_lxc_template \
  -target=proxmox_virtual_environment_vm.k3s \
  -target=proxmox_virtual_environment_container.this
```

Recrée le template Debian, les 3 VM k3s et les 2 LXC (teleport, iam) avec les mêmes
IP que toujours (`terraform/vms.tf`, `terraform/containers.tf`).

### 3.4 Ansible — inventaire de secours

**Problème non résolu par ce document** (voir §4) : l'inventaire Ansible par défaut
(`ansible/inventory/netbox.yml`) interroge NetBox, qui n'existe pas encore à ce stade
(il tourne dans k3s, qui vient d'être recréé vide). Écrire à la main un inventaire
temporaire le temps du premier tour :

```yaml
# /tmp/inventory-secours.yml — à jeter une fois NetBox revenu (§3.8)
all:
  vars:
    ansible_user: admin
k3s_server:
  hosts:
    k3s-adm: { ansible_host: 10.42.0.11 }
k3s_agents:
  hosts:
    k3s-w1: { ansible_host: 10.42.0.21 }
    k3s-w2: { ansible_host: 10.42.0.22 }
teleport:
  vars: { is_container: true }
  hosts:
    teleport: { ansible_host: 10.42.0.5 }
iam:
  vars: { is_container: true }
  hosts:
    iam: { ansible_host: 10.42.0.6 }
k3s_cluster:
  children: { k3s_server: {}, k3s_agents: {} }
```

```bash
cd ansible
ansible-playbook site.yml -i /tmp/inventory-secours.yml \
  -e keycloak_db_password="$(cat ../secrets/keycloak_db_password.txt)" \
  -e gandi_api_token="$(cat ../secrets/gandi.token)"
  # + toute autre var sensible que site.yml réclame (relire les erreurs, elles
  # nomment la variable manquante une par une)
```

Ça réinstalle base/Keycloak/Teleport/k3s/dns-interne sur les 5 machines fraîches.

### 3.5 Keycloak — le realm n'est pas scripté

Le rôle Ansible `keycloak` installe le binaire, Postgres, nginx, lego et bootstrap
l'admin du realm `master` — **rien de plus**. Le realm `infra`, ses clients OIDC et ses
groupes ont été créés à la main via l'API admin REST pendant le déploiement initial et
ne sont nulle part en code. À recréer manuellement (`https://sso.aetheriscloud.fr/admin`,
accessible uniquement depuis le WG) :

- Realm : `infra`
- Groupe : `infra-admins` (+ un `client-<name>` par futur tenant, Phase 7)
- Clients OIDC confidentiels, un par outil : `argocd`, `harbor`, `grafana`, `gitea`,
  `netbox`, `portal` — chacun avec un mapper de groupe (`groups`, attribut client
  direct, **pas** de scope `groups` dédié — ce realm n'en a pas) et son
  `redirectUris` pointant vers son hostname réel (`https://<outil>.aetheriscloud.fr`
  ou `.teleport.aetheriscloud.fr` selon l'outil, cf. [apps/portal/main.py](apps/portal/main.py)
  pour la liste à jour)
- **Teleport n'a volontairement pas de client OIDC** : Teleport Community Edition ne
  supporte pas les connecteurs OIDC (Enterprise uniquement) — comptes locaux + WebAuthn
- Les secrets de client générés doivent être reportés dans les `Secret` Kubernetes
  correspondants (`argocd-secret` clé `oidc.keycloak.clientSecret`, etc. — chaque
  `application.yaml` sous `kubernetes/platform/` référence le nom exact)

### 3.6 Bootstrap ArgoCD (manuel, hors GitOps par construction)

```bash
helm repo add argo https://argoproj.github.io/argo-helm
kubectl create namespace argocd
helm install argocd argo/argo-cd --version 10.2.2 -n argocd \
  -f kubernetes/bootstrap/values.yaml
kubectl apply -f kubernetes/bootstrap/app-of-apps.yaml
kubectl apply -f kubernetes/bootstrap/tenants-appset.yaml
```

À partir de là, ArgoCD redéploie automatiquement tout `kubernetes/platform/` (Traefik,
cert-manager + webhook Gandi, Vault, Gitea, Harbor, NetBox, monitoring, portail,
teleport-agent). Tout revient **vide** :

- **Vault** : `vault operator init` génère de nouvelles clés d'unseal + un nouveau root
  token (les anciennes, dans `secrets/vault_init.json`, ne servent plus à rien sur une
  instance vierge) — tous les secrets qu'il contenait sont perdus
- **Harbor** : registre vide. Rebuild + push `apps/portal` depuis son Dockerfile ;
  pour `cert-manager-webhook-gandi`, refaire la recette du README (patch
  `Apikey`→`Bearer` dans `gandiclient.go`, cf. §4)
- **Gitea** : vide, sauf si des dépôts autres que `infra-ac` y étaient hébergés (celui-ci
  reste sur GitHub)

### 3.7 NetBox — repeupler via Terraform

Une fois le pod NetBox `Running` (laisser les migrations Django tourner, ~5 min la
première fois — cf. le bug de resync concurrent documenté dans le workflow) :

```bash
cd terraform
export TF_VAR_netbox_api_token=$(cat ../secrets/netbox_api_token.txt)
terraform apply
```

Recrée site/tenant/rôles/tag/custom field/5 VM+IP+services/prefixes (`terraform/netbox.tf`).
Puis rejouer le job `sync-netbox` (ou `python3 scripts/sync_netbox_tenants.py` en local)
pour les tenants clients réels.

### 3.8 Bascule finale

Une fois NetBox up et repeuplé, l'inventaire dynamique (`ansible/inventory/netbox.yml`,
déjà la config par défaut de `ansible.cfg`) redevient utilisable — jeter
`/tmp/inventory-secours.yml`. Valider : `ansible-inventory --graph` doit retrouver
exactement les mêmes 5 hôtes/groupes qu'avant (déjà testé une fois en conditions
réelles le 2026-08-04, cf. `workflow-deploiement-dedibox.md` §10.4).

## 4. Dette laissée ouverte par ce document

Ce document explique comment reconstruire à la main ce qui ne l'est pas encore. Deux
chantiers identifiés en même temps que cette procédure, pas encore faits :

1. **Committer l'inventaire de secours** (§3.4) en dur dans le repo au lieu de le
   réécrire à la main pendant un incident — supprime le tout premier point de blocage
   circulaire (Ansible dépend de NetBox, NetBox dépend d'Ansible pour exister)
2. **Vendoriser le patch `gandiclient.go`** (§3.6/Harbor) dans ce repo au lieu de le
   laisser en prose dans un README — évite de re-diagnostiquer le même bug
   `Apikey`/`Bearer` si Harbor est perdu
