#!/usr/bin/env pwsh
# Run after apply and before destroy. Requires az CLI read access to both VNets
# and Network Contributor (or equivalent) to invoke the spoke VM run command.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-Output([string]$Name) {
  $result = terraform output -raw $Name
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($result)) {
    throw "Terraform output '$Name' is unavailable."
  }
  return $result.Trim()
}

function Get-AzureJson([string[]]$Arguments) {
  $result = & az @Arguments --output json
  if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI read failed: az $($Arguments -join ' ')"
  }
  return $result | ConvertFrom-Json -Depth 100
}

$connectivitySubscription = Get-Output 'connectivity_subscription_id'
$applicationSubscription = Get-Output 'application_subscription_id'
$hubId = Get-Output 'hub_virtual_network_id'
$opnsenseVmId = Get-Output 'opnsense_vm_id'
$spokeId = Get-Output 'spoke_virtual_network_id'
$hubRg = Get-Output 'connectivity_resource_group_name'
$spokeRg = Get-Output 'spoke_resource_group_name'
$hubPeeringName = Get-Output 'hub_to_spoke_peering_name'
$spokePeeringName = Get-Output 'spoke_to_hub_peering_name'
$nicName = Get-Output 'spoke_test_nic_name'
$vmName = Get-Output 'spoke_test_vm_name'
$expectedHop = Get-Output 'hub_router_ip'
$connectivityObjectId = Get-Output 'connectivity_provider_object_id'
$applicationObjectId = Get-Output 'application_provider_object_id'

if ($connectivitySubscription -eq $applicationSubscription) { throw 'Subscriptions must differ.' }
if ($connectivityObjectId -eq $applicationObjectId) { throw 'Connectivity and Application providers must use different identities.' }
if (-not $hubId.StartsWith("/subscriptions/$connectivitySubscription/", [StringComparison]::OrdinalIgnoreCase)) { throw 'Hub VNet is outside Connectivity subscription.' }
if (-not $opnsenseVmId.StartsWith("/subscriptions/$connectivitySubscription/", [StringComparison]::OrdinalIgnoreCase)) { throw 'OPNsense VM is outside Connectivity subscription.' }
if (-not $spokeId.StartsWith("/subscriptions/$applicationSubscription/", [StringComparison]::OrdinalIgnoreCase)) { throw 'Spoke VNet is outside Application LZ subscription.' }

$hubPeering = Get-AzureJson @('network', 'vnet', 'peering', 'show', '--subscription', $connectivitySubscription, '--resource-group', $hubRg, '--vnet-name', ($hubId -split '/')[-1], '--name', $hubPeeringName)
$spokePeering = Get-AzureJson @('network', 'vnet', 'peering', 'show', '--subscription', $applicationSubscription, '--resource-group', $spokeRg, '--vnet-name', ($spokeId -split '/')[-1], '--name', $spokePeeringName)
foreach ($peering in @($hubPeering, $spokePeering)) {
  if ($peering.peeringState -ne 'Connected') { throw "Peering '$($peering.name)' is $($peering.peeringState), expected Connected." }
  if (-not $peering.allowForwardedTraffic) { throw "Peering '$($peering.name)' does not allow forwarded traffic." }
}
if ($hubPeering.remoteVirtualNetwork.id -ne $spokeId -or $spokePeering.remoteVirtualNetwork.id -ne $hubId) {
  throw 'Peering remote VNet IDs do not match the two owned VNets.'
}

$routes = Get-AzureJson @('network', 'nic', 'show-effective-route-table', '--subscription', $applicationSubscription, '--resource-group', $spokeRg, '--name', $nicName)
$defaultRoute = @($routes.value | Where-Object {
  $_.source -eq 'User' -and
  $_.addressPrefix -contains '0.0.0.0/0' -and
  $_.nextHopType -eq 'VirtualAppliance' -and
  $_.nextHopIpAddress -eq $expectedHop
})
if ($defaultRoute.Count -ne 1) { throw "Expected one user default route via VirtualAppliance $expectedHop; found $($defaultRoute.Count)." }

# The current guest bootstrap has no deterministic post-boot runtime/config
# attestation. Azure VM/CSE provisioning state only proves Stage 1 succeeded;
# it does not prove OPNsense is installed, forwarding, or firewall-ready.
# Keep the packet test unreachable until that proof is implemented and checked.
throw 'BLOCKED: OPNsense post-boot readiness is not deterministically proven. CSE Stage 1 success is not appliance readiness; packet smoke was not run.'

$packet = Get-AzureJson @('vm', 'run-command', 'invoke', '--subscription', $applicationSubscription, '--resource-group', $spokeRg, '--name', $vmName, '--command-id', 'RunShellScript', '--scripts', 'set -e; curl -fsS --connect-timeout 10 --max-time 30 https://www.microsoft.com/ >/dev/null; echo OPNSENSE010_PACKET_OK')
if ((@($packet.value.message) -join "`n") -notmatch 'OPNSENSE010_PACKET_OK') {
  throw 'Packet smoke from the spoke VM failed.'
}

Write-Host '010 dual-subscription ownership, peering, forwarded traffic, effective route, and packet smoke passed.'
