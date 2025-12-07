variable "tenant_id" {
  type        = string
  description = "Azure Tenant ID"
  default     = "${env("ARM_TENANT_ID")}"
}

variable "subscription_id" {
  type        = string
  description = "Azure Staging Subscription ID"
  default     = "${env("ARM_SUBSCRIPTION_ID")}"
}

variable "client_id" {
  type        = string
  description = "Azure Client ID (Service Principal)"
  default     = "${env("ARM_CLIENT_ID")}"
}

variable "client_secret" {
  type        = string
  description = "Azure Client Secret"
  default     = "${env("ARM_CLIENT_SECRET")}"
  sensitive   = true
}

variable "managed_image_resource_group_name" {
  type        = string
  description = "The managed image resource group name"
  default     = "${env("PKR_VAR_IMAGE_RG_NAME")}"
}

variable "managed_image_name" {
  type        = string
  description = "The managed image name"
  default     = "${env("PKR_VAR_IMAGE_NAME")}"
}

variable "gallery_subscription_id" {
  type        = string
  description = "Azure Gallery Subscription ID"
  default     = ""
}

variable "location" {
  type        = string
  description = "Azure Region"
  default     = "France Central"
}

variable "vm_size" {
  type        = string
  description = "Temporary VM size for building"
  default     = "Standard_D4s_v5"
}

variable "shared_image_gallery_name" {
  type        = string
  description = "Shared Image Gallery name"
  default     = ""
}

variable "shared_image_gallery_resource_group" {
  type        = string
  description = "Resource Group containing the Shared Image Gallery"
  default     = ""
}

variable "gallery_image_name" {
  type        = string
  description = "Image name in the gallery"
  default     = ""
}

variable "gallery_image_version" {
  type        = string
  description = "Image version in the gallery"
  default     = ""
}

variable "source_image_publisher" {
  type        = string
  description = "Source image publisher"
  default     = "MicrosoftWindowsServer"
}

variable "source_image_offer" {
  type        = string
  description = "Source image offer"
  default     = "WindowsServer"
}

variable "source_image_sku" {
  type        = string
  description = "Source image SKU"
  default     = "2022-datacenter-hotpatch-g2"
}

variable "build_resource_group_name" {
  type        = string
  description = "Temporary Resource Group for the build process"
  default     = "rg-packer-build"
}

variable "virtual_network_name" {
  type        = string
  description = "Virtual network name (optional)"
  default     = ""
}

variable "virtual_network_subnet_name" {
  type        = string
  description = "Subnet name (optional)"
  default     = ""
}

variable "virtual_network_resource_group_name" {
  type        = string
  description = "Virtual network Resource Group (optional)"
  default     = ""
}

variable "winrm_username" {
  type        = string
  description = "WinRM username for Packer connection"
  default     = "packer"
}

variable "winrm_timeout" {
  type        = string
  description = "WinRM connection timeout"
  default     = "20m"
}

variable "common_tags" {
  type        = map(string)
  description = "Common tags to apply to all resources"
  default = {
    Environment = "Staging"
    CreatedBy   = "Packer"
    Purpose     = "base-Image"
    OS          = "Windows"
  }
}

# Additional variables for build metadata and customization
# Used in locals for tagging and image naming
variable "build_name" {
  type        = string
  description = "Build name identifier"
  default     = "windows-server-2022-build"
}

variable "execution_policy" {
  type        = string
  description = "PowerShell execution policy for scripts"
  default     = "unrestricted"
}

variable "run_id" {
  type        = string
  description = "Unique run identifier for this build. Typically the Azure DevOps build ID."
  default     = "${env("BUILD_BUILDID")}"
}

variable "baseline_version" {
  type        = string
  description = "Baseline version for the image build"
  default     = ""
}