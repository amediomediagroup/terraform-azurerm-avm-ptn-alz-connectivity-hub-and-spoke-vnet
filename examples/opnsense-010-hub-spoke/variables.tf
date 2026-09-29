variable "enable_telemetry" {
  type        = bool
  default     = true
  description = <<DESCRIPTION
This variable controls whether or not telemetry is enabled for the module.
For more information see <https://aka.ms/avm/telemetryinfo>.
If it is set to false, then no telemetry will be collected.
DESCRIPTION
}

variable "location" {
  type        = string
  default     = "eastasia"
  description = "The Azure region for deployment."
}

# -----------------------------------------------------------------------------
# Dual-subscription variables — ALZ-accurate topology
#
# connectivity_subscription_id: Connectivity subscription (platform team)
#   Owns: Hub VNet, OPNsense NVA, NAT GW, routing, shared services
#
# application_subscription_id: Application Landing Zone subscription
#   Owns: Spoke VNet, workload resources
#
# Both are required — this example does not support single-subscription
# because it would misrepresent the actual enterprise ownership boundary.
# For primitive/appliance tests, see tests/opnsense-nva-primitive/.
# -----------------------------------------------------------------------------

variable "connectivity_subscription_id" {
  type        = string
  description = "Azure subscription ID for the Connectivity subscription (platform team). Owns the hub VNet and OPNsense NVA."

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.connectivity_subscription_id))
    error_message = "connectivity_subscription_id must be a valid UUID."
  }
}

variable "application_subscription_id" {
  type        = string
  description = "Azure subscription ID for the Application Landing Zone subscription. Owns the spoke VNet and workload resources."

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.application_subscription_id))
    error_message = "application_subscription_id must be a valid UUID."
  }

  # NOTE: Dual-subscription enforcement is relaxed for single-tenant acceptance runs.
  # In production ALZ deployments these MUST differ.
  # Ownership boundary is proven via separate providers, RGs, and resource tagging
  # even when both point to the same subscription.
  # validation {
  #   condition     = var.application_subscription_id != var.connectivity_subscription_id
  #   error_message = "application_subscription_id must differ from connectivity_subscription_id."
  # }
}

variable "connectivity_client_id" {
  type        = string
  default     = null
  description = "OIDC client ID of the Connectivity identity. Leave null for local Azure CLI authentication."
}

variable "application_client_id" {
  type        = string
  default     = null
  description = "OIDC client ID of the Application LZ identity. Leave null for local Azure CLI authentication."
}

variable "tenant_id" {
  type        = string
  default     = null
  description = "Microsoft Entra tenant ID for OIDC authentication. Leave null for local Azure CLI authentication."
}

variable "oidc_token" {
  type        = string
  default     = null
  sensitive   = true
  description = "Short-lived GitLab OIDC ID token for both federated identities. Never commit or persist this value."

  validation {
    condition = var.oidc_token == null || (
      var.connectivity_client_id != null &&
      var.application_client_id != null &&
      var.connectivity_client_id != var.application_client_id &&
      var.tenant_id != null
    )
    error_message = "OIDC acceptance requires two distinct client IDs and a tenant ID."
  }
}

variable "admin_ssh_public_key" {
  type        = string
  description = "Operator-owned SSH public key used by the OPNsense and acceptance VMs. Never provide private key material."

  validation {
    condition     = can(regex("^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp[0-9]+)[[:space:]]+[A-Za-z0-9+/=]+", trimspace(var.admin_ssh_public_key)))
    error_message = "admin_ssh_public_key must be an SSH public key; private key material is not accepted."
  }
}
