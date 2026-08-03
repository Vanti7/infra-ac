resource "proxmox_download_file" "debian_lxc_template" {
  content_type = "vztmpl"
  datastore_id = "local"
  node_name    = var.proxmox_node
  url          = "http://download.proxmox.com/images/system/debian-13-standard_13.6-1_amd64.tar.zst"
}

locals {
  containers = {
    teleport = { vm_id = 105, ip = "10.42.0.5/24", cores = 2, memory = 2048, disk_size = 10 }
    iam      = { vm_id = 106, ip = "10.42.0.6/24", cores = 2, memory = 3072, disk_size = 20 }
  }
}

resource "proxmox_virtual_environment_container" "this" {
  for_each = local.containers

  node_name    = var.proxmox_node
  vm_id        = each.value.vm_id
  unprivileged = true
  started      = true

  initialization {
    hostname = each.key

    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = var.vm_network_gateway
      }
    }

    dns {
      servers = ["62.210.16.6", "62.210.16.7"]
    }

    user_account {
      keys = [var.ssh_public_key]
    }
  }

  disk {
    datastore_id = var.datastore_id
    size         = each.value.disk_size
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
  }

  network_interface {
    name   = "eth0"
    bridge = var.vm_network_bridge
  }

  operating_system {
    template_file_id = proxmox_download_file.debian_lxc_template.id
    type              = "debian"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "apt-get update",
      "apt-get install -y sudo",
      "id -u admin >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo admin",
      "mkdir -p /home/admin/.ssh",
      "cp /root/.ssh/authorized_keys /home/admin/.ssh/authorized_keys",
      "chown -R admin:admin /home/admin/.ssh",
      "chmod 700 /home/admin/.ssh",
      "chmod 600 /home/admin/.ssh/authorized_keys",
      "echo 'admin ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/admin",
      "chmod 440 /etc/sudoers.d/admin",
      "sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config",
      "systemctl reload ssh || service ssh reload",
    ]

    connection {
      type        = "ssh"
      host        = split("/", each.value.ip)[0]
      user        = "root"
      private_key = file(var.ssh_private_key_path)
    }
  }
}
