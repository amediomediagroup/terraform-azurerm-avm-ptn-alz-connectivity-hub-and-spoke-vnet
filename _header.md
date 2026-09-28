# Azure Landing Zones Platform Landing Zone Connectivity with Hub and Spoke Virtual Network

This module deploys a hub and spoke virtual network topology aligned to the Azure Landing Zones (ALZ) and Microsoft Cloud Adoption Framework (CAF) for Azure. The module is designed to be used in conjunction with the [Azure Verified Modules](https://aka.ms/AVM) initiative and is part of the [Microsoft Cloud Adoption Framework Azure Landing Zones](https://aka.ms/alz).

This module is leveraged by the [Azure Landing Zones IaC Accelerator](https://aka.ms/alz), head over there to learn more. It is part of the Azure Verified Modules for Platform Landing Zone (ALZ) set of modules.

> **Deprecation notice:** The `id` attribute on entries of the curated `virtual_networks` output (exposed by the `hub-virtual-network-mesh` submodule and consumed internally by this root module) is deprecated in favour of `resource_id` and will be removed in a future major version. New code should read `module.<name>.virtual_networks[<key>].resource_id` or use the top-level `resource_id` map output.

## Managed OPNsense NVA (Aegis fork extension)

Set `enabled_resources.opnsense_nva = true` inside a hub entry and optionally
provide `opnsense_nva.subnet.address_prefix` plus supported VM/image/bootstrap
overrides. The root module creates the NVA subnet and appliance, derives one
static router IP from `subnet.router_host` (default `4`), and supplies that IP
to its existing hub route model. It also enables the root-owned NAT Gateway
needed for bootstrap egress. Azure Firewall and Firewall Policy remain enabled
by default for legacy hubs; OPNsense mode disables them when omitted and fails
if either is explicitly enabled.

When the OPNsense prefix is omitted, the root can reuse the reserved
`hub_virtual_network.subnets["opnsense_nva"].address_prefixes[0]`. It does not
invent a CIDR. A caller-owned SSH public key is required in managed mode; no
private key is generated or stored by the module. Existing configurations that
omit OPNsense retain the upstream behavior. See
[`examples/opnsense-010-hub-spoke`](examples/opnsense-010-hub-spoke) for the
dual-subscription Application LZ boundary. Its live acceptance is currently
**BLOCKED** because CSE Stage 1 does not prove post-boot OPNsense runtime and
forwarding readiness; do not treat route state or a fixed delay as proof.
