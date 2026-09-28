# -----------------------------------------------------------------------------
# OPNsense Virtual Machine
# 
# Single VM deployment for opnsense-001-single-nva scenario.
# HA with dual VMs + ILB will be added in opnsense-040-ha.
# -----------------------------------------------------------------------------

resource "azapi_resource" "vm" {
  type      = "Microsoft.Compute/virtualMachines@2024-11-01"
  name      = var.name
  location  = var.location
  parent_id = var.parent_id
  tags      = var.tags

  body = {
    zones = local.zones
    plan  = var.plan
    properties = {
      hardwareProfile = {
        vmSize = var.vm_size
      }
      osProfile = local.os_profile
      storageProfile = {
        imageReference = var.source_image_id != null ? {
          id = var.source_image_id
        } : local.image_reference
        osDisk = {
          createOption = "FromImage"
          caching      = var.os_disk.caching
          managedDisk = {
            storageAccountType = var.os_disk.storage_account_type
            diskEncryptionSet = var.os_disk.disk_encryption_set_id != null ? {
              id = var.os_disk.disk_encryption_set_id
            } : null
          }
          diskSizeGB              = var.os_disk.disk_size_gb
          writeAcceleratorEnabled = var.os_disk.write_accelerator_enabled
        }
      }
      networkProfile = {
        networkInterfaces = [
          {
            id = azapi_resource.nic.id
            properties = {
              primary = true
            }
          }
        ]
      }
      userData = var.user_data
    }
  }

  response_export_values    = ["*"]
  retry                     = var.retry
  schema_validation_enabled = true
  ignore_body_changes       = []

  timeouts {
    create = var.timeouts.create
    delete = var.timeouts.delete
    read   = var.timeouts.read
    update = var.timeouts.update
  }

  depends_on = [azapi_resource.nic]

  lifecycle {
    precondition {
      condition     = var.admin_ssh_public_key != null || var.admin_password != null
      error_message = "Either admin_ssh_public_key or admin_password must be provided."
    }
  }
}
