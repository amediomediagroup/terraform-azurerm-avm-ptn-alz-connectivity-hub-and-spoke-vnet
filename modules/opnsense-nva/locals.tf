locals {
  # Extract resource group name from parent_id using AzAPI provider function
  resource_group_name = provider::azapi::parse_resource_id("Microsoft.Resources/resourceGroups", var.parent_id).resource_group_name

  # Determine private IP address (for outputs)
  # When using dynamic allocation, we need to read from the deployed NIC
  private_ip_address = var.private_ip_address_allocation == "Static" ? var.private_ip_address : azapi_resource.nic.output.properties.ipConfigurations[0].properties.privateIPAddress

  # NIC name derivation
  nic_name = "nic-${var.name}"

  # Determine authentication type
  disable_password_authentication = var.admin_ssh_public_key != null

  # OS profile
  os_profile = {
    computerName  = var.name
    adminUsername = var.admin_username
    adminPassword = var.admin_password
    customData    = var.custom_data
    linuxConfiguration = {
      disablePasswordAuthentication = local.disable_password_authentication
      ssh = local.disable_password_authentication ? {
        publicKeys = [
          {
            path    = "/home/${var.admin_username}/.ssh/authorized_keys"
            keyData = var.admin_ssh_public_key
          }
        ]
      } : null
    }
  }

  # Image reference - prefer custom image if provided
  image_reference = var.source_image_id != null ? null : {
    publisher = var.source_image_reference.publisher
    offer     = var.source_image_reference.offer
    sku       = var.source_image_reference.sku
    version   = var.source_image_reference.version
  }

  # Zones configuration
  zones = var.availability_zone != null ? [var.availability_zone] : null
}
