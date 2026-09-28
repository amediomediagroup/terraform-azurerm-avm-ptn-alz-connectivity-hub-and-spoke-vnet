mock_provider "azurerm" {}
mock_provider "azapi" {}
mock_provider "modtm" {}
mock_provider "random" {}

run "managed_opnsense_derives_router_ip_and_owns_firewall_choice" {
  command = plan

  variables {
    enable_telemetry = false
    tags             = { test = "opnsense" }
    hub_and_spoke_networks_settings = {
      enabled_resources = { ddos_protection_plan = false }
    }
    hub_virtual_networks = {
      primary = {
        location          = "southeastasia"
        default_parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-connectivity"
        enabled_resources = {
          opnsense_nva                          = true
          bastion                               = false
          virtual_network_gateway_express_route = false
          virtual_network_gateway_vpn           = false
          private_dns_zones                     = false
          private_dns_resolver                  = false
          dns_resolver_policy                   = false
        }
        hub_virtual_network = {
          address_space = ["10.20.0.0/16"]
        }
        opnsense_nva = {
          subnet  = { address_prefix = "10.20.1.0/27" }
          compute = { admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEexample" }
        }
      }
    }
  }

  assert {
    condition     = output.opnsense_nva_private_ip_addresses["primary"] == "10.20.1.4"
    error_message = "The root module must derive the canonical OPNsense IP from the subnet and router_host."
  }

  assert {
    condition     = output.opnsense_nva_private_ip_addresses["primary"] == output.hub_router_ip_addresses["primary"]
    error_message = "The NVA NIC address and root hub router address must be the same canonical IP."
  }

  assert {
    condition     = length(output.firewall_resource_ids) == 0
    error_message = "Managed OPNsense mode must not create an Azure Firewall."
  }

  assert {
    condition     = contains(keys(output.nat_gateways), "primary")
    error_message = "Managed OPNsense mode must create the root-owned NAT Gateway by default."
  }
}

run "managed_opnsense_requires_a_resolvable_subnet" {
  command = plan

  variables {
    enable_telemetry = false
    hub_and_spoke_networks_settings = {
      enabled_resources = { ddos_protection_plan = false }
    }
    hub_virtual_networks = {
      primary = {
        location          = "southeastasia"
        default_parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-connectivity"
        enabled_resources = {
          opnsense_nva                          = true
          firewall                              = false
          firewall_policy                       = false
          bastion                               = false
          virtual_network_gateway_express_route = false
          virtual_network_gateway_vpn           = false
          private_dns_zones                     = false
          private_dns_resolver                  = false
          dns_resolver_policy                   = false
        }
        hub_virtual_network = { address_space = ["10.20.0.0/16"] }
        opnsense_nva = {
          compute = { admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEexample" }
        }
      }
    }
  }

  expect_failures = [var.hub_virtual_networks]
}

run "managed_opnsense_reuses_reserved_subnet_and_supports_host_override" {
  command = plan

  variables {
    enable_telemetry = false
    hub_and_spoke_networks_settings = {
      enabled_resources = { ddos_protection_plan = false }
    }
    hub_virtual_networks = {
      primary = {
        location          = "southeastasia"
        default_parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-connectivity"
        enabled_resources = {
          opnsense_nva                          = true
          firewall                              = false
          firewall_policy                       = false
          bastion                               = false
          virtual_network_gateway_express_route = false
          virtual_network_gateway_vpn           = false
          private_dns_zones                     = false
          private_dns_resolver                  = false
          dns_resolver_policy                   = false
        }
        hub_virtual_network = {
          address_space = ["10.20.0.0/16"]
          subnets = {
            opnsense_nva = {
              name             = "snet-existing-opnsense"
              address_prefixes = ["10.20.1.0/27"]
            }
          }
        }
        opnsense_nva = {
          subnet  = { router_host = 5 }
          compute = { admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEexample" }
        }
      }
    }
  }

  assert {
    condition     = output.opnsense_nva_private_ip_addresses["primary"] == "10.20.1.5"
    error_message = "The root module must reuse the reserved subnet and derive the selected router host address."
  }
}

run "managed_opnsense_rejects_conflicting_explicit_router_ip" {
  command = plan

  variables {
    enable_telemetry = false
    hub_and_spoke_networks_settings = {
      enabled_resources = { ddos_protection_plan = false }
    }
    hub_virtual_networks = {
      primary = {
        location          = "southeastasia"
        default_parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-connectivity"
        enabled_resources = {
          opnsense_nva                          = true
          firewall                              = false
          firewall_policy                       = false
          bastion                               = false
          virtual_network_gateway_express_route = false
          virtual_network_gateway_vpn           = false
          private_dns_zones                     = false
          private_dns_resolver                  = false
          dns_resolver_policy                   = false
        }
        hub_virtual_network = {
          address_space         = ["10.20.0.0/16"]
          hub_router_ip_address = "10.20.1.5"
        }
        opnsense_nva = {
          subnet  = { address_prefix = "10.20.1.0/27" }
          compute = { admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEexample" }
        }
      }
    }
  }

  expect_failures = [var.hub_virtual_networks]
}

run "managed_opnsense_rejects_explicit_azure_firewall_enablement" {
  command = plan

  variables {
    enable_telemetry = false
    hub_and_spoke_networks_settings = {
      enabled_resources = { ddos_protection_plan = false }
    }
    hub_virtual_networks = {
      primary = {
        location          = "southeastasia"
        default_parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-connectivity"
        enabled_resources = {
          opnsense_nva                          = true
          firewall                              = true
          bastion                               = false
          virtual_network_gateway_express_route = false
          virtual_network_gateway_vpn           = false
          private_dns_zones                     = false
          private_dns_resolver                  = false
          dns_resolver_policy                   = false
        }
        hub_virtual_network = { address_space = ["10.20.0.0/16"] }
        opnsense_nva = {
          subnet  = { address_prefix = "10.20.1.0/27" }
          compute = { admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEexample" }
        }
      }
    }
  }

  expect_failures = [var.hub_virtual_networks]
}

run "legacy_hub_keeps_default_firewall_behavior" {
  command = plan

  variables {
    enable_telemetry = false
    hub_and_spoke_networks_settings = {
      enabled_resources = { ddos_protection_plan = false }
    }
    hub_virtual_networks = {
      primary = {
        location          = "southeastasia"
        default_parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-connectivity"
        enabled_resources = {
          bastion                               = false
          virtual_network_gateway_express_route = false
          virtual_network_gateway_vpn           = false
          private_dns_zones                     = false
          private_dns_resolver                  = false
          dns_resolver_policy                   = false
        }
        hub_virtual_network = {
          address_space = ["10.20.0.0/16"]
        }
      }
    }
  }

  assert {
    condition     = contains(keys(output.firewall_resource_ids), "primary")
    error_message = "A legacy hub that omits OPNsense must retain the upstream enabled Firewall default."
  }
}
