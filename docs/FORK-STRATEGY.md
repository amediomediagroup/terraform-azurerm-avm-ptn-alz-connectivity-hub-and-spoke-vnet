# Fork Strategy: OPNsense Connectivity Landing Zone

> **Status:** Root managed-OPNsense implementation in progress; `010` live acceptance **BLOCKED** on deterministic post-boot readiness proof.
> **Date:** 2026-09-28
> **Upstream:** Azure/terraform-azurerm-avm-ptn-alz-connectivity-hub-and-spoke-vnet @ v0.17.5

## Decision

Preserve the upstream ALZ Accelerator/root consumer interface. Add managed
OPNsense as an opt-in `enabled_resources.opnsense_nva` feature inside each
`hub_virtual_networks` entry, with optional sibling overrides. The root PTN
dispatches the existing `modules/opnsense-nva` implementation and owns the NVA
subnet, derived canonical router IP, NAT association, and routing integration.
No top-level OPNsense argument or consumer-owned sibling module is introduced.

## Versioning

```text
upstream: v0.17.5   (Terraform Registry latest as of 2026-09-28)
fork:     v0.17.5-aegis.1
```

Source of truth for published version: Terraform Registry (`registry.terraform.io`), not GitHub Releases page — GitHub release cache may lag.

Subsequent additive changes increment the `-aegis.N` suffix:

```text
v0.17.5-aegis.2
v0.17.5-aegis.3
```

Rebase onto new upstream releases:

```text
upstream v0.18.0 → v0.18.0-aegis.1
```

**Note:** SemVer prerelease suffixes sort before the base version (`v0.17.5-aegis.1 < v0.17.5`). This is acceptable—provenance matters more than ordering. Pin via Git ref, not version comparison.

## Scope of Changes

### Allowed

- New submodule: `modules/opnsense-nva/`
- New examples: `examples/opnsense-*/`
- New tests: `tests/opnsense-*/`
- Documentation under `docs/`

### Not Allowed (without justification)

- Root-wide AzureRM → AzAPI migration
- Modifications to existing submodules
- Disabling or modifying upstream tests
- Breaking the root module interface

The minimal, additive root changes required to compose a managed appliance are
allowed. Preserve default behavior for hubs that omit OPNsense; inherited
upstream AzureRM usage remains tracked compatibility debt.

## Upstream Compatibility Gate

Every release must pass:

1. Rebase onto upstream tag
2. All upstream tests pass (unmodified)
3. All upstream examples deploy successfully
4. OPNsense examples pass full test matrix
5. Documentation regenerated via `avm pre-commit`

### Managed OPNsense readiness limitation

The current FreeBSD/CSE bootstrap Stage 1 only prepares bootstrap and requests
a reboot. No deterministic guest-side evidence currently proves that bootstrap
finished and that OPNsense runtime, forwarding, and firewall configuration are
ready. Therefore `010` is **BLOCKED**, and its acceptance script fails closed
before packet smoke. Do not report it as accepted based on CSE provisioning
state, a delay, effective routes, or successful VM provisioning.

If OPNsense changes break upstream tests, **the OPNsense patch is wrong** until proven otherwise.

## Scenario Ladder

Examples follow a progressive complexity model. Each example proves one property:

| Example | Property |
|---------|----------|
| `opnsense-001-single-nva` | VM + NIC + IP forwarding + bootstrap |
| `opnsense-010-hub-spoke` | Hub/spoke + peering + UDR |
| `opnsense-020-central-egress` | Spoke → NVA → Internet |
| `opnsense-030-east-west` | Spoke ↔ NVA ↔ Spoke |
| `opnsense-040-ha` | 2 NVAs + ILB + failover |
| `opnsense-050-private-endpoints` | PE routing + inspection symmetry |
| `opnsense-060-vpn` | P2S/S2S → Hub → NVA |
| `opnsense-070-private-dns` | DNS Resolver integration |
| `opnsense-090-production` | Complete Connectivity Landing Zone |

HA/ILB abstraction is introduced at `040-ha`, not before.

`tests/opnsense-nva-primitive` may use one subscription for fast appliance
mechanics. Every public `010+` Landing Zone scenario uses separate Connectivity
and Application LZ subscriptions. The connectivity root owns the hub and NVA;
an Application LZ fixture owns the spoke. Peering is established from each
subscription with its own provider alias and both sides must allow the
forwarded-traffic behavior required by the route. The `010` fixture pins
`Azure/avm-res-network-virtualnetwork/azurerm` v0.22.2 for its spoke and
peering modules and uses AzAPI for other direct Azure resources. The Registry
suffix is not a direct AzureRM provider resource.

The upstream connectivity root still contains inherited AzureRM resources.
Those remain tracked [upstream TFFR3 debt](https://github.com/Azure/terraform-azurerm-avm-ptn-alz-connectivity-hub-and-spoke-vnet/issues/164); root-wide provider migration is a
separate workstream. Aegis-added resources and fixtures must not add direct
AzureRM control-plane blocks. Do not describe the whole fork as fully TFFR3
compliant while the inherited debt remains.

## Test Matrix

Every OPNsense example must pass six validation layers:

| Layer | Checks |
|-------|--------|
| L1 Source | `terraform fmt`, `terraform validate`, `avm pre-commit`, tflint |
| L2 Plan | No unexpected replacement, correct next-hops, no hardcoded secrets |
| L3 Deploy | Resources healthy, VM boot complete, LB probes up, effective routes correct |
| L4 Packet | Bidirectional flow verification (request + return path) |
| L5 Failure | Kill NVA, break probe, remove route, remove peering |
| L6 Lifecycle | Second plan = zero diff, upgrade, destroy, fresh redeploy |

L4 must prove routing symmetry—stateful firewall requires request and return traffic through the same NVA.

## Source of Truth Hierarchy

1. Azure official documentation and behavior
2. Azure AVM PTN source and tests
3. Azure Architecture Center reference architectures
4. Houssem Dellai scenario library (learning reference)
5. Aegis production adaptation (security, HA, lifecycle)

Houssem scenarios inform **how Azure works**. AVM defines **how landing zone modules compose**. Aegis adds **enterprise production requirements**.

## Release Checklist

- [ ] Upstream rebase clean
- [ ] All upstream tests pass
- [ ] All upstream examples pass
- [ ] OPNsense tests pass L1-L6
- [ ] `avm pre-commit` clean
- [ ] Tag: `v{upstream}-aegis.{patch}`
- [ ] CHANGELOG updated
