# -----------------------------------------------------------------------------
# OPNsense 010: Hub-and-Spoke — first Landing Zone acceptance example
# -----------------------------------------------------------------------------
#
# Design proof:
#   Business requirement:  Centrally inspect and control workload egress via a
#                          custom NVA in a dedicated Connectivity subscription,
#                          following the ALZ hub-spoke topology.
#
#   Architecture decision: CAF ALZ hub-spoke with custom NVA replaces Azure
#                          Firewall. Hub in Connectivity sub; spokes in
#                          Application LZ subs. Ref: Azure Architecture Center
#                          hub-spoke topology + CAF ALZ guidance.
#
#   Ownership:             Hub VNet, OPNsense, routing → Connectivity sub
#                          (platform team). Spoke VNet → Application LZ sub
#                          (workload team). Peering initiated from spoke side;
#                          hub allows forwarded traffic.
#
#   Traffic model:         spoke VM → UDR → Hub VNet → root-derived OPNsense (10.1.1.4)
#                          → destination. Return: destination → OPNsense →
#                          spoke VM (stateful; symmetry required).
#
#   Failure model:         (addressed at 040-ha) — single NVA here; failure
#                          drops egress path. HA pattern in 040.
#
#   IaC contract:          hub_and_spoke_vnet (Aegis fork) via
#                          hub_virtual_networks.primary.opnsense_nva.
#                          Spoke peering: AVM VNet peering submodule, once per
#                          subscription, using each subscription's provider.
#
# Consumer contract: one root module call for connectivity, one AVM VNet and
# two AVM peering calls for the spoke fixture. No raw VNet/NAT/UDR resources
# at the hub side — those are owned by the root module.
#
# See _header.md for gate definitions (G0–G6).
# -----------------------------------------------------------------------------

