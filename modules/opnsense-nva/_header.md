# OPNsense NVA Submodule

This submodule deploys an OPNsense Network Virtual Appliance (NVA) for use in Azure Landing Zone hub-spoke topologies.

## Overview

The OPNsense NVA serves as a central firewall/routing appliance in hub-spoke architectures, providing:

- **Egress filtering**: Spoke → NVA → Internet
- **East-west inspection**: Spoke A ↔ NVA ↔ Spoke B
- **VPN termination**: Site-to-site or point-to-site connectivity
- **Network segmentation**: Stateful firewall rules between network zones

## Scenario Progression

This submodule follows a progressive complexity model. Each example builds on the previous:

| Example | Capabilities |
|---------|-------------|
| `opnsense-001-single-nva` | VM + NIC + IP forwarding |
| `opnsense-010-hub-spoke` | + Hub/spoke + peering + UDR |
| `opnsense-020-central-egress` | + Spoke → NVA → Internet |
| `opnsense-030-east-west` | + Spoke ↔ NVA ↔ Spoke |
| `opnsense-040-ha` | + 2 NVAs + ILB + failover |

## Current Phase: Single NVA (001)

The initial implementation supports:

- Single network interface
- IP forwarding enabled
- Static or dynamic private IP allocation
- SSH key or password authentication
- Custom managed image or FreeBSD marketplace image
- Availability zone placement

HA features (dual NVA, internal load balancer, CARP/pfsync) are added at the `040-ha` phase.

## Usage

```hcl
module "opnsense" {
  source = "../../modules/opnsense-nva"

  name      = "opnsense-nva-01"
  location  = "swedencentral"
  parent_id = var.hub_resource_group_id
  subnet_id = var.nva_subnet_id

  admin_username       = "azureadmin"
  admin_ssh_public_key = file("~/.ssh/id_rsa.pub")

  enable_ip_forwarding = true

  tags = {
    environment = "production"
    role        = "nva"
  }
}
```

## Bootstrap

OPNsense requires post-deployment configuration. Options:

1. **Cloud-init**: Pass configuration via `custom_data`
2. **Custom image**: Pre-install OPNsense in a managed image
3. **Manual**: Configure via web UI or serial console after deployment

For production deployments, use a custom managed image with OPNsense pre-installed and hardened.
