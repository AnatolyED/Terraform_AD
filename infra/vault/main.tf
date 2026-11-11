locals {
  vault_clusters = yamldecode(file("${var.inventory_root}/vault/clusters.yaml"))
  cluster = local.vault_clusters[var.vault_cluster_id]
  vault_cluster_addresses = [for cluster in values(local.vault_clusters) : lower(trimsuffix(cluster.address, ":443"))]
  rotation_assignments = flatten([
    for cluster in values(local.vault_clusters) : [
      for role in values(cluster.static_roles) : jsonencode([cluster.ad_environment, role.user_id])
    ]
  ])

  ad_inventory_directory = "${var.inventory_root}/active-directory/${local.cluster.ad_environment}"
  ad_groups = yamldecode(file("${local.ad_inventory_directory}/groups.yaml"))
  ad_users = yamldecode(file("${local.ad_inventory_directory}/users.yaml"))
  ldap_ca_certificate = var.vault_ldap_ca_file == null ? null : file(var.vault_ldap_ca_file)
}

provider "vault" {
  address = local.cluster.address
  skip_tls_verify = false
  skip_child_token = true

  dynamic "auth_login_jwt" {
    for_each = var.vault_use_gitlab_jwt ? [true] : []

    content {
      mount = "gitlab-jwt"
      role = var.vault_gitlab_role
      jwt = var.vault_gitlab_jwt
    }
  }
}
