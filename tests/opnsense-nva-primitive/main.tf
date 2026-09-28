# -----------------------------------------------------------------------------
# OPNsense 001: Single NVA
# -----------------------------------------------------------------------------
#
# Proves:
#   L3 — FreeBSD VM provisions and Custom Script Extension succeeds
#   L3 — NIC has IP forwarding enabled
#   L4 smoke — effective route on snet-test next-hop == OPNsense IP
#   L6 — second plan == zero diff; destroy succeeds
#
# Topology:
#   VNet 10.0.0.0/16
#   ├── snet-nva  10.0.1.0/24  ← OPNsense 10.0.1.4   NAT GW for egress, NO UDR
#   └── snet-test 10.0.2.0/24  ← test NIC              UDR 0.0.0.0/0 → 10.0.1.4
#
# Bootstrap tuple (candidate — must be confirmed by integration run):
#   FreeBSD  : thefreebsdfoundation/freebsd-14_2/14_2-release-amd64-gen2-zfs:14.2.20250516
#   bootstrap: opnsense/update @ da1985064501 (2025-05-07, last stable before FreeBSD 15 work)
#   OPNsense : 25.1
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

  # Bootstrap tuple — candidate, pending integration run confirmation.
  # Pinned bootstrap commit: da1985064501 (2025-05-07)
  bootstrap_commit = "da1985064501be4e7e7f35c073f21b5b3a17a6f5"
  opnsense_release = "25.1"
  bootstrap_url    = "https://raw.githubusercontent.com/opnsense/update/${local.bootstrap_commit}/src/bootstrap/opnsense-bootstrap.sh.in"

  # Generation ID — same formula as main.opnsense.tf opnsense_bootstrap_generation local.
  # Key components: hub_key(="primitive"), release, commit_sha, router_ip.
  # CI must assert attestation.generation == this value to reject stale records.
  bootstrap_generation = sha256("primitive:${local.opnsense_release}:${local.bootstrap_commit}:${local.opnsense_private_ip}")
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

  vm_size        = "Standard_B2ms"
  admin_username = "azureadmin"

  admin_ssh_public_key = tls_private_key.ssh.public_key_openssh

  enable_ip_forwarding = true

  # AN not supported on Standard_B2ms (requires B12ms+)
  enable_accelerated_networking = false

  # Pinned FreeBSD image — do NOT use "latest"
  source_image_reference = {
    publisher = "thefreebsdfoundation"
    offer     = "freebsd-14_2"
    sku       = "14_2-release-amd64-gen2-zfs"
    version   = "14.2.20250516"
  }

  # custom_data intentionally null — bootstrap is done via CSE below,
  # which gives Azure-reported success/failure status we can assert on.
  custom_data = null

  enable_telemetry = var.enable_telemetry
  tags             = local.tags

  depends_on = [azapi_update_resource.subnet_nva_natgw]
}

# -----------------------------------------------------------------------------
# Custom Script Extension — OPNsense bootstrap stage 1
#
# Publisher: Microsoft.OSTCExtensions.CustomScriptForLinux  (v1.x)
#   This is the version with documented FreeBSD support.
#   Microsoft.Azure.Extensions.CustomScript v2.x does NOT list FreeBSD
#   in its supported OS matrix. Using v1.x until v2.x FreeBSD support is
#   confirmed by official documentation.
#
# Stage 1 only: downloads bootstrap, schedules it as a firstboot rc.d service,
# then EXITS before the reboot. CSE must not run across the reboot boundary.
# See locals.bootstrap_stage1_script for full design rationale.
# -----------------------------------------------------------------------------

