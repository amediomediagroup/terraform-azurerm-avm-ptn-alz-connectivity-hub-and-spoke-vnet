# -----------------------------------------------------------------------------
# Required Variables
# -----------------------------------------------------------------------------

variable "location" {
  type        = string
  description = "The Azure region where the OPNsense NVA will be deployed."
  nullable    = false
}

variable "name" {
  type        = string
  description = "The name of the OPNsense virtual machine."
  nullable    = false
}

variable "parent_id" {
  type        = string
  description = "The resource ID of the resource group in which to create the OPNsense NVA."
  nullable    = false

  validation {
    condition     = can(provider::azapi::parse_resource_id("Microsoft.Resources/resourceGroups", var.parent_id))
    error_message = "parent_id must be a valid resource group resource ID (e.g. /subscriptions/<sub>/resourceGroups/<rg>)."
  }
}

variable "subnet_id" {
  type        = string
  description = "The resource ID of the subnet where the OPNsense NVA will be deployed."
  nullable    = false

  validation {
    condition     = can(provider::azapi::parse_resource_id("Microsoft.Network/virtualNetworks/subnets", var.subnet_id))
    error_message = "subnet_id must be a valid subnet resource ID."
  }
}

# -----------------------------------------------------------------------------
# VM Configuration
# -----------------------------------------------------------------------------

variable "vm_size" {
  type        = string
  default     = "Standard_B2ms"
  description = "The size of the OPNsense virtual machine."
  nullable    = false
}

variable "admin_username" {
  type        = string
  default     = "azureadmin"
  description = "The administrator username for the OPNsense VM. Note: OPNsense will require initial configuration via console or web UI."
  nullable    = false
}

variable "admin_ssh_public_key" {
  type        = string
  default     = null
  description = "The SSH public key for the administrator account. If not provided, password authentication will be used."
  sensitive   = true
}

variable "admin_password" {
  type        = string
  default     = null
  description = "The administrator password. Required if admin_ssh_public_key is not provided. Must meet Azure complexity requirements."
  sensitive   = true

  validation {
    condition     = var.admin_password == null || length(var.admin_password) >= 12
    error_message = "admin_password must be at least 12 characters if provided."
  }
}

variable "os_disk" {
  type = object({
    caching                   = optional(string, "ReadWrite")
    storage_account_type      = optional(string, "Premium_LRS")
    disk_size_gb              = optional(number, 30)
    disk_encryption_set_id    = optional(string)
    write_accelerator_enabled = optional(bool, false)
  })
  default     = {}
  description = <<DESCRIPTION
OS disk configuration for the OPNsense VM.

- `caching` - The caching type. Possible values: None, ReadOnly, ReadWrite. Default: ReadWrite.
- `storage_account_type` - The storage account type. Possible values: Standard_LRS, StandardSSD_LRS, Premium_LRS, Premium_ZRS. Default: Premium_LRS.
- `disk_size_gb` - The size of the OS disk in GB. Default: 30.
- `disk_encryption_set_id` - The ID of the disk encryption set to use for encryption.
- `write_accelerator_enabled` - Enable write accelerator. Only available for Premium_LRS disks on M-series VMs.
DESCRIPTION
  nullable    = false
}

variable "availability_zone" {
  type        = string
  default     = null
  description = "The availability zone for the VM. Specify 1, 2, or 3. Leave null for regional deployment."

  validation {
    condition     = var.availability_zone == null || contains(["1", "2", "3"], var.availability_zone)
    error_message = "availability_zone must be null, \"1\", \"2\", or \"3\"."
  }
}

# -----------------------------------------------------------------------------
# Image Configuration
# -----------------------------------------------------------------------------

