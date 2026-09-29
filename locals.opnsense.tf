locals {
  opnsense_enabled = {
    for key, value in var.hub_virtual_networks : key => value.enabled_resources.opnsense_nva
  }

  opnsense_subnet_prefixes = {
    for key, value in var.hub_virtual_networks : key => try(coalesce(
      value.opnsense_nva.subnet.address_prefix,
      try(value.hub_virtual_network.subnets["opnsense_nva"].address_prefixes[0], null)
    ), null) if local.opnsense_enabled[key]
  }

  opnsense_router_ip_addresses = {
    for key, value in var.hub_virtual_networks : key => local.opnsense_subnet_prefixes[key] == null ? null : cidrhost(
      local.opnsense_subnet_prefixes[key],
      value.opnsense_nva.subnet.router_host
    ) if local.opnsense_enabled[key]
  }

  opnsense_hubs = {
    for key, value in var.hub_virtual_networks : key => value
    if local.opnsense_enabled[key]
  }

  opnsense_subnets = {
    for key, value in local.opnsense_hubs : key => {
      opnsense_nva = {
        name             = "snet-opnsense-nva"
        address_prefixes = [local.opnsense_subnet_prefixes[key]]
        nat_gateway = {
          assign_generated_nat_gateway = true
        }
        route_table = {
          assign_generated_route_table = false
        }
        default_outbound_access_enabled = false
      }
    }
  }

  opnsense_nat_gateway_ip_configurations = {
    for key, value in var.hub_virtual_networks : key => (
      value.nat_gateway == null || length(try(value.nat_gateway.ip_configurations, {})) == 0
      ? { default = { is_default = true } }
      : value.nat_gateway.ip_configurations
    ) if local.opnsense_enabled[key]
  }

  # ---------------------------------------------------------------------------
  # AEGIS first-boot configurator payload
  #
  # Derived internally from hub_virtual_network.routing_address_space — the
  # authoritative spoke-CIDR declaration already required by consumers for
  # hub-mesh UDR. Consumer does not see or construct this payload.
  #
  # Only produced for gallery-image hubs (source_image_id != null); the
  # bootstrap path does not use first-boot configuration.
  # ---------------------------------------------------------------------------
  opnsense_allowed_spoke_cidrs = {
    for key, value in local.opnsense_hubs : key =>
    # routing_address_space is coalesced in locals.tf to include
    # default_hub_address_space; filter it out — spoke CIDRs are
    # those not equal to the hub's own address space.
    [
      for cidr in coalesce(value.hub_virtual_network.routing_address_space, []) :
      cidr
      if !startswith(cidr, split("/", coalesce(
        try(value.hub_virtual_network.address_space[0], null),
        value.default_hub_address_space,
        "10.0.0.0/16"
      ))[0])
    ]
    if value.opnsense_nva.image.source_image_id != null
  }

  # Generation: deterministic from image identity + router IP + spoke CIDRs.
  # Changing any of these produces a new generation, so the READY attestation
  # can be matched to exactly this deployment.
  opnsense_runtime_generations = {
    for key, value in local.opnsense_hubs : key => sha256(join(":", concat(
      [key, value.opnsense_nva.image.source_image_id, local.opnsense_router_ip_addresses[key]],
      sort(local.opnsense_allowed_spoke_cidrs[key])
    )))
    if value.opnsense_nva.image.source_image_id != null
  }

  # Full JSON payload — base64-encoded for Azure VM customData transport.
  # Schema version 1 matches aegis-first-boot.py SCHEMA_VERSION constant.
  opnsense_runtime_payloads = {
    for key, value in local.opnsense_hubs : key => base64encode(jsonencode({
      schema_version      = "1"
      generation          = local.opnsense_runtime_generations[key]
      router_ip           = local.opnsense_router_ip_addresses[key]
      allowed_spoke_cidrs = local.opnsense_allowed_spoke_cidrs[key]
    }))
    if value.opnsense_nva.image.source_image_id != null
  }
}