terraform {
  required_version = "~> 1.12"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.12"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

# -----------------------------------------------------------------------------
# Providers — one per subscription, matching ALZ ownership boundary
# -----------------------------------------------------------------------------

# Connectivity subscription — platform team; owns Hub + OPNsense
provider "azurerm" {
  alias           = "connectivity"
  subscription_id = var.connectivity_subscription_id
  client_id       = var.connectivity_client_id
  tenant_id       = var.tenant_id
  oidc_token      = var.oidc_token
  use_oidc        = var.oidc_token != null
  features {}
}

provider "azapi" {
  alias           = "connectivity"
  subscription_id = var.connectivity_subscription_id
  client_id       = var.connectivity_client_id
  tenant_id       = var.tenant_id
  oidc_token      = var.oidc_token
  use_oidc        = var.oidc_token != null
}

# Application Landing Zone subscription — workload team; owns spoke
provider "azapi" {
  alias           = "application"
  subscription_id = var.application_subscription_id
  client_id       = var.application_client_id
  tenant_id       = var.tenant_id
  oidc_token      = var.oidc_token
  use_oidc        = var.oidc_token != null
}

data "azapi_client_config" "connectivity" {
  provider = azapi.connectivity
}

data "azapi_client_config" "application" {
  provider = azapi.application
}

# -----------------------------------------------------------------------------
# Random suffix. The caller supplies only an SSH public key; no private key is
# generated, persisted in Terraform state, or committed by this fixture.
# -----------------------------------------------------------------------------

resource "random_string" "suffix" {
  length  = 4
  numeric = true
  special = false
  upper   = false
}

# -----------------------------------------------------------------------------
# Resource groups
# Connectivity RG: owned by platform team (Connectivity sub)
# Application RG:  owned by workload team (Application LZ sub)
# -----------------------------------------------------------------------------

resource "azapi_resource" "rg_connectivity" {
  type      = "Microsoft.Resources/resourceGroups@2024-11-01"
  name      = "rg-connectivity-010-${random_string.suffix.result}"
  location  = var.location
  parent_id = "/subscriptions/${var.connectivity_subscription_id}"

  tags = {
    created_by   = "terraform"
    project      = "opnsense-010-hub-spoke"
    owner        = "platform-connectivity"
    environment  = "demo"
    subscription = "connectivity"
  }

  provider               = azapi.connectivity
  response_export_values = []
}

resource "azapi_resource" "rg_application" {
  type      = "Microsoft.Resources/resourceGroups@2024-11-01"
  name      = "rg-application-010-${random_string.suffix.result}"
  location  = var.location
  parent_id = "/subscriptions/${var.application_subscription_id}"

  tags = {
    created_by   = "terraform"
    project      = "opnsense-010-hub-spoke"
    owner        = "workload-team"
    environment  = "demo"
    subscription = "application"
  }

  provider               = azapi.application
  response_export_values = []
}

# -----------------------------------------------------------------------------
# Locals — networking topology
# -----------------------------------------------------------------------------

locals {
  tags = {
    created_by  = "terraform"
    project     = "opnsense-010-hub-spoke"
    environment = "demo"
  }

  hub_prefix = "10.1.0.0/16"
  nva_prefix = "10.1.1.0/27"

  spoke_cidr   = "10.2.0.0/16"
  spoke_prefix = "10.2.0.0/24"

  hub_and_spoke_networks_settings = {
    enabled_resources = {
      ddos_protection_plan = false
    }
  }

  hub_virtual_networks = {
    primary = {
      location          = var.location
      default_parent_id = azapi_resource.rg_connectivity.id

      # Azure Firewall disabled — OPNsense is the hub router
      enabled_resources = {
        opnsense_nva                          = true
        bastion                               = false
        virtual_network_gateway_express_route = false
        virtual_network_gateway_vpn           = false
        private_dns_zones                     = false
        private_dns_resolver                  = false
      }

      default_hub_address_space = "10.1.0.0/16"

      hub_virtual_network = {
        address_space = [local.hub_prefix]
        # routing_address_space declares spoke CIDRs — used for hub UDR mesh
        # AND derived by root into AEGIS configurator customData for OPNsense policy.
        # Consumer declares only intent; root owns all transport semantics.
        routing_address_space = [local.spoke_cidr]
      }

      opnsense_nva = {
        subnet = {
          address_prefix = local.nva_prefix
        }
        compute = {
          admin_ssh_public_key = var.admin_ssh_public_key
          vm_size              = "Standard_B2ats_v2"
        }
        image = {
          # Gallery 1.0.2: OPNsense CE 26.7 + AEGIS first-boot configurator
          # (waagent OS.SshDir fix + per-deployment policy injection via customData)
          source_image_id = "/subscriptions/e93e97f4-923a-4807-93fb-00499800f572/resourceGroups/rg-connectivity-imagebuilder-eas-rg-001/providers/Microsoft.Compute/galleries/gal_connectivity_prod_opnsense/images/opnsense-ce/versions/1.0.2"
        }
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Hub — Connectivity subscription
# Single root module call; all hub networking owned inside.
# -----------------------------------------------------------------------------

module "hub_and_spoke_vnet" {
  source = "../../"

  enable_telemetry                = var.enable_telemetry
  hub_and_spoke_networks_settings = local.hub_and_spoke_networks_settings
  hub_virtual_networks            = local.hub_virtual_networks
  tags                            = local.tags

  providers = {
    azurerm = azurerm.connectivity
    azapi   = azapi.connectivity
  }
}

# -----------------------------------------------------------------------------
# Spoke — Application Landing Zone subscription
#
# Spoke VNet is owned by the application team (Application LZ sub).
# It is external to the connectivity module — the root module does not create
# or manage it. This reflects the actual ALZ ownership boundary.
#
# UDR on the spoke subnet: 0.0.0.0/0 → OPNsense (via hub peering).
# allow_forwarded_traffic = true required so NVA-originated packets
# from the hub can reach the spoke (non-transitive peering behavior).
# Ref: https://learn.microsoft.com/azure/virtual-network/virtual-network-peering-overview
# -----------------------------------------------------------------------------

resource "azapi_resource" "spoke_route_table" {
  type      = "Microsoft.Network/routeTables@2024-05-01"
  name      = "rt-spoke-via-nva-${random_string.suffix.result}"
  location  = var.location
  parent_id = azapi_resource.rg_application.id
  tags      = local.tags

  body = {
    properties = {
      disableBgpRoutePropagation = true
    }
  }

  response_export_values = []
  provider               = azapi.application
}

resource "azapi_resource" "spoke_default_route" {
  type      = "Microsoft.Network/routeTables/routes@2024-05-01"
  name      = "default-via-nva"
  parent_id = azapi_resource.spoke_route_table.id

  body = {
    properties = {
      addressPrefix    = "0.0.0.0/0"
      nextHopType      = "VirtualAppliance"
      nextHopIpAddress = module.hub_and_spoke_vnet.hub_router_ip_addresses["primary"]
    }
  }

  response_export_values = []
  provider               = azapi.application
}

# The Application LZ VNet and subnet are independent from the connectivity PTN.
# This pinned AVM release implements their control-plane resources with AzAPI.
module "spoke" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm"
  version = "0.22.2"

  name          = "vnet-spoke-010-${random_string.suffix.result}"
  location      = var.location
  parent_id     = azapi_resource.rg_application.id
  address_space = [local.spoke_cidr]
  subnets = {
    workload = {
      name             = "snet-workload"
      address_prefixes = [local.spoke_prefix]
      route_table = {
        id = azapi_resource.spoke_route_table.id
      }
    }
  }
  tags = merge(local.tags, { owner = "workload-team" })

  providers = {
    azapi = azapi.application
  }

  depends_on = [azapi_resource.spoke_default_route]
}

# -----------------------------------------------------------------------------
# Cross-subscription VNet peering (both directions required)
#
# Peering is non-transitive. Both sides must be configured:
#   spoke → hub: initiated from Application LZ sub (application team)
#   hub  → spoke: initiated from Connectivity sub (platform team)
#
# allow_forwarded_traffic on hub→spoke side: permits OPNsense-forwarded
# traffic originating from the NVA (not the hub VNet itself) to reach spoke.
# This is required for NVA-based inspection to work correctly.
# -----------------------------------------------------------------------------

module "spoke_to_hub" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm//modules/peering"
  version = "0.22.2"

  name                         = "peer-spoke-to-hub-${random_string.suffix.result}"
  parent_id                    = module.spoke.resource_id
  remote_virtual_network_id    = module.hub_and_spoke_vnet.virtual_network_resource_ids["primary"]
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true

  providers = {
    azapi = azapi.application
  }
}

module "hub_to_spoke" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm//modules/peering"
  version = "0.22.2"

  name                         = "peer-hub-to-spoke-${random_string.suffix.result}"
  parent_id                    = module.hub_and_spoke_vnet.virtual_network_resource_ids["primary"]
  remote_virtual_network_id    = module.spoke.resource_id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true

  providers = {
    azapi = azapi.connectivity
  }
}

# -----------------------------------------------------------------------------
# Test NIC in spoke — attached to a running VM so effective-route API works
# (Azure requires NIC to be attached to a running VM for effective-route query)
# -----------------------------------------------------------------------------

resource "azapi_resource" "spoke_test_nic" {
  type      = "Microsoft.Network/networkInterfaces@2024-07-01"
  name      = "nic-spoke-test-${random_string.suffix.result}"
  location  = var.location
  parent_id = azapi_resource.rg_application.id
  tags      = local.tags

  body = {
    properties = {
      ipConfigurations = [{
        name = "ipconfig1"
        properties = {
          privateIPAllocationMethod = "Dynamic"
          subnet = {
            id = module.spoke.subnets["workload"].resource_id
          }
        }
      }]
    }
  }

  response_export_values = []
  provider               = azapi.application
}

resource "azapi_resource" "spoke_test_vm" {
  type      = "Microsoft.Compute/virtualMachines@2024-11-01"
  name      = "vm-spoke-test-${random_string.suffix.result}"
  location  = var.location
  parent_id = azapi_resource.rg_application.id
  tags      = local.tags

  body = {
    properties = {
      hardwareProfile = {
        vmSize = "Standard_B2ats_v2"
      }
      osProfile = {
        computerName  = "spoke-test"
        adminUsername = "azureadmin"
        linuxConfiguration = {
          disablePasswordAuthentication = true
          ssh = {
            publicKeys = [{
              path    = "/home/azureadmin/.ssh/authorized_keys"
              keyData = var.admin_ssh_public_key
            }]
          }
        }
      }
      storageProfile = {
        imageReference = {
          publisher = "Canonical"
          offer     = "ubuntu-24_04-lts"
          sku       = "server"
          version   = "latest"
        }
        osDisk = {
          createOption = "FromImage"
          caching      = "ReadWrite"
          managedDisk = {
            storageAccountType = "Standard_LRS"
          }
        }
      }
      networkProfile = {
        networkInterfaces = [{
          id = azapi_resource.spoke_test_nic.id
          properties = {
            primary = true
          }
        }]
      }
    }
  }

  response_export_values = []
  provider               = azapi.application

  depends_on = [module.spoke_to_hub, module.hub_to_spoke]
}
