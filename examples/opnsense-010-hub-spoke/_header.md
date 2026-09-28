# OPNsense 010: Hub-and-Spoke — Landing Zone Acceptance

> **Acceptance status: BLOCKED.** Root-level managed OPNsense wiring and the
> dual-subscription fixture are implemented, but the FreeBSD bootstrap has no
> deterministic post-boot runtime/configuration attestation. Stage 1/CSE success
> does not prove the OPNsense dataplane is ready, so packet smoke is deliberately
> fail-closed and must not be reported as passed.

First public Landing Zone example. Proves that the Aegis fork delivers an
OPNsense-backed hub-spoke topology that reflects actual ALZ ownership
boundaries — not a simplified single-subscription lab.

## Design Proof

**Business requirement:** Centrally inspect and control workload egress traffic
via a custom NVA in a dedicated Connectivity subscription, following the ALZ
hub-spoke topology pattern.

**Architecture decision:** CAF ALZ hub-spoke topology with custom NVA in
Connectivity subscription. Spokes in Application Landing Zone subscriptions.
OPNsense replaces Azure Firewall as the hub router. References:
- [Azure hub-spoke topology](https://learn.microsoft.com/azure/architecture/reference-architectures/hybrid-networking/hub-spoke)
- [CAF ALZ platform landing zones](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/landing-zone/platform-vs-application-landing-zones)

**Ownership:** Hub VNet, OPNsense, NAT Gateway, routing → platform team
(Connectivity subscription). Spoke VNet, workload resources → application team
(Application LZ subscription). Peering is initiated from the spoke side
(application team needs hub VNet ID published as an output).

**Traffic model:**
```text
spoke VM
  → UDR (0.0.0.0/0 → VirtualAppliance → root-derived 10.1.1.4)
  → VNet peering (spoke→hub, allow_forwarded_traffic=true)
  → OPNsense 10.1.1.4 (hub)
  → destination

Return path (stateful NVA — symmetry required):
destination → OPNsense → VNet peering (hub→spoke) → spoke VM
```

**Failure model:** Single NVA — NVA failure drops egress. Full HA (dual NVA +
ILB + failover) is addressed at `opnsense-040-ha`.

**IaC contract:** `hub_and_spoke_vnet` (Aegis fork) via
`hub_virtual_networks.primary.opnsense_nva`. The Application LZ fixture uses
`Azure/avm-res-network-virtualnetwork/azurerm` v0.22.2 for the spoke and its
peering submodule once per subscription. The `/azurerm` suffix is the module's
Registry namespace; its v0.22.2 networking resources use AzAPI. The existing
connectivity root still requires an AzureRM provider alias for inherited
upstream resources. No Aegis fixture resource uses AzureRM directly.

## Architecture

```text
Connectivity Subscription
  rg-connectivity-010-<suffix>
  │
  └── module hub_and_spoke_vnet (Aegis fork — single call)
        ├── Hub VNet 10.1.0.0/16
        │     └── snet-opnsense-nva 10.1.1.0/27
        │           └── OPNsense 10.1.1.4 (root-derived hub router IP)
        ├── NAT Gateway → snet-opnsense-nva
        └── Route table (user subnets) → 0.0.0.0/0 via 10.1.1.4

Application LZ Subscription
  rg-application-010-<suffix>
  │
  ├── Spoke VNet 10.2.0.0/16
  │     └── snet-workload 10.2.0.0/24
        │           UDR: 0.0.0.0/0 → 10.1.1.4
  │
  ├── VNet peering: spoke → hub (allow_forwarded_traffic=true)
  └── test VM + NIC (for effective-route assertion)

Cross-subscription peering (both directions):
  spoke → hub: Application LZ sub, application team
  hub  → spoke: Connectivity sub, platform team
```

## Provider Model

```hcl
provider "azurerm" {
  alias           = "connectivity"
  subscription_id = var.connectivity_subscription_id
}

module "hub_and_spoke_vnet" {
  source = "../.."  # dev; production: exact Aegis fork tag
  providers = {
    azurerm = azurerm.connectivity
    azapi   = azapi.connectivity
  }
}

module "spoke" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm"
  version = "0.22.2"
  providers = {
    azapi = azapi.application
  }
}
```

## Acceptance Gates (G0–G6)

| Gate | Check |
|------|-------|
| G0 | `terraform plan` on upstream `nva-nat-gatewayv2` example unchanged |
| G1 | Only `module.hub_and_spoke_vnet` call for hub networking; no raw hub VNet/NAT/UDR resources at consumer |
| G2 | Hub VNet, OPNsense subnet, NAT GW, route table owned by root PTN; confirmed via `terraform state show` |
| G3 | OPNsense VM/NIC/CSE not referenced in consumer outputs or spoke configuration |
| G4 | Root-derived OPNsense IP == `spoke_test_nic` effective-route next-hop (`10.1.1.4`) |
| G5 | Both peering sides `Connected`, forwarded traffic enabled, and spoke effective route is `VirtualAppliance` to `hub_router_ip_address` |
| G6 | `source = "../.."` for dev; release consumers pin exact Aegis fork tag |
| G7 | Packet smoke from Application LZ VM follows the NVA route, second plan has zero diff, and destroy leaves no fixture resources in either subscription |

The legacy AzureRM resources inside the inherited upstream root are tracked
as upstream TFFR3 compatibility debt. This example does not claim the entire
fork is TFFR3 compliant; Aegis-added control-plane resources use AzAPI.

After deployment, `pwsh ./Test-Acceptance.ps1` verifies separate provider
identities and subscription ownership, both peerings, forwarded traffic, and
the effective default route, then exits **BLOCKED before packet smoke** until a
deterministic post-boot OPNsense readiness proof is implemented. CSE extension
state is not sufficient. Do not mark the scenario accepted until runtime
readiness, packet path, second-plan zero diff, and destroy all pass. The
generated ALZ platform root uses the same connectivity inputs and provider
mapping, with `count` gated by `connectivity_type` and tags from `module.config`;
this standalone example pins the local fork source and uses fixture tags.

## Next Steps

- `opnsense-020-central-egress`: Prove spoke → NVA → Internet packet path with
  actual traffic capture and source IP verification
- `opnsense-030-east-west`: Spoke A ↔ NVA ↔ Spoke B with symmetry verification
