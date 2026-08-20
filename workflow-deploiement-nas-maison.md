# Workflow d'exécution — NAS maison

> Complément à [`workflow-deploiement-dedibox.md`](./workflow-deploiement-dedibox.md) : couvre le
> serveur de stockage maison (hôte `nas-maison`, hors Dedibox), déployé pour répondre au
> besoin de stockage général (priorité 1) et servir de cible de sauvegarde pour le Dedibox
> (C2 dans `audit-infra-ac.md`, priorité 2). Pas de plan écrit à l'avance comme pour le
> Dedibox — décisions prises au fil de l'installation, documentées ici après coup.

**Légende** : `[x]` fait · `⚠` déviation/incident rencontré

---

## Décisions d'architecture

- **OS : Debian nu**, pas d'OS NAS appliance (TrueNAS SCALE, OpenMediaVault). TrueNAS SCALE
  écarté après calcul : 4 cœurs / 8 Go RAM — TrueNAS SCALE annonce 8 Go comme minimum pour
  l'OS *seul*, ne laissant aucune marge pour l'ARC ZFS + le futur stack SaveOS
  (Postgres/Redis/MinIO/API/worker/web). Cohérent aussi avec le reste du repo : aucun hôte
  n'est géré par une appliance GUI, tout est Debian + Ansible.
- **Stockage : Btrfs, pas ZFS.** ZFS était le choix initial (cohérent avec `local-zfs` côté
  Dedibox) mais abandonné en cours d'install — voir incident Secure Boot ci-dessous.
