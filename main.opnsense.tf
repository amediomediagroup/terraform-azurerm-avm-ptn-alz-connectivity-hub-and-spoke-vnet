# Managed OPNsense is an implementation detail of the connectivity PTN.
# The root owns its subnet, NAT association, canonical router address and
# routing integration; this module owns only the appliance resources.
locals {
  opnsense_subnet_ids = {
    for key, value in local.opnsense_hubs : key => try(
      module.hub_and_spoke_vnet.virtual_networks[key].subnet_ids["opnsense_nva"],
      "${module.hub_and_spoke_vnet.resource_id[key]}/subnets/snet-opnsense-nva"
    )
  }

  opnsense_bootstrap_release = {
    for key, value in local.opnsense_hubs : key => coalesce(value.opnsense_nva.bootstrap.release, "25.1")
  }

  opnsense_bootstrap_commit_sha = {
    for key, value in local.opnsense_hubs : key => coalesce(value.opnsense_nva.bootstrap.commit_sha, "da1985064501be4e7e7f35c073f21b5b3a17a6f5")
  }

  opnsense_bootstrap_urls = {
    for key, value in local.opnsense_hubs : key => "https://raw.githubusercontent.com/opnsense/update/${local.opnsense_bootstrap_commit_sha[key]}/src/bootstrap/opnsense-bootstrap.sh.in"
    if value.opnsense_nva.image.source_image_id == null
  }

  # Generation ID: stable hash of deployment parameters.
  # Written to /var/db/aegis/generation on the VM; CI must assert this
  # matches the expected value to reject stale Boot Diagnostics records.
  opnsense_bootstrap_generation = {
    for key, value in local.opnsense_hubs : key => sha256(
      "${key}:${local.opnsense_bootstrap_release[key]}:${local.opnsense_bootstrap_commit_sha[key]}:${local.opnsense_router_ip_addresses[key]}"
    )
    if value.opnsense_nva.image.source_image_id == null
  }

  # Aegis fork SHA — pinned here to build immutable script URLs.
  # Update this when the fork SHA changes (same discipline as bootstrap_commit_sha).
  # Current: amediomediagroup fork, feat/opnsense-nva-root-integration branch.
  aegis_fork_sha = "d22cc19622b1244b732900613453e4a88f98ecde"

  # Raw GitHub URL for stage-1 bootstrap script (immutable at commit SHA).
  opnsense_stage1_script_base_url = "https://raw.githubusercontent.com/amediomediagroup/terraform-azurerm-avm-ptn-alz-connectivity-hub-and-spoke-vnet/${local.aegis_fork_sha}/scripts/bootstrap"

  # Per-hub CSE commandToExecute strings built from deployment parameters.
  opnsense_stage1_commands = {
    for key, value in local.opnsense_hubs : key => join(" ", [
      "sh aegis-opnsense-stage1.sh",
      "'${local.opnsense_bootstrap_release[key]}'",
      "'${local.opnsense_bootstrap_commit_sha[key]}'",
      "'${local.opnsense_router_ip_addresses[key]}'",
      "'${local.opnsense_bootstrap_generation[key]}'"
    ])
    if value.opnsense_nva.image.source_image_id == null
  }
}

module "opnsense_nva" {
  source   = "./modules/opnsense-nva"
  for_each = local.opnsense_hubs

  name      = coalesce(each.value.opnsense_nva.name, "opnsense-${each.key}")
  location  = each.value.location
  parent_id = local.hub_virtual_networks[each.key].parent_id
  subnet_id = local.opnsense_subnet_ids[each.key]

  private_ip_address_allocation = "Static"
  private_ip_address            = local.opnsense_router_ip_addresses[each.key]

  vm_size              = coalesce(each.value.opnsense_nva.compute.vm_size, "Standard_B2ms")
  admin_username       = "azureadmin"
  admin_ssh_public_key = each.value.opnsense_nva.compute.admin_ssh_public_key
  availability_zone    = each.value.opnsense_nva.compute.zone
  source_image_id      = each.value.opnsense_nva.image.source_image_id
  source_image_reference = {
    publisher = "thefreebsdfoundation"
    offer     = "freebsd-14_2"
    sku       = "14_2-release-amd64-gen2-zfs"
    version   = "14.2.20250516"
  }

  enable_ip_forwarding          = true
  enable_accelerated_networking = false
  # Internally-generated AEGIS first-boot configurator payload.
  # Derived from routing_address_space, router_ip, and image identity.
  # Consumer does not construct or see this value.
  custom_data      = try(local.opnsense_runtime_payloads[each.key], null)
  enable_telemetry = var.enable_telemetry
  tags             = coalesce(each.value.opnsense_nva.tags, var.tags, {})

  retry    = var.retry
  timeouts = var.timeouts

  depends_on = [module.hub_and_spoke_vnet]
}

# Stage 1 only prepares the pinned bootstrap and requests a guest reboot.
# CSE success is deliberately not treated as appliance readiness; 010 remains
# blocked until a deterministic post-boot runtime/configuration proof exists.
resource "azapi_resource" "opnsense_bootstrap_ext" {
  for_each = {
    for key, value in local.opnsense_hubs : key => value
    if value.opnsense_nva.image.source_image_id == null
  }

  type      = "Microsoft.Compute/virtualMachines/extensions@2024-11-01"
  name      = "opnsense-bootstrap"
  location  = each.value.location
  parent_id = module.opnsense_nva[each.key].resource_id
  tags      = coalesce(each.value.opnsense_nva.tags, var.tags, {})

  body = {
    properties = {
      publisher               = "Microsoft.OSTCExtensions"
      type                    = "CustomScriptForLinux"
      typeHandlerVersion      = "1.5"
      autoUpgradeMinorVersion = true
      settings = {
        fileUris = [
          "${local.opnsense_stage1_script_base_url}/aegis-opnsense-stage1.sh"
        ]
        commandToExecute = local.opnsense_stage1_commands[each.key]
      }
    }
  }

  response_export_values    = []
  retry                     = var.retry
  schema_validation_enabled = true
  ignore_body_changes       = []

  timeouts {
    create = "30m"
    delete = "10m"
    read   = "5m"
    update = "30m"
  }

  depends_on = [module.opnsense_nva]
}
