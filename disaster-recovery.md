# Reprise après sinistre — aetheriscloud (hors backup)

> Scénario couvert : l'hôte Proxmox (`stargate-px1`, 51.15.191.67) crashe et se corrompt —
> disque mort, réinstallation nécessaire. **La Phase 8 (backups) n'est pas faite** : ce
> document décrit comment reconstruire l'architecture depuis le code, pas comment
> récupérer les données. Tout ce qui n'est que dans une base de données vivante
> (Gitea, Harbor, NetBox, sessions Keycloak) est considéré perdu — c'est le risque
> explicitement accepté en attendant que le NAS maison soit prêt.
>
> Écrit le 2026-08-04 en auditant l'état réel de la stack (configs live relues sur
> l'hôte, pas juste le plan de déploiement) — corrige au passage plusieurs écarts entre
> ce que `plan-deploiement-dedibox.md` décrit et ce qui tourne réellement. Révisé le
> 2026-08-10 suite à l'audit `audit-infra-ac.md` : Vault retiré (C5), inventaire Ansible
> découplé de NetBox (C4), secrets Ansible/k8s chiffrés SOPS/ksops (C3) — la procédure
> ci-dessous est plus courte qu'avant, pas juste corrigée.

## 0. Le vrai point de rupture : `secrets/` + la clé age

Rien de ce qui suit n'est possible sans le dossier `secrets/` de ce repo (gitignored,
**uniquement sur ce Mac**, jamais copié ailleurs). Avant de commencer, vérifier qu'on a
toujours accès à :

- `proxmox_api_token.txt`, `gandi.token` — pour Terraform et le renouvellement TLS
- `ssh/dedibox_root`, `ssh/vm_admin` — accès root à l'hôte et admin aux VM/LXC
- `wg_mac_private.key` (+ la conf WireGuard côté Mac) — sans ça, plus aucun accès admin
  au réseau interne (10.42.0.0/24), ni SSH, ni UI Proxmox, ni Keycloak `/admin`
- `keycloak_admin_password.txt`
- `netbox_api_token.txt`, `github.token`/`ghcr_pull_token.txt`

**La clé age privée** (`~/.config/sops/age/keys.txt`, hors de `secrets/` — générée en
Phase 0, sauvegardée hors-machine dans une note Bitwarden) mérite une mention à part :
depuis C3 (audit), c'est elle qui déchiffre **tout** — `ansible/group_vars/all/secrets.sops.yaml`
(gandi/keycloak/k3s/ghcr) **et** tout `kubernetes/secrets/*.enc.yaml` via ksops côté
ArgoCD. Elle doit être redéployée à **deux** endroits distincts sur une reconstruction,
détaillé en §3.4 et §3.6 — vérifier maintenant, avant d'en avoir besoin, que la note
Bitwarden est toujours à jour et accessible.

Si ce Mac est aussi hors service, ce document ne sert à rien : c'est le vrai single
point of failure du projet, plus critique que Proxmox lui-même.

## 1. Ce qui est perdu (rappel)

- Tous les dépôts hébergés sur Gitea — **sauf ce repo `infra-ac` lui-même**, qui reste
  sur GitHub (`Vanti7/infra-ac`), indépendant de Proxmox
- Toutes les images Harbor — rebuildables depuis le source pour `portal`
  ([apps/portal/Dockerfile](apps/portal/Dockerfile)) et pour `docs-internal`/`docs-public`.
  `cert-manager-webhook-gandi` n'est plus sur Harbor (cf. §3.6/C4) : image publique sur
  `ghcr.io`, mais le code patché lui-même n'est toujours pas vendorisé dans ce repo
  (recette dans [kubernetes/platform/cert-manager/README.md](kubernetes/platform/cert-manager/README.md),
  dette ouverte, cf. §4)
- L'IPAM NetBox au-delà de ce que `terraform/netbox.tf` sait recréer (tout ce qui a été
  ajouté à la main par la suite, un vrai tenant client par exemple)
- Les comptes/sessions Keycloak au-delà de la structure du realm (à recréer, cf. §3.5)
- Dashboards Grafana, historique Prometheus/Alertmanager
- Rien côté secrets applicatifs courants : les 12 principaux (DB Gitea, OIDC de chaque
  appli, admin Harbor/NetBox/Grafana, token Gandi...) sont chiffrés dans
  `kubernetes/secrets/` (ksops, C3) et reviennent automatiquement avec ArgoCD (§3.6).
  Ce qui reste hors ksops par choix : `sops-age-key` (redéployée à la main, §3.4/§3.6)
  et le join token Teleport (éphémère, régénéré à chaque run, §3.4)

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

### 3.3 Terraform — VM/LXC + inventaire Ansible

`terraform/netbox.tf` va échouer tant que NetBox n'existe pas (voir §3.7) — scoper le
premier apply aux ressources Proxmox **et** au générateur d'inventaire (`local_file`,
qui ne dépend que de `local.netbox_hosts`, pas de NetBox lui-même) :

```bash
cd terraform
export TF_VAR_proxmox_api_token=$(cat ../secrets/proxmox_api_token.txt)
terraform init
terraform apply \
  -target=proxmox_download_file.debian_cloud_image \
  -target=proxmox_virtual_environment_vm.debian_template \
  -target=proxmox_download_file.debian_lxc_template \
  -target=proxmox_virtual_environment_vm.k3s \
  -target=proxmox_virtual_environment_container.this \
  -target=local_file.ansible_inventory
```

