# Phase 10.4 : NetBox lui-même devient une ressource Terraform, au même titre que les
# VM/LXC Proxmox qu'il décrit. Un seul `terraform apply` crée la machine réelle (vms.tf/
# containers.tf) ET son enregistrement NetBox (ce fichier), à partir des mêmes valeurs
# name/ip — plus de script one-off à rejouer à la main après coup.

locals {
  # Fusion de local.vms (vms.tf) et local.containers (containers.tf) avec le rôle NetBox
  # attendu par chaque machine. Les slugs des rôles ci-dessous sont ceux consommés par
  # l'inventaire Ansible dynamique (ansible/inventory/netbox.yml) : ne pas renommer sans
  # mettre à jour ce fichier en parallèle.
  netbox_role_by_host = {
    k3s-adm  = "k3s_server"
    k3s-w1   = "k3s_agents"
    k3s-w2   = "k3s_agents"
    teleport = "teleport"
    iam      = "iam"
  }

  netbox_hosts = {
    for name, host in merge(local.vms, local.containers) :
    name => merge(host, { role = local.netbox_role_by_host[name] })
  }

  netbox_role_ids = {
    k3s_server = netbox_device_role.k3s_server.id
    k3s_agents = netbox_device_role.k3s_agents.id
    teleport   = netbox_device_role.teleport.id
    iam        = netbox_device_role.iam.id
  }

  netbox_services = {
    sso-https = {
      host        = "iam"
      port        = 443
      description = "Keycloak (nginx, TLS Let's Encrypt) - sso.aetheriscloud.fr"
    }
    teleport-proxy = {
      host        = "teleport"
      port        = 443
      description = "Teleport proxy (SSH/kube/app_service) - teleport.aetheriscloud.fr"
    }
    k3s-api = {
      host        = "k3s-adm"
      port        = 6443
      description = "API k3s - kube.aetheriscloud.fr"
    }
    traefik-https-w1 = {
      host        = "k3s-w1"
      port        = 443
      description = "Traefik hostPort - *.apps.aetheriscloud.fr"
    }
    traefik-https-w2 = {
      host        = "k3s-w2"
      port        = 443
      description = "Traefik hostPort - *.apps.aetheriscloud.fr"
    }
  }
}

resource "netbox_site" "stargate_px1" {
  name = "Stargate PX1"
  slug = "stargate_px1"
}

resource "netbox_cluster_type" "proxmox_ve" {
  name = "Proxmox VE"
  slug = "proxmox-ve"
}

resource "netbox_cluster" "dedibox" {
  name            = "dedibox"
  cluster_type_id = netbox_cluster_type.proxmox_ve.id
  site_id         = netbox_site.stargate_px1.id
  description     = "Dedibox Start-2-L, hote stargate-px1 (51.15.191.67)"
}

resource "netbox_tenant" "interne" {
  name = "Interne"
  slug = "interne"
}

resource "netbox_device_role" "k3s_server" {
  name      = "k3s server"
  slug      = "k3s_server"
  vm_role   = true
  color_hex = "2196f3"
}

resource "netbox_device_role" "k3s_agents" {
  name      = "k3s agent"
  slug      = "k3s_agents"
  vm_role   = true
  color_hex = "4caf50"
}

resource "netbox_device_role" "teleport" {
  name      = "teleport"
  slug      = "teleport"
  vm_role   = true
  color_hex = "ff9800"
}

resource "netbox_device_role" "iam" {
  name      = "iam"
  slug      = "iam"
  vm_role   = true
  color_hex = "9c27b0"
}

resource "netbox_tag" "managed_by_ansible" {
  name = "managed-by:ansible"
  slug = "managed_by_ansible"
}

resource "netbox_custom_field" "namespace" {
  name          = "namespace"
  label         = "Namespace k8s"
  type          = "text"
  content_types = ["tenancy.tenant"]
  description   = "Namespace Kubernetes du tenant (cust-<name>), posé par le job CI sync-netbox."
}

resource "netbox_virtual_machine" "this" {
  for_each = local.netbox_hosts

  name         = each.key
  cluster_id   = netbox_cluster.dedibox.id
  site_id      = netbox_site.stargate_px1.id
  tenant_id    = netbox_tenant.interne.id
  role_id      = local.netbox_role_ids[each.value.role]
  vcpus        = each.value.cores
  memory_mb    = each.value.memory
  disk_size_mb = each.value.disk_size * 1024
  tags         = [netbox_tag.managed_by_ansible.name]
}

resource "netbox_interface" "eth0" {
  for_each = local.netbox_hosts

  name               = "eth0"
  virtual_machine_id = netbox_virtual_machine.this[each.key].id
}

resource "netbox_ip_address" "primary" {
  for_each = local.netbox_hosts

  ip_address                   = each.value.ip
  status                       = "active"
  virtual_machine_interface_id = netbox_interface.eth0[each.key].id
  description                  = "${each.key} (interne)"
}

resource "netbox_primary_ip" "this" {
  for_each = local.netbox_hosts

  virtual_machine_id = netbox_virtual_machine.this[each.key].id
  ip_address_id      = netbox_ip_address.primary[each.key].id
}

resource "netbox_ip_address" "public" {
  ip_address  = "51.15.191.67/32"
  status      = "active"
  description = "IP publique dedibox (stargate-px1)"
}

resource "netbox_service" "this" {
  for_each = local.netbox_services

  name               = each.key
  protocol           = "tcp"
  ports              = [each.value.port]
  virtual_machine_id = netbox_virtual_machine.this[each.value.host].id
  description        = each.value.description
}

resource "netbox_prefix" "interne" {
  prefix      = "10.42.0.0/24"
  status      = "active"
  description = "Reseau interne VM/LXC (vmbr1, Proxmox)"
}

resource "netbox_prefix" "wireguard" {
  prefix      = "10.99.0.0/24"
  status      = "active"
  description = "WireGuard (site-to-site/peers admin)"
}

resource "netbox_prefix" "k3s_cluster_cidr" {
  prefix      = "10.44.0.0/16"
  status      = "active"
  description = "CIDR pods k3s (cluster-cidr)"
}

resource "netbox_prefix" "k3s_service_cidr" {
  prefix      = "10.43.0.0/16"
  status      = "active"
  description = "CIDR services k3s (service-cidr)"
}
