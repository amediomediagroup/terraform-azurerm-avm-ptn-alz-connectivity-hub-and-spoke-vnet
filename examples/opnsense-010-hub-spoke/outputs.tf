# -----------------------------------------------------------------------------
# Connectivity (hub) outputs — published by root module, platform team
# -----------------------------------------------------------------------------

output "hub_virtual_network_resource_ids" {
  value       = module.hub_and_spoke_vnet.virtual_network_resource_ids
  description = "Hub VNet resource IDs keyed by hub name. Published so application teams can initiate spoke peering."
}

output "hub_virtual_network_id" {
  value       = module.hub_and_spoke_vnet.virtual_network_resource_ids["primary"]
  description = "Primary Connectivity hub VNet resource ID for acceptance checks."
}

output "connectivity_subscription_id" {
  value       = var.connectivity_subscription_id
  description = "Connectivity subscription ID used by this example."
}

output "application_subscription_id" {
  value       = var.application_subscription_id
  description = "Application LZ subscription ID used by this example."
}

output "hub_virtual_network_resource_names" {
  value       = module.hub_and_spoke_vnet.virtual_network_resource_names
  description = "Hub VNet names keyed by hub name."
}

# -----------------------------------------------------------------------------
# Application LZ (spoke) outputs — owned by workload team
# -----------------------------------------------------------------------------

output "spoke_virtual_network_id" {
  value       = module.spoke.resource_id
  description = "Spoke VNet resource ID (Application LZ subscription)."
}

output "spoke_resource_group_name" {
  value       = azapi_resource.rg_application.name
  description = "Spoke resource group name (Application LZ subscription)."
}

# -----------------------------------------------------------------------------
# Smoke assertion inputs — CI use only
# -----------------------------------------------------------------------------

output "hub_router_ip" {
  value       = module.hub_and_spoke_vnet.hub_router_ip_addresses["primary"]
  description = "Canonical hub router / NVA IP derived by the connectivity root. Used by CI to assert effective routes on spoke NICs."
}

output "opnsense_vm_id" {
  value       = module.hub_and_spoke_vnet.opnsense_nva_resource_ids["primary"]
  description = "Connectivity-root-owned OPNsense VM resource ID."
}

output "spoke_test_nic_id" {
  value       = azapi_resource.spoke_test_nic.id
  description = "Test NIC ID in spoke subnet. Used by CI to query effective routes (requires running VM)."
}

output "spoke_test_nic_name" {
  value       = azapi_resource.spoke_test_nic.name
  description = "Test NIC name in spoke subnet."
}

output "spoke_test_vm_name" {
  value       = azapi_resource.spoke_test_vm.name
  description = "Application LZ VM name for packet smoke testing."
}

output "spoke_to_hub_peering_name" {
  value       = module.spoke_to_hub.name
  description = "Application-owned peering name."
}

output "hub_to_spoke_peering_name" {
  value       = module.hub_to_spoke.name
  description = "Connectivity-owned peering name."
}

output "connectivity_resource_group_name" {
  value       = azapi_resource.rg_connectivity.name
  description = "Connectivity resource group name. Used by CI for extension assertions."
}

output "connectivity_provider_object_id" {
  value       = data.azapi_client_config.connectivity.object_id
  description = "Object ID of the identity that deployed Connectivity resources."
}

output "application_provider_object_id" {
  value       = data.azapi_client_config.application.object_id
  description = "Object ID of the identity that deployed Application LZ resources."
}