Recrée le template Debian, les 3 VM k3s et les 2 LXC (teleport, iam) avec les mêmes
IP que toujours (`terraform/vms.tf`, `terraform/containers.tf`), **et** génère
`ansible/inventory/terraform.yml` — déjà l'inventaire par défaut de `ansible.cfg`.
Plus besoin d'inventaire de secours à écrire à la main (l'ancien piège circulaire
NetBox↔Ansible : voir §4, résolu).

### 3.4 Déployer la clé age (1/2) + Ansible

Restaurer `~/.config/sops/age/keys.txt` depuis la note Bitwarden sur le poste admin
(`chmod 600`), et vérifier que `SOPS_AGE_KEY_FILE` pointe dessus (normalement déjà dans
`~/.zshrc`, cf. Phase 0 — sops ne cherche pas ce chemin par défaut sur macOS,
contrairement à Linux). Sans ça, `community.sops` ne peut rien déchiffrer et
`ansible-playbook` échouera sur `gandi_api_token`/`keycloak_admin_password`/
`keycloak_db_password`/`k3s_token`/`ghcr_pull_token` — undefined.

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml   # community.sops, netbox.netbox
ansible-playbook site.yml
```

Plus aucun `-e` à passer à la main : les 4 secrets Ansible + `ghcr_pull_token` viennent
de `group_vars/all/secrets.sops.yaml`, déchiffré à la volée par `community.sops`
(vars plugin, activé dans `ansible.cfg`). Ça réinstalle base/Keycloak/Teleport/k3s/
dns-interne sur les 5 machines fraîches, containerd déjà configuré pour puller
`ghcr.io` (webhook Gandi, cf. §3.6).

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

### 3.6 Déployer la clé age (2/2) + bootstrap ArgoCD (manuel, hors GitOps par construction)

Le repo-server ArgoCD monte la clé age via un Secret Kubernetes (`sops-age-key`,
namespace `argocd`) — **il doit exister avant le premier démarrage du repo-server**,
sinon le pod reste en erreur de montage de volume. C'est la deuxième (et dernière)
fois qu'on touche à cette clé pendant toute la reconstruction :

```bash
helm repo add argo https://argoproj.github.io/argo-helm
kubectl create namespace argocd
kubectl -n argocd create secret generic sops-age-key \
  --from-file=keys.txt=~/.config/sops/age/keys.txt
helm install argocd argo/argo-cd --version 10.2.2 -n argocd \
  -f kubernetes/bootstrap/values.yaml
kubectl apply -f kubernetes/bootstrap/app-of-apps.yaml
kubectl apply -f kubernetes/bootstrap/tenants-appset.yaml
```

`kubernetes/bootstrap/values.yaml` contient déjà toute la config ksops (initContainer,
volumes, `SOPS_AGE_KEY_FILE`) — rien à ajouter ici, c'est le même fichier que celui
utilisé au quotidien.

À partir de là, ArgoCD redéploie automatiquement tout `kubernetes/platform/` (Traefik,
cert-manager + webhook Gandi, Gitea, Harbor, NetBox, monitoring, portail,
teleport-agent, docs-internal/docs-public) **et** `kubernetes/secrets/` (Application
dédiée `secrets` — tous les secrets déjà migrés en ksops reviennent déchiffrés et
identiques automatiquement, cf. §4 pour l'état de la migration). Ce qui revient
**vide** malgré tout :

- **Harbor** : registre vide. Rebuild + push `apps/portal` et `apps/docs-internal`/
  `apps/docs-public` depuis leurs Dockerfile (voir leurs README respectifs pour la
  méthode podman-sur-k3s-w1, pas de Docker sur le poste admin macOS).
  `cert-manager-webhook-gandi` n'est pas concerné : image publique sur `ghcr.io`,
  pullable dès que `registries.yaml` est en place (§3.4) — mais si le **code** patché
  est perdu, refaire la recette du README (patch `Apikey`→`Bearer` dans
  `gandiclient.go`, cf. §4)
- **Gitea** : vide, sauf si des dépôts autres que `infra-ac` y étaient hébergés (celui-ci
  reste sur GitHub)

Tous les autres secrets applicatifs (DB, OIDC, admin) reviennent **identiques**
automatiquement via l'Application dédiée `secrets` — rien à recréer à la main pour eux.

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
pour les tenants clients réels. L'inventaire Ansible, lui, n'a jamais dépendu de NetBox
(§3.3) — rien à rebasculer, `ansible/inventory/netbox.yml` reste disponible en option
si on veut vérifier que NetBox reflète bien le parc.

## 4. Dette laissée ouverte par ce document

- **Vendoriser le patch `gandiclient.go`** (§3.6) dans ce repo au lieu de le laisser en
  prose dans un README — évite de re-diagnostiquer le même bug `Apikey`/`Bearer` si le
  code source du fork amont disparaît

~~Migration ksops incomplète~~ — faite le 2026-08-10 : 12 secrets applicatifs migrés
(`kubernetes/secrets/`), zéro redémarrage de pod constaté au sync. `argocd-secret`
reste volontairement hors ksops (mélange chart+custom, cf. `kubernetes/secrets/kustomization.yaml`) ;
le client OIDC ArgoCD passe par un secret dédié (`argocd-oidc-secret`) à la place.

~~Committer l'inventaire de secours en dur~~ — fait différemment et mieux : l'inventaire
est maintenant généré par Terraform (`terraform/inventory.tf`), qui ne dépend que de
Proxmox — plus de dépendance circulaire à contourner du tout (§3.3).
