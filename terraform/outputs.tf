output "vm_ips" {
  description = "IP des VMs k3s par nom"
  value       = { for name, vm in local.vms : name => vm.ip }
}

output "container_ips" {
  description = "IP des LXC par nom"
  value       = { for name, ct in local.containers : name => ct.ip }
}
