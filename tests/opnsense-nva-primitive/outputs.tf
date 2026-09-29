
# -----------------------------------------------------------------------------
# OPNsense NVA
# -----------------------------------------------------------------------------

output "opnsense_vm_id" {
  value       = module.opnsense.resource_id
  description = "The resource ID of the OPNsense virtual machine."
}

output "opnsense_nic_id" {
  value       = module.opnsense.nic_id
  description = "The resource ID of the OPNsense network interface."
}

output "opnsense_private_ip" {
  value       = module.opnsense.private_ip_address
  description = "The private IP address of the OPNsense NVA. Used as next-hop in route tables."
}

output "opnsense_source_image_id" {
  value       = local.opnsense_source_image_id
  description = "The gallery image version ID used to deploy OPNsense. Matches opnsense-ce-image-provenance.json."
}

# -----------------------------------------------------------------------------
# Infrastructure
# -----------------------------------------------------------------------------

output "resource_group_name" {
  value       = azapi_resource.rg.name
  description = "The name of the resource group."
}

output "vnet_id" {
  value       = azapi_resource.vnet.id
  description = "The resource ID of the virtual network."
}

output "subnet_nva_id" {
  value       = azapi_resource.subnet_nva.id
  description = "The resource ID of the NVA subnet (snet-nva). Has NAT GW; no UDR."
}

output "subnet_test_id" {
  value       = azapi_resource.subnet_test.id
  description = "The resource ID of the test subnet (snet-test). Has UDR routing via NVA."
}

output "route_table_test_id" {
  value       = azapi_resource.route_table_test.id
  description = "The resource ID of the route table attached to snet-test."
}

output "natgw_id" {
  value       = azapi_resource.natgw.id
  description = "The resource ID of the NAT Gateway providing outbound access for snet-nva."
}

# -----------------------------------------------------------------------------
# Smoke assertion inputs
# Used by CI to assert effective routes and NVA readiness.
# -----------------------------------------------------------------------------

output "test_nic_id" {
  value       = azapi_resource.nic_test.id
  description = "The resource ID of the test NIC in snet-test. Used to query effective routes (requires running VM)."
}

output "test_vm_id" {
  value       = azapi_resource.vm_test.id
  description = "The resource ID of the test VM in snet-test."
}

output "expected_next_hop_ip" {
  value       = local.opnsense_private_ip
  description = "The expected next-hop IP in effective routes for snet-test NICs."
}

output "opnsense_vm_name" {
  value       = module.opnsense.name
  description = "The name of the OPNsense VM. Used by CI to query Boot Diagnostics."
}

output "opnsense_image_version" {
  value       = "26.7"
  description = "OPNsense CE version deployed via gallery image."
}
