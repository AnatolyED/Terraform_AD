locals {
  inventory_directory = "${path.module}/../../inventory/active-directory/${var.ad_inventory_environment}"
}

provider "ad" {
  ldap_url = var.ad_ldap_url
  use_tls = true
  skip_tls_verify = false
  ignore_missing_members = false
}

module "directory" {
  source = "../../modules/active-directory"

  managed_base_dn = var.ad_managed_base_dn
  user_passwords = var.ad_user_passwords
  inventory = {
    organizational_units = yamldecode(file("${local.inventory_directory}/organizational-units.yaml"))
    groups = yamldecode(file("${local.inventory_directory}/groups.yaml"))
    users = yamldecode(file("${local.inventory_directory}/users.yaml"))
  }
}
