# -----------------------------------------------------------------------------
# OPNsense 001: Single NVA
# -----------------------------------------------------------------------------
#
# Proves:
#   L3 — OPNsense CE 26.7 VM provisions from Azure Compute Gallery image
#   L3 — NIC has IP forwarding enabled
#   L4 smoke — effective route on snet-test next-hop == OPNsense IP
#   L6 — second plan == zero diff; destroy succeeds
#
# Topology:
#   VNet 10.0.0.0/16
#   ├── snet-nva  10.0.1.0/24  ← OPNsense 10.0.1.4   NO UDR (NVA own subnet)
#   └── snet-test 10.0.2.0/24  ← test NIC              UDR 0.0.0.0/0 → 10.0.1.4
#
# Image: OPNsense CE 26.7 (FreeBSD 15.1-RELEASE-p1, amd64)
#   Gallery : aegisOPNsenseGallery / opnsense-ce / 1.0.0
#   RG      : rg-opnsense-image-factory (eastasia, sub e93e97f4)
#   Provenance: opnsense-ce-image-provenance.json
#
# CSE bootstrap retired — gallery image has OPNsense pre-installed + waagent.
# NAT Gateway retained to allow OPNsense outbound (pkg updates, NTP, etc).
#
# See _header.md for full acceptance gates.
# -----------------------------------------------------------------------------

