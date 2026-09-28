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
  custom_data                   = null
  enable_telemetry              = var.enable_telemetry
  tags                          = coalesce(each.value.opnsense_nva.tags, var.tags, {})

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
        script = base64encode(<<-SCRIPT
          #!/bin/sh
          set -e
          echo "[opnsense/${each.key}] preparing pinned OPNsense ${local.opnsense_bootstrap_release[each.key]} bootstrap"
          for attempt in 1 2 3; do
            fetch -o /usr/local/sbin/opnsense-bootstrap.sh "${local.opnsense_bootstrap_urls[each.key]}" && break
            [ "$attempt" -lt 3 ] || exit 1
            sleep 15
          done
          chmod 700 /usr/local/sbin/opnsense-bootstrap.sh
          cat > /usr/local/etc/rc.d/opnsense_bootstrap <<'EOF'
          #!/bin/sh
          # PROVIDE: opnsense_bootstrap
          # REQUIRE: NETWORKING
          /usr/local/sbin/opnsense-bootstrap.sh -r ${local.opnsense_bootstrap_release[each.key]} -y
          rc=$?
          echo "$rc" > /var/db/opnsense-bootstrap.exit
          rm -f /usr/local/etc/rc.d/opnsense_bootstrap
          exit "$rc"
          EOF
          chmod 700 /usr/local/etc/rc.d/opnsense_bootstrap
          shutdown -r +1 "OPNsense bootstrap scheduled"
        SCRIPT
        )
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
