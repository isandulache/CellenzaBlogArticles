source "azure-arm" "image" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  client_id       = var.client_id
  client_secret   = var.client_secret

  location                 = var.location
  temp_resource_group_name = var.build_resource_group_name
  vm_size                  = var.vm_size

  image_publisher = var.source_image_publisher
  image_offer     = var.source_image_offer
  image_sku       = var.source_image_sku

  #If you want to build the image in an existing VNet, uncomment the 3 lines below and provide the variables
  # virtual_network_name                = var.virtual_network_name
  # virtual_network_subnet_name         = var.virtual_network_subnet_name
  # virtual_network_resource_group_name = var.virtual_network_resource_group_name

  communicator   = "winrm"
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = var.winrm_timeout
  winrm_username = var.winrm_username

  os_type = "Windows"

  managed_image_name                = var.managed_image_name
  managed_image_resource_group_name = var.managed_image_resource_group_name

  ### If you want to upload to a Shared Gallery, uncomment the block below
  ### and comment `managed_image_name` and `managed_image_resource_group_name`

  # shared_image_gallery_destination {
  #   subscription         = var.gallery_subscription_id
  #   resource_group       = var.shared_image_gallery_resource_group
  #   gallery_name         = var.shared_image_gallery_name
  #   image_name           = var.gallery_image_name
  #   image_version        = var.gallery_image_version
  #   replication_regions  = ["France Central"]
  #   storage_account_type = "Standard_LRS"
  # }

  azure_tags = local.computed_tags
}
