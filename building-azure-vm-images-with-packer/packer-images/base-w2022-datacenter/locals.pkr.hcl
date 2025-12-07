locals {
  computed_tags = merge(var.common_tags, {
    gitRef          = var.run_id != "" ? var.run_id : "manual"
    imageVersion    = var.gallery_image_version
    imageName       = var.gallery_image_name != "" ? var.gallery_image_name : "${var.managed_image_name}-img"
    buildDate       = formatdate("YYYY-MM-DD", timestamp())
    baselineVersion = var.baseline_version

  })
}