variable "source_image_reference" {
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = {
    publisher = "thefreebsdfoundation"
    offer     = "freebsd-14_2"
    sku       = "14_2-release-amd64-gen2-zfs"
    version   = "14.2.20250516"
  }
  description = <<DESCRIPTION
The source image reference for the OPNsense VM.

Default: FreeBSD 14.2.20250516 — a **candidate** base image for OPNsense 25.1
bootstrap. This version has not yet been confirmed by a passing integration run.
Label changes to "confirmed" once CI passes end-to-end.

Do NOT use `version = "latest"` in reproducible deployments.

OPNsense is installed via `custom_data` or a Custom Script Extension using
opnsense-bootstrap, which converts stock FreeBSD to OPNsense in-place:
  https://github.com/opnsense/update

For production, consider a custom managed image with OPNsense pre-installed
to avoid bootstrap time and external network dependency at boot.
DESCRIPTION
  nullable    = false
}

variable "source_image_id" {
  type        = string
  default     = null
  description = "The ID of a custom managed image to use instead of marketplace image. If provided, source_image_reference is ignored."
}

variable "plan" {
  type = object({
    name      = string
    product   = string
    publisher = string
  })
  default     = null
  description = "The marketplace plan for the image. Required for some marketplace images."
}

# -----------------------------------------------------------------------------
# Network Configuration
# -----------------------------------------------------------------------------

variable "enable_ip_forwarding" {
  type        = bool
  default     = true
  description = "Enable IP forwarding on the NIC. Required for NVA functionality."
  nullable    = false
}

variable "enable_accelerated_networking" {
  type        = bool
  default     = false
  description = <<DESCRIPTION
Enable accelerated networking on the NIC.

Accelerated Networking is NOT supported on all VM sizes. For the B-series:
- NOT supported: Standard_B2ms, Standard_B4ms, Standard_B8ms
- Supported: Standard_B12ms, Standard_B16ms, Standard_B20ms

For production NVA workloads, use a D/E/F-series VM (e.g. Standard_D4s_v5)
which reliably supports Accelerated Networking.

Default: false — safe for Standard_B2ms. Set true only with a compatible SKU.
DESCRIPTION
  nullable    = false
}

variable "private_ip_address" {
  type        = string
  default     = null
  description = "Static private IP address. If not provided, dynamic allocation is used."
}

variable "private_ip_address_allocation" {
  type        = string
  default     = "Dynamic"
  description = "The private IP address allocation method. Possible values: Dynamic, Static."
  nullable    = false

  validation {
    condition     = contains(["Dynamic", "Static"], var.private_ip_address_allocation)
    error_message = "private_ip_address_allocation must be either 'Dynamic' or 'Static'."
  }
}

# -----------------------------------------------------------------------------
# Bootstrap Configuration
# -----------------------------------------------------------------------------

variable "custom_data" {
  type        = string
  default     = null
  description = "Base64 encoded custom data (cloud-init) to pass to the VM."
  sensitive   = true
}

variable "user_data" {
  type        = string
  default     = null
  description = "Base64 encoded user data to pass to the VM."
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Tagging and Telemetry
# -----------------------------------------------------------------------------

variable "tags" {
  type        = map(string)
  default     = {}
  description = "A map of tags to apply to all resources."
  nullable    = false
}

variable "enable_telemetry" {
  type        = bool
  default     = true
  description = <<DESCRIPTION
This variable controls whether or not telemetry is enabled for the module.
For more information see <https://aka.ms/avm/telemetryinfo>.
If it is set to false, then no telemetry will be collected.
DESCRIPTION
  nullable    = false
}

# -----------------------------------------------------------------------------
# Timeouts
# -----------------------------------------------------------------------------

variable "timeouts" {
  type = object({
    create = optional(string, "60m")
    delete = optional(string, "60m")
    read   = optional(string, "5m")
    update = optional(string, "60m")
  })
  default     = {}
  description = "Timeouts for resource operations."
  nullable    = false
}

# -----------------------------------------------------------------------------
# AzAPI Retry Configuration
# -----------------------------------------------------------------------------

variable "retry" {
  type = object({
    error_message_regex  = optional(list(string))
    interval_seconds     = optional(number, 10)
    max_interval_seconds = optional(number, 180)
    multiplier           = optional(number, 1.5)
    randomization_factor = optional(number, 0.5)
  })
  default     = null
  description = "Retry configuration for AzAPI resources."
}
