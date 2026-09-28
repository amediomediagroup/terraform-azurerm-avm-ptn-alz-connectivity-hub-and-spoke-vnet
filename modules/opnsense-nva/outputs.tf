# -----------------------------------------------------------------------------
# Virtual Machine Outputs
# -----------------------------------------------------------------------------

output "resource_id" {
  value       = azapi_resource.vm.id
  description = "The resource ID of the OPNsense virtual machine."
}

output "name" {
  value       = azapi_resource.vm.name
  description = "The name of the OPNsense virtual machine."
}

output "resource" {
  value       = azapi_resource.vm
  description = "The full AzAPI resource object for the virtual machine."
}

# -----------------------------------------------------------------------------
# Network Interface Outputs
# -----------------------------------------------------------------------------

output "nic_id" {
  value       = azapi_resource.nic.id
  description = "The resource ID of the network interface."
}

output "nic_name" {
  value       = azapi_resource.nic.name
  description = "The name of the network interface."
}

output "private_ip_address" {
  value       = local.private_ip_address
  description = "The private IP address of the OPNsense NVA."
}

# -----------------------------------------------------------------------------
# Computed Outputs for Integration
# -----------------------------------------------------------------------------

output "next_hop_ip_address" {
  value       = local.private_ip_address
  description = "The IP address to use as next-hop in route tables. Alias for private_ip_address."
}
