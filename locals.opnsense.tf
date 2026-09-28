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
}