resource "azapi_resource" "bootstrap_ext" {
  type      = "Microsoft.Compute/virtualMachines/extensions@2024-11-01"
  name      = "opnsense-bootstrap"
  location  = var.location
  parent_id = module.opnsense.resource_id
  tags      = local.tags

  body = {
    properties = {
      publisher               = "Microsoft.OSTCExtensions"
      type                    = "CustomScriptForLinux"
      typeHandlerVersion      = "1.5"
      autoUpgradeMinorVersion = true
      settings = {
        # Same state machine contract as main.opnsense.tf (root PTN).
        # Adapted for single-hub locals; generation uses key="primitive".
        script = base64encode(<<-SCRIPT
          #!/bin/sh
          set -e
          echo "[001] stage1: preparing bootstrap state machine"

          AEGIS_STATE_DIR="/var/db/aegis"
          mkdir -p "$AEGIS_STATE_DIR"

          GENERATION="${local.bootstrap_generation}"
          echo "$GENERATION" > "$AEGIS_STATE_DIR/generation"
          echo "PREPARED" > "$AEGIS_STATE_DIR/state"
          echo "[001] state=PREPARED generation=$GENERATION"

          for attempt in 1 2 3; do
            fetch -o /usr/local/sbin/opnsense-bootstrap.sh "${local.bootstrap_url}" && break
            [ "$attempt" -lt 3 ] || exit 1
            sleep 15
          done
          chmod 700 /usr/local/sbin/opnsense-bootstrap.sh

          cat > /usr/local/etc/rc.d/aegis_opnsense_ready <<RCEOF
          #!/bin/sh
          # PROVIDE: aegis_opnsense_ready
          # REQUIRE: NETWORKING
          # KEYWORD: nojail

          . /etc/rc.subr

          name="aegis_opnsense_ready"
          rcvar=\$${name}_enable
          start_cmd="\$${name}_start"

          aegis_opnsense_ready_start() {
            local state_dir="/var/db/aegis"
            local generation=\$$(cat "\$${state_dir}/generation" 2>/dev/null || echo "unknown")

            local attempts=0
            while [ -f /var/run/booting ] && [ \$${attempts} -lt 30 ]; do
              sleep 10
              attempts=\$$(( attempts + 1 ))
            done

            local actual_release=\$$(opnsense-version -v 2>/dev/null | awk '{print \$$1}')
            local release_ok="false"
            [ "\$${actual_release}" = "${local.opnsense_release}" ] && release_ok="true"

            local fwd_val=\$$(sysctl -n net.inet.ip.forwarding 2>/dev/null)
            local forwarding_ok="false"
            [ "\$${fwd_val}" = "1" ] && forwarding_ok="true"

            local pf_status=\$$(pfctl -si 2>/dev/null | grep -i "^Status:" | awk '{print \$$2}')
            local pf_ok="false"
            [ "\$${pf_status}" = "Enabled" ] && pf_ok="true"

            local ip_ok="false"
            ifconfig | grep -q "${local.opnsense_private_ip}" && ip_ok="true"

            local bootstrap_pending="false"
            [ -f /usr/local/etc/rc.d/opnsense_bootstrap ] && bootstrap_pending="true"

            if [ "\$${release_ok}" = "true" ] && [ "\$${forwarding_ok}" = "true" ] && \
               [ "\$${pf_ok}" = "true" ] && [ "\$${ip_ok}" = "true" ] && \
               [ "\$${bootstrap_pending}" = "false" ]; then
              echo "READY" > "\$${state_dir}/state"
            fi

            printf 'AEGIS_OPNSENSE_READY {"generation":"%s","release":"%s","release_ok":%s,"router_ip":"%s","ip_ok":%s,"forwarding":%s,"pf":%s,"bootstrap_pending":%s}\n' \
              "\$${generation}" \
              "\$${actual_release}" "\$${release_ok}" \
              "${local.opnsense_private_ip}" "\$${ip_ok}" \
              "\$${forwarding_ok}" "\$${pf_ok}" \
              "\$${bootstrap_pending}" \
              > /dev/console
          }

          load_rc_config \$${name}
          : \$${aegis_opnsense_ready_enable:=YES}
          run_rc_command "\$$1"
          RCEOF
          chmod 700 /usr/local/etc/rc.d/aegis_opnsense_ready

          cat > /usr/local/etc/rc.d/opnsense_bootstrap <<BSEOF
          #!/bin/sh
          # PROVIDE: opnsense_bootstrap
          # REQUIRE: NETWORKING
          # KEYWORD: nojail

          state_dir="/var/db/aegis"

          current_state=\$$(cat "\$${state_dir}/state" 2>/dev/null || echo "")
          if [ "\$${current_state}" != "PREPARED" ]; then
            echo "[aegis] bootstrap: state=\$${current_state}, skipping"
            rm -f /usr/local/etc/rc.d/opnsense_bootstrap
            exit 0
          fi

          echo "BOOTSTRAPPING" > "\$${state_dir}/state"
          echo "[aegis] bootstrap: state=BOOTSTRAPPING, starting opnsense-bootstrap"

          /usr/local/sbin/opnsense-bootstrap.sh -r ${local.opnsense_release} -y
          BSEOF
          chmod 700 /usr/local/etc/rc.d/opnsense_bootstrap

          echo "[001] stage1 complete"
          shutdown -r +1 "OPNsense bootstrap scheduled"
        SCRIPT
        )
      }
    }
  }

  timeouts {
    create = "30m"
    delete = "10m"
    read   = "5m"
    update = "30m"
  }

  depends_on = [module.opnsense]
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
        vmSize = "Standard_B1s"
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