- **Partage : NFS (serveurs infra, via WireGuard) + Samba (LAN maison, postes perso)**,
  pas de LDAP — un compte de service unique (`svc-nas-share`) suffit au besoin actuel,
  LDAP resterait à évaluer séparément si le nombre de comptes/hôtes à centraliser grandit
  (cf. discussion du 2026-08-18, pas d'urgence identifiée).
- **Disques** : 1 SSD Crucial BX500 1To (SATA) installé et utilisé dès maintenant, aucune
  redondance (même situation que C2 côté Dedibox). 2 disques Dell 600G 15K rpm (SAS
  d'occasion) possédés mais pas câblés — prévus en filesystem Btrfs **séparé** en raid1 une
  fois branchés (tailles/vitesses trop différentes pour les mélanger avec le 1To).

## Chronologie

### Installation Debian
- [x] Clé USB Debian 13 (trixie) netinst, machine ASUS (4C/8G, ex-hôte Proxmox VE réutilisé)
- [x] ⚠ **Résidu LVM de l'ancien Proxmox** : l'installeur affichait un groupe de volumes
  `pve` avec thin pool `data` (LVM-thin, signature du provisioning PVE) sur le disque
  réutilisé. Supprimé via le menu "Configurer le gestionnaire de volumes logiques (LVM)"
  du partitionneur (LV puis VG), avant de pouvoir recréer une table de partitions vierge.
- [x] Partitionnement manuel (pas de LVM, pas de partitionnement assisté) — l'OS et le
  futur volume Btrfs partagent le même disque physique :

  | # | Taille | Type | Point de montage |
  |---|--------|------|-------------------|
  | 1 | 487 Mo | EFI System | `/boot/efi` |
  | 2 | 7,5 Go | swap | — |
  | 3 | 46,6 Go | ext4 | `/` |
  | 4 | 877 Go | non formaté à l'install | réservé — devient le volume Btrfs |

### ⚠ Incident : boot cassé après désactivation du Secure Boot
- Premier reboot post-install → `grub rescue> error: disk lvmid/... not found`. Cause :
  le firmware UEFI garde en NVRAM les entrées de boot de l'ancienne install Proxmox,
  indépendamment de la table de partitions (qu'on avait bien effacée) — au premier reboot
  après avoir touché aux réglages Secure Boot, le firmware est retombé sur l'ancienne
  entrée EFI de Proxmox, qui référence l'ancien LVM `pve` disparu.
- Impossible d'entrer dans le BIOS via `Suppr`/`F8` (Fast Boot ASUS trop agressif, fenêtre
  de saisie clavier quasi inexistante) → résolu par un **Clear CMOS matériel** (bouton
  dédié ou jumper CLRTC sur la carte).
- Une fois de retour dans le BIOS (mode avancé, `F7`), l'option Secure Boot n'était pas
  visible en mode EZ — trouvée sous `Boot → Secure Boot → OS Type: Other OS`.

### ⚠ Incident : Secure Boot bloque ZFS, abandon au profit de Btrfs
- `zfsutils-linux` installé, module DKMS compilé avec succès (`dkms status` : `installed`)
  mais chargement refusé par le noyau : `modprobe: ERROR: could not insert 'zfs': Key was
  rejected by service`. ZFS est un module tiers (licence CDDL, jamais signé par Debian) —
  Secure Boot le rejette.
- Le changement fait dans le BIOS ("OS Type: Other OS") n'a en réalité pas désactivé
  l'application du Secure Boot : `dmesg` du boot suivant affichait toujours
  `secureboot: Secure boot enabled`.
- Tentative de contournement propre : enrôlement MOK (`mokutil --import
  /var/lib/dkms/mok.pub`, mécanisme officiellement supporté par Debian pour ce cas de
  figure). Bloqué à son tour : `mokutil` répond *"This system doesn't support Secure
  Boot"* alors que le noyau, lui, détecte bien Secure Boot actif au boot — la variable EFI
  `SecureBoot` n'est pas exposée correctement en runtime via `efivarfs` sur ce firmware
  (bug/limitation connue sur certaines cartes ASUS grand public). `efibootmgr -v` présente
  la même incohérence (boot entries invisibles alors que `BootOrder` est peuplé).
- **Décision (2026-08-18)** : abandon de ZFS sur cette machine plutôt que de continuer à
  batailler avec un firmware qui ne coopère pas. Bascule sur **Btrfs**, intégré et signé
  avec le noyau Debian officiel (`modinfo btrfs` → `signer: Build time autogenerated
  kernel key`) — chargement testé et confirmé immédiat, aucun réglage firmware requis.
  Rôle Ansible `home-nas` réécrit en conséquence (`mkfs.btrfs` + sous-volumes `data`/
  `backups` au lieu de `zpool create`/`zfs create` ; `btrfs device add` + `btrfs balance
  -dconvert=raid1 -mconvert=raid1` remplace `zpool attach` comme trajectoire d'ajout des 2
  disques Dell plus tard).

### Accès Ansible
- [x] Compte `vanti` créé à l'install n'a pas `sudo` (paquet absent, pas dans le groupe) —
  accès root direct nécessaire pour Ansible.
- [x] Mot de passe root fourni par l'utilisateur non fonctionnel en SSH par mot de passe
  (`PermitRootLogin prohibit-password`, comportement par défaut Debian récent — normal, pas
  un bug). Accès établi via dépôt manuel d'une clé publique dédiée
  (`secrets/ssh/home_nas_root`, gitignored, générée pour l'occasion) dans
  `/root/.ssh/authorized_keys`, fait localement à la console par l'utilisateur.
- [x] IP LAN passée de DHCP dynamique (`.150`) à une réservation statique (`.50`) —
  renouvellement de bail forcé à distance (`ifdown`/`ifup`, `dhclient` absent de cette
  install minimale, `dhcpcd`/`ifupdown` utilisés à la place).
- [x] `inventory/home-nas.yml` activé dans `ansible.cfg` une fois l'IP stable connue.

### ⚠ Contrainte réseau : VLAN management maison
- Le réseau maison a une VLAN 99 dédiée au management, initialement en `10.99.0.0/24` —
  collision exacte avec la plage `10.99.0.0/24` du tunnel WireGuard management
  aetheriscloud (cf. `workflow-deploiement-dedibox.md` Phase 1.3). Aurait cassé le routage
  une fois ce NAS raccordé au VPN (le noyau n'aurait pas pu distinguer trafic LAN local et
  trafic tunnel sur une plage identique). **Résolu le jour même** : VLAN 99 maison
  renumérotée en `10.99.99.0/24` côté box/routeur, par l'utilisateur.
- La sortie WAN (crainte d'un cloisonnement bloquant le handshake UDP/51820) s'est révélée
  être un non-problème : le tunnel s'est monté du premier coup.

### Raccordement au WireGuard management
- [x] Nouveau rôle `wireguard-client` (générique, réutilisable pour tout futur hôte — pas
  spécifique au NAS). La paire de clés est générée **sur** la machine cliente et la clé
  privée n'en sort jamais : rien à stocker dans `secrets.sops.yaml` pour ce rôle. Le rôle
  affiche la clé publique en fin de run, à reporter dans `wireguard_peers` côté serveur
  (`roles/wireguard/defaults/main.yml`).
- [x] NAS raccordé en `10.99.0.6` (`.1` serveur, `.3`/`.4`/`.5` déjà pris par Mac/PC
  boulot/téléphone). Aucune règle firewall à ajouter côté PVE : les règles existantes sont
  déjà en CIDR sur tout `10.99.0.0/24`.
- [x] Vérifié : handshake actif, ping OK vers le serveur WG (`10.99.0.1`) **et** vers le
  réseau interne (`10.42.0.11`).

### ⚠ Deux bugs trouvés en testant un vrai montage NFS (pas en supposant)
- **Export sur le mauvais réseau** : `/etc/exports` n'autorisait que `10.99.0.0/24` (le
  réseau WireGuard). Or les serveurs qui monteront réellement ce NAS (nœuds k3s, CT) vivent
  sur `10.42.0.0/24` et leur trafic n'est **pas** NATé vers le tunnel — ils gardent leur IP
  réelle `10.42.0.x`. Résultat : `mount.nfs: access denied by server`. Corrigé : les deux
  réseaux sont désormais listés (`home_nas_nfs_allowed_networks`).
- **`root_squash` empêche l'écriture** : une fois le montage accepté, `touch` échouait en
  `Permission denied` — `root_squash` (volontairement conservé) mappe le root distant sur
  `nobody`, qui n'a rien à faire dans un répertoire `0755` appartenant à root. Sous-volumes
  passés en `0777` **à titre temporaire** : le compte de service qui écrira vraiment dépend
  du moteur de backup, pas encore choisi. À resserrer à ce moment-là. L'accès reste
  restreint au niveau réseau (WireGuard uniquement).
- [x] Montage + écriture + démontage revérifiés depuis `k3s-adm` après correction : OK.

### Rôle Ansible `home-nas`
- [x] Créé : `ansible/roles/home-nas/` (Btrfs + NFS + Samba), inventaire statique
  `inventory/home-nas.yml`, `group_vars/home_nas.yml`, secret `home_nas_samba_password`
  dans `group_vars/all/secrets.sops.yaml`. Lint propre (`ansible-lint`, profil production).
- [x] Compte Samba dédié `svc-nas-share` (nomenclature `svc-` pour tous les comptes de
  service de l'infra, décidée à cette occasion — à appliquer aux futurs comptes de service
  similaires).
- [x] Joué avec succès contre `nas-maison` : socle commun (`base`) + `home-nas`
  (formatage Btrfs, sous-volumes `data`/`backups`, exports NFS, partage Samba).

### Intégration Teleport (2026-08-19)
- [x] Le NAS rejoint le play `teleport-agent` de `site.yml` (`hosts:
  k3s_cluster:iam:home_nas`) — shell accessible par `tsh ssh root@ACNAS`,
  session auditée comme les autres hôtes. L'agent joint le cluster par le nom
  public `teleport.aetheriscloud.fr:443`, il n'a donc pas besoin du réseau
  interne pour ça. Vérifié : `ACNAS` apparaît dans `tctl nodes ls`.
- [x] ⚠ **Trouvé au passage** : `inventory/terraform.yml` (généré) ne porte
  aucun chemin de clé SSH — le playbook ne fonctionnait que si la clé était
  déjà chargée dans l'agent SSH de la machine d'admin, ce qui aurait échoué
  sur un checkout neuf (contredit I12). `private_key_file` fixé dans
  `ansible.cfg` ; les inventaires statiques utilisant une autre clé
  (`pve-host.yml`, `home-nas.yml`) la surchargent déjà explicitement.

## État à date (2026-08-18)

Machine installée, joignable en SSH par clé, raccordée au WireGuard management
(`10.99.0.6`), stockage Btrfs + partages NFS/Samba opérationnels sur le disque unique.
Montage NFS depuis un vrai nœud k3s vérifié (montage + écriture + démontage). Supervisée
par Zabbix (le play `zabbix-agent` cible `hosts: all`, l'agent est donc parti avec).

Pas encore fait : câblage des 2 disques Dell 600G 15K (toujours pas de câbles), choix du
moteur de sauvegarde (PBS/Veeam/SaveOS — toujours ouvert, c'est le dernier maillon de C2),
resserrement des permissions `0777` des sous-volumes (dépend du choix précédent), rotation
du mot de passe root utilisé pour l'accès initial.

Voir [`exploitation.md`](./exploitation.md) pour l'usage courant (accès, ajout de
sous-volume, etc.).
