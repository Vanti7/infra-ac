provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  ssh {
    agent    = false
    username = "root"
  }
}

provider "netbox" {
  server_url = var.netbox_server_url
  api_token  = var.netbox_api_token
}