terraform {
  required_version = "~> 1.12"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.4"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.21"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "azapi" {}

# -----------------------------------------------------------------------------
# Random Suffix
# -----------------------------------------------------------------------------

resource "random_string" "suffix" {
  length  = 4
  numeric = true
  special = false
  upper   = false
}

# -----------------------------------------------------------------------------
# SSH Key (ephemeral — test only, never reuse in production)
# -----------------------------------------------------------------------------

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# -----------------------------------------------------------------------------
# Locals
# -----------------------------------------------------------------------------

locals {
  name_suffix = random_string.suffix.result

  tags = {
    created_by  = "terraform"
    project     = "opnsense-001-single-nva"
    owner       = "avm"
    environment = "demo"
  }

  vnet_address_space  = "10.0.0.0/16"
  subnet_nva_prefix   = "10.0.1.0/24"
  subnet_test_prefix  = "10.0.2.0/24"
  opnsense_private_ip = "10.0.1.4"

  # OPNsense CE 26.7 gallery image — built by image factory (opnsense-ce-image-provenance.json)
  # Hyper-V Gen 1, Generalized, WALinuxAgent 2.15.0.1 pre-installed.
  # Pin to exact version — do NOT use "latest" for NVA images.
  opnsense_source_image_id = "/subscriptions/e93e97f4-923a-4807-93fb-00499800f572/resourceGroups/rg-opnsense-image-factory/providers/Microsoft.Compute/galleries/aegisOPNsenseGallery/images/opnsense-ce/versions/1.0.0"
}

# -----------------------------------------------------------------------------
# Resource Group
# -----------------------------------------------------------------------------

resource "azapi_resource" "rg" {
  type     = "Microsoft.Resources/resourceGroups@2024-11-01"
  name     = "rg-opnsense-001-${local.name_suffix}"
  location = var.location
  tags     = local.tags
}

# -----------------------------------------------------------------------------
# Virtual Network
# -----------------------------------------------------------------------------

resource "azapi_resource" "vnet" {
  type      = "Microsoft.Network/virtualNetworks@2024-07-01"
  name      = "vnet-opnsense-001-${local.name_suffix}"
  location  = var.location
  parent_id = azapi_resource.rg.id
  tags      = local.tags

  body = {
    properties = {
      addressSpace = {
        addressPrefixes = [local.vnet_address_space]
      }
    }
  }
}

# -----------------------------------------------------------------------------
# snet-nva — OPNsense subnet — NO UDR
# A UDR on the NVA's own subnet would loop the NVA's own egress back to itself.
# defaultOutboundAccess=false — explicit outbound only via NAT Gateway below.
# -----------------------------------------------------------------------------

resource "azapi_resource" "subnet_nva" {
  type      = "Microsoft.Network/virtualNetworks/subnets@2024-07-01"
  name      = "snet-nva"
  parent_id = azapi_resource.vnet.id

  body = {
    properties = {
      addressPrefix         = local.subnet_nva_prefix
      defaultOutboundAccess = false
    }
  }

  depends_on = [azapi_resource.vnet]
}

# -----------------------------------------------------------------------------
# NAT Gateway — gives snet-nva explicit outbound Internet access for bootstrap.
# No inbound path is opened. Removed after bootstrap if using custom image.
# -----------------------------------------------------------------------------

resource "azapi_resource" "pip_natgw" {
  type      = "Microsoft.Network/publicIPAddresses@2024-07-01"
  name      = "pip-natgw-${local.name_suffix}"
  location  = var.location
  parent_id = azapi_resource.rg.id
  tags      = local.tags

  body = {
    sku = { name = "Standard" }
    properties = {
      publicIPAllocationMethod = "Static"
    }
  }
}

resource "azapi_resource" "natgw" {
  type      = "Microsoft.Network/natGateways@2024-07-01"
  name      = "natgw-nva-${local.name_suffix}"
  location  = var.location
  parent_id = azapi_resource.rg.id
  tags      = local.tags

  body = {
    sku = { name = "Standard" }
    properties = {
      idleTimeoutInMinutes = 10
      publicIpAddresses = [
        { id = azapi_resource.pip_natgw.id }
      ]
    }
  }

  depends_on = [azapi_resource.pip_natgw]
}

# Associate NAT Gateway with snet-nva
resource "azapi_update_resource" "subnet_nva_natgw" {
  type        = "Microsoft.Network/virtualNetworks/subnets@2024-07-01"
  resource_id = azapi_resource.subnet_nva.id

  body = {
    properties = {
      addressPrefix         = local.subnet_nva_prefix
      defaultOutboundAccess = false
      natGateway            = { id = azapi_resource.natgw.id }
    }
  }

  depends_on = [
    azapi_resource.subnet_nva,
    azapi_resource.natgw,
  ]
}

# -----------------------------------------------------------------------------
# snet-test — workload/smoke-test subnet — UDR → NVA
# defaultOutboundAccess=false; UDR forces traffic through NVA for egress.
# -----------------------------------------------------------------------------

resource "azapi_resource" "subnet_test" {
  type      = "Microsoft.Network/virtualNetworks/subnets@2024-07-01"
  name      = "snet-test"
  parent_id = azapi_resource.vnet.id

  body = {
    properties = {
      addressPrefix         = local.subnet_test_prefix
      defaultOutboundAccess = false
    }
  }

  depends_on = [azapi_update_resource.subnet_nva_natgw]
}

# Route Table — 0.0.0.0/0 → OPNsense; attached to snet-test only
resource "azapi_resource" "route_table_test" {
  type      = "Microsoft.Network/routeTables@2024-07-01"
  name      = "rt-test-via-nva-${local.name_suffix}"
  location  = var.location
  parent_id = azapi_resource.rg.id
  tags      = local.tags

  body = {
    properties = {
      disableBgpRoutePropagation = true
      routes = [
        {
          name = "default-via-nva"
          properties = {
            addressPrefix    = "0.0.0.0/0"
            nextHopType      = "VirtualAppliance"
            nextHopIpAddress = local.opnsense_private_ip
          }
        }
      ]
    }
  }
}

resource "azapi_update_resource" "subnet_test_rt" {
  type        = "Microsoft.Network/virtualNetworks/subnets@2024-07-01"
  resource_id = azapi_resource.subnet_test.id

  body = {
    properties = {
      addressPrefix         = local.subnet_test_prefix
      defaultOutboundAccess = false
      routeTable            = { id = azapi_resource.route_table_test.id }
    }
  }

  depends_on = [
    azapi_resource.subnet_test,
    azapi_resource.route_table_test,
  ]
}

# -----------------------------------------------------------------------------
# OPNsense NVA
# -----------------------------------------------------------------------------

module "opnsense" {
  source = "../../modules/opnsense-nva"

  name      = "opnsense-nva-${local.name_suffix}"
  location  = var.location
  parent_id = azapi_resource.rg.id
  subnet_id = azapi_resource.subnet_nva.id

  private_ip_address_allocation = "Static"
  private_ip_address            = local.opnsense_private_ip

  vm_size        = "Standard_B2ats_v2"
  admin_username = "azureadmin"

  admin_ssh_public_key = tls_private_key.ssh.public_key_openssh

  enable_ip_forwarding = true

  # Gallery image — no Marketplace plan needed for custom/gallery images
  plan = null

  # AN not supported on Standard_B2ats_v2
  enable_accelerated_networking = false

  # Gallery image: OPNsense CE 26.7 (Generalized, V1, WALinuxAgent pre-installed)
  # source_image_reference is ignored when source_image_id is set (see virtual-machines.tf).
  source_image_id = local.opnsense_source_image_id

  custom_data      = null
  enable_telemetry = var.enable_telemetry
  tags             = local.tags

  depends_on = [azapi_update_resource.subnet_nva_natgw]
}

# -----------------------------------------------------------------------------
# Test VM — Standard_B1s in snet-test
#
# Required for valid effective-route assertions. Azure only returns effective
# routes for NICs that are attached to a running VM.
# Ref: https://learn.microsoft.com/azure/virtual-network/virtual-network-routes-overview
#
# Uses Ubuntu LTS — standard Linux image, no marketplace plan needed.
# SKU: Standard_B1s — smallest available, sufficient for routing assertions.
# -----------------------------------------------------------------------------

resource "azapi_resource" "nic_test" {
  type      = "Microsoft.Network/networkInterfaces@2024-07-01"
  name      = "nic-test-${local.name_suffix}"
  location  = var.location
  parent_id = azapi_resource.rg.id
  tags      = local.tags

  body = {
    properties = {
      enableIPForwarding          = false
      enableAcceleratedNetworking = false
      ipConfigurations = [
        {
          name = "ipconfig1"
          properties = {
            privateIPAllocationMethod = "Dynamic"
            subnet                    = { id = azapi_resource.subnet_test.id }
          }
        }
      ]
    }
  }

  response_export_values = ["properties.ipConfigurations"]

  depends_on = [azapi_update_resource.subnet_test_rt]
}

resource "azapi_resource" "vm_test" {
  type      = "Microsoft.Compute/virtualMachines@2024-11-01"
  name      = "vm-test-${local.name_suffix}"
  location  = var.location
  parent_id = azapi_resource.rg.id
  tags      = local.tags

  body = {
    properties = {
      hardwareProfile = {
        vmSize = "Standard_B2ats_v2"
      }
      osProfile = {
        computerName  = "vm-test"
        adminUsername = "azureadmin"
        linuxConfiguration = {
          disablePasswordAuthentication = true
          ssh = {
            publicKeys = [
              {
                path    = "/home/azureadmin/.ssh/authorized_keys"
                keyData = tls_private_key.ssh.public_key_openssh
              }
            ]
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
          managedDisk  = { storageAccountType = "Standard_LRS" }
        }
      }
      networkProfile = {
        networkInterfaces = [
          {
            id         = azapi_resource.nic_test.id
            properties = { primary = true }
          }
        ]
      }
    }
  }

  depends_on = [azapi_resource.nic_test]
}
