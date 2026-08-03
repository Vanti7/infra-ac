resource "proxmox_download_file" "debian_cloud_image" {
  content_type        = "import"
  datastore_id        = "local"
  node_name           = var.proxmox_node
  url                 = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
  file_name           = "debian-13-genericcloud-amd64.qcow2"
  overwrite_unmanaged = true
}

resource "proxmox_virtual_environment_vm" "debian_template" {
  node_name = var.proxmox_node
  vm_id     = 9000
  name      = "debian-13-genericcloud-template"
  template  = true
  started   = false

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
  }

  network_device {
    bridge = var.vm_network_bridge
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    import_from  = proxmox_download_file.debian_cloud_image.id
    size         = 10
  }

  initialization {
    datastore_id = var.datastore_id
    interface    = "ide2"

    user_account {
      username = "admin"
      keys     = [var.ssh_public_key]
    }
  }

  agent {
    enabled = true
  }

  serial_device {}
}
