# Ansible — variables requises

I12 (audit) : ce fichier liste tout ce qu'il faut avoir en place avant de lancer
`ansible-playbook site.yml` sur un checkout neuf. La plupart des rôles ont des
valeurs par défaut raisonnables (`roles/*/defaults/main.yml`) — seules les vraies
variables **à fournir** sont listées ici.

## Prérequis

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install ansible
ansible-galaxy collection install -r requirements.yml
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt   # macOS : pas de découverte auto du chemin par défaut
```

## Secrets (chiffrés, `group_vars/all/secrets.sops.yaml`)

Éditer avec `sops --config /dev/null group_vars/all/secrets.sops.yaml` (déchiffre dans
un éditeur, ré-encrypte à la sauvegarde). Clés attendues :

| Variable | Utilisée par | Où l'obtenir |
|---|---|---|
| `gandi_api_token` | `keycloak` (lego DNS-01), `cert-manager` (cluster) | Gandi → Compte → API Gandi Domain |
| `keycloak_admin_password` | `keycloak` | choisie à la création (`kcadm`/bootstrap-admin) |
| `keycloak_db_password` | `keycloak` | choisie à la création (rôle Postgres `keycloak`) |
| `k3s_token` | `k3s-adm`, `k3s-agent` | pré-partagé, identique des deux côtés — générer avec `openssl rand -hex 32` |
| `ghcr_pull_token` | `k3s-adm`, `k3s-agent` (`registries.yaml`, pull ghcr.io) | PAT GitHub `read:packages` uniquement (jamais le token d'écriture CI) |
| `harbor_pull_token` | `k3s-adm`, `k3s-agent` (`registries.yaml`, pull Harbor) | Robot account Harbor pull-only, projet `aetheriscloud` (cf. `exploitation.md`) |
| `home_nas_samba_password` | `home-nas` (compte Samba `home_nas_samba_user`) | à choisir à l'installation du NAS — pas encore renseigné (§ NAS maison ci-dessous) |

Toutes les tâches qui manipulent ces variables directement (mot de passe Postgres,
bootstrap admin Keycloak, token ACME Gandi, `config.yaml`/`registries.yaml` k3s, jeton
de join Teleport) sont en `no_log: true` — rien de tout ça n'apparaît dans la sortie
Ansible, `--diff` compris.

**PAS de secret statique à fournir** pour le join Teleport : `teleport_join_token`
est généré à la volée par le rôle `teleport-agent` (`tctl tokens add`, TTL 1h, usage
unique) — rien à committer, même chiffré.

## Variables en clair (`group_vars/k3s_cluster.yml`)

| Variable | Rôle |
|---|---|
| `k3s_version` | version k3s à installer (`k3s-adm`/`k3s-agent`) |
| `k3s_server_url` | URL WG de l'apiserver, utilisée pour réécrire le kubeconfig local récupéré |
| `k3s_registry_host` | NodePort du registre de packages Gitea (`10.42.0.11:30300`), plain HTTP |
| `ghcr_pull_username` | nom d'utilisateur associé à `ghcr_pull_token` (le token seul est secret) |
| `harbor_pull_username` | nom du robot account associé à `harbor_pull_token` |

## Inventaire

`ansible.cfg` pointe sur `inventory/terraform.yml,inventory/pve-host.yml` (liste
explicite, pas le dossier `inventory/` entier — `inventory/netbox.yml` est un plugin
dynamique qui échoue bruyamment sans `NETBOX_TOKEN`, gardé pour usage manuel
ponctuel uniquement, cf. son propre en-tête).

- `inventory/terraform.yml` : généré par `terraform apply -target=local_file.ansible_inventory`
  (jamais édité à la main — écrasé au prochain apply)
- `inventory/pve-host.yml` : statique, l'hôte PVE lui-même (`stargate-px1`) n'est pas
  provisionné par Terraform. **N'est ciblé que par le rôle `zabbix-agent`** — I13
  (rôles Ansible pour l'hôte PVE : `base-pve`, `firewall`, `wireguard`, `haproxy`)
  n'est pas fait, `site.yml` exclut volontairement `pve_host` des plays `base` et
  `dns-interne` pour ne pas faire converger l'hyperviseur vers un rôle jamais
  pensé pour lui en side-effect d'un ajout ponctuel.
- `inventory/home-nas.yml` : statique, même principe que `pve-host.yml` (hôte hors
  NetBox). **Volontairement pas encore listé dans `inventory` ci-dessus** — voir
  section "NAS maison" plus bas, c'est le dernier maillon à activer une fois la
  machine installée.

## NAS maison (`home_nas`)

Rôle `home-nas` (ZFS + NFS + Samba) prêt et branché dans `site.yml`, mais **inerte**
tant que la machine physique n'existe pas encore côté Ansible — au 2026-08-18, elle
n'a même pas Debian installé. Rien ne s'exécute nulle part tant que les 3 étapes
suivantes n'ont pas été faites, dans l'ordre, une fois l'accès SSH local obtenu :

1. Renseigner `ansible_host` (et au besoin `ansible_ssh_private_key_file`) dans
   `inventory/home-nas.yml`.
2. Renseigner `home_nas_zpool_disks` (chemins `/dev/disk/by-id/...`, sans le
   préfixe), `home_nas_samba_allowed_network` et `home_nas_samba_user` dans
   `group_vars/home_nas.yml`, plus `home_nas_samba_password` dans
   `group_vars/all/secrets.sops.yaml`. Le rôle refuse de tourner (assert) tant
   que les 3 premières sont vides.
3. Ajouter `,inventory/home-nas.yml` à la ligne `inventory` de `ansible.cfg`.

Stockage actuel : 1 disque de 1To (vdev simple, `home_nas_zpool_mode: ""`, aucune
redondance — même situation que C2 côté Dedibox). 2 disques Dell 600G 15K rpm
possédés mais pas encore câblés ; une fois branchés, ils sont prévus en **mirror
séparé** (pas mélangés avec le 1To, tailles/vitesses trop différentes), via
`zpool attach` — pas de perte de données ni de rebuild complet du pool existant.

Le partage NFS (données + backups, vers les serveurs de l'infra) suppose que ce
NAS a rejoint le réseau de management WireGuard (10.99.0.0/24) — pas encore le
cas, ça dépend de I13 (rôle `wireguard`, pas écrit). Le partage Samba (poste perso,
LAN) est indépendant de ça et fonctionnera dès l'installation.

## Premier lancement

```bash
ansible-playbook site.yml --check --diff   # dry-run, aucun -e manuel requis
ansible-playbook site.yml
```
