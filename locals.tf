locals {
  has_regions = length(var.hub_virtual_networks) > 0
  hub_virtual_networks = {
    for key, value in var.hub_virtual_networks : key => merge(value.hub_virtual_network, {
      parent_id                     = coalesce(value.hub_virtual_network.parent_id, value.default_parent_id)
      name                          = coalesce(value.hub_virtual_network.name, local.default_names[key].virtual_network_name)
      location                      = value.location
      ddos_protection_plan_id       = local.ddos_protection_plan_id != null ? local.ddos_protection_plan_id : value.hub_virtual_network.ddos_protection_plan_id
      firewall                      = local.firewalls[key]
      subnets                       = merge(local.subnets[key], value.hub_virtual_network.subnets, lookup(local.opnsense_subnets, key, {}))
      address_space                 = coalesce(value.hub_virtual_network.address_space, [local.virtual_network_default_ip_prefixes[key]])
      routing_address_space         = coalesce(value.hub_virtual_network.routing_address_space, [value.default_hub_address_space])
      hub_router_ip_address         = local.opnsense_enabled[key] ? local.opnsense_router_ip_addresses[key] : value.hub_virtual_network.hub_router_ip_address
      route_table_name_firewall     = coalesce(value.hub_virtual_network.route_table_name_firewall, local.default_names[key].route_table_firewall_name)
      route_table_name_user_subnets = coalesce(value.hub_virtual_network.route_table_name_user_subnets, local.default_names[key].route_table_user_subnets_name)
      lock = value.hub_virtual_network.lock == null ? null : {
        kind = value.hub_virtual_network.lock.kind
        name = coalesce(value.hub_virtual_network.lock.name, "lock-${key}-hub-${value.location}-${value.hub_virtual_network.lock.kind}")
      }
      nat_gateway = (value.enabled_resources.nat_gateway && value.nat_gateway != null) || local.opnsense_enabled[key] ? merge(value.nat_gateway == null ? {
        name                    = null
        parent_id               = null
        location                = null
        sku                     = "StandardV2"
        idle_timeout_in_minutes = 4
        tags                    = null
        zones                   = null
        lock                    = null
        ip_configurations       = {}
        } : value.nat_gateway, {
        name      = coalesce(try(value.nat_gateway.name, null), local.default_names[key].nat_gateway_name)
        location  = coalesce(try(value.nat_gateway.location, null), value.location)
        parent_id = coalesce(try(value.nat_gateway.parent_id, null), value.default_parent_id)
        zones     = coalesce(try(value.nat_gateway.zones, null), local.availability_zones[key])
        lock = try(value.nat_gateway.lock, null) == null ? null : {
          kind = value.nat_gateway.lock.kind
          name = coalesce(value.nat_gateway.lock.name, "lock-${key}-nat-gateway-${value.location}-${value.nat_gateway.lock.kind}")
        }
        ip_configurations = local.opnsense_enabled[key] ? local.opnsense_nat_gateway_ip_configurations[key] : { for ip_key, ip_config in coalesce(value.nat_gateway.ip_configurations, {}) : ip_key => merge(ip_config, {
          public_ip_configuration = merge(ip_config.public_ip_configuration, {
            zones = coalesce(ip_config.public_ip_configuration.zones, local.availability_zones[key])
          })
        }) }
      }) : null
    })
  }
  hub_virtual_networks_resource_group_names = { for key, value in var.hub_virtual_networks : key => provider::azapi::parse_resource_id("Microsoft.Resources/resourceGroups", coalesce(value.default_parent_id, value.hub_virtual_network.parent_id)).resource_group_name }
  primary_location                          = local.has_regions ? var.hub_virtual_networks[local.primary_region_key].location : null
  primary_region_key                        = local.has_regions ? keys(var.hub_virtual_networks)[0] : null
}
