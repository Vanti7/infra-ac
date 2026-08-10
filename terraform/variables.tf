variable "proxmox_endpoint" {
  description = "URL de l'API Proxmox, joignable via WireGuard (Phase 1.3)"
  type        = string
  default     = "https://10.99.0.1:8006/"
}

variable "proxmox_api_token" {
  description = "Token terraform@pve!iac (Phase 2.1) — passer via TF_VAR_proxmox_api_token, jamais en dur ici"
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Ignorer la vérification du certificat TLS auto-signé de PVE"
  type        = bool
  default     = true
}

variable "proxmox_node" {
  description = "Nom du nœud Proxmox (hostname défini à l'installation)"
  type        = string
  default     = "pve"
}

variable "ssh_public_key" {
  description = "Clé publique SSH injectée via cloud-init (user admin, pas de mot de passe)"
  type        = string
}

variable "vm_network_bridge" {
  description = "Bridge réseau interne (Phase 1.2)"
  type        = string
  default     = "vmbr1"
}

variable "vm_network_gateway" {
  description = "Passerelle du réseau interne 10.42.0.0/24"
  type        = string
  default     = "10.42.0.1"
}

variable "ssh_private_key_path" {
  description = "Chemin vers la clé privée SSH admin, utilisée pour le bootstrap post-création des LXC (création user admin, désactivation root)"
  type        = string
  default     = "../secrets/ssh/vm_admin"
}

variable "datastore_id" {
  description = "Datastore ZFS pour disques VM/LXC"
  type        = string
  default     = "local-zfs"
}

variable "netbox_server_url" {
  description = "URL publique de NetBox (Phase 10)"
  type        = string
  default     = "https://netbox.aetheriscloud.fr"
}

variable "netbox_api_token" {
  description = "Token API NetBox (compte terraform, permissions CMDB) — passer via TF_VAR_netbox_api_token, jamais en dur ici"
  type        = string
  sensitive   = true
}
