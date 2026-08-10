# Casse la dépendance circulaire NetBox ↔ inventaire Ansible (NetBox tourne dans k3s,
# k3s a besoin d'Ansible pour exister — donc un inventaire qui ne dépend QUE de NetBox
# ne peut jamais amorcer un cluster neuf). Terraform ne dépend que de Proxmox, donc c'est
# lui la vraie source de vérité pour "quelles machines existent" — cet inventaire est
# généré à partir des mêmes données que celles poussées vers NetBox (local.netbox_hosts,
# netbox.tf), pas une source séparée qui pourrait diverger.

locals {
  ansible_inventory = {
    all = {
      vars = { ansible_user = "admin" }
    }
    k3s_server = {
      hosts = {
        for name, h in local.netbox_hosts : name => { ansible_host = split("/", h.ip)[0] }
        if h.role == "k3s_server"
      }
    }
    k3s_agents = {
      hosts = {
        for name, h in local.netbox_hosts : name => { ansible_host = split("/", h.ip)[0] }
        if h.role == "k3s_agents"
      }
    }
    teleport = {
      vars = { is_container = true }
      hosts = {
        for name, h in local.netbox_hosts : name => { ansible_host = split("/", h.ip)[0] }
        if h.role == "teleport"
      }
    }
    iam = {
      vars = { is_container = true }
      hosts = {
        for name, h in local.netbox_hosts : name => { ansible_host = split("/", h.ip)[0] }
        if h.role == "iam"
      }
    }
    k3s_cluster = {
      children = {
        k3s_server = {}
        k3s_agents = {}
      }
    }
  }
}

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory/terraform.yml"
  content         = yamlencode(local.ansible_inventory)
  file_permission = "0644"
}
