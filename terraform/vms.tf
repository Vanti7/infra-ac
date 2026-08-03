locals {
  vms = {
    k3s-adm    = { vm_id = 111, ip = "10.42.0.11/24", cores = 2, memory = 3072, disk_size = 30 }
    k3s-w1     = { vm_id = 121, ip = "10.42.0.21/24", cores = 4, memory = 8192, disk_size = 60 }
    k3s-w2     = { vm_id = 122, ip = "10.42.0.22/24", cores = 4, memory = 8192, disk_size = 60 }
  }
}

resource "proxmox_virtual_environment_vm" "k3s" {
  for_each = local.vms

  node_name = var.proxmox_node
  vm_id     = each.value.vm_id
  name      = each.key

  clone {
    vm_id = proxmox_virtual_environment_vm.debian_template.vm_id
    full  = true
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = each.value.disk_size
  }

  network_device {
    bridge = var.vm_network_bridge
  }

  initialization {
    datastore_id = var.datastore_id
    interface    = "ide2"

    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = var.vm_network_gateway
      }
    }

    user_account {
      username = "admin"
      keys     = [var.ssh_public_key]
    }
  }

  agent {
    enabled = true
  }
}
