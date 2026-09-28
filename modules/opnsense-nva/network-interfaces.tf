# -----------------------------------------------------------------------------
# Network Interface
# 
# Single NIC deployment for opnsense-001-single-nva scenario.
# Multi-NIC (trust/untrust) will be added in opnsense-040-ha.
# -----------------------------------------------------------------------------

resource "azapi_resource" "nic" {
  type      = "Microsoft.Network/networkInterfaces@2024-07-01"
  name      = local.nic_name
  location  = var.location
  parent_id = var.parent_id
  tags      = var.tags

  body = {
    properties = {
      enableAcceleratedNetworking = var.enable_accelerated_networking
      enableIPForwarding          = var.enable_ip_forwarding
      ipConfigurations = [
        {
          name = "ipconfig1"
          properties = {
            privateIPAllocationMethod = var.private_ip_address_allocation
            privateIPAddress          = var.private_ip_address_allocation == "Static" ? var.private_ip_address : null
            subnet = {
              id = var.subnet_id
            }
          }
        }
      ]
    }
  }

  response_export_values    = ["properties.ipConfigurations"]
  retry                     = var.retry
  schema_validation_enabled = true
  ignore_body_changes       = []

  timeouts {
    create = var.timeouts.create
    delete = var.timeouts.delete
    read   = var.timeouts.read
    update = var.timeouts.update
  }

  lifecycle {
    precondition {
      condition     = var.private_ip_address_allocation == "Dynamic" || var.private_ip_address != null
      error_message = "private_ip_address is required when private_ip_address_allocation is 'Static'."
    }
  }
}
