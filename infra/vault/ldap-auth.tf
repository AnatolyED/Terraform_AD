resource "vault_ldap_auth_backend" "directory" {
  path = "ad-ldap"
  url = var.vault_ldap_url
  certificate = local.ldap_ca_certificate
  insecure_tls = false
  binddn = var.vault_ldap_auth_bind_dn
  bindpass_wo = var.vault_ldap_auth_bind_password
  bindpass_wo_version = local.cluster.auth_bind_password_version
  userdn = var.vault_ldap_auth_user_dn
  userattr = "sAMAccountName"
  groupdn = var.vault_ldap_auth_group_dn
  groupattr = "sAMAccountName"
  groupfilter = "(&(objectClass=group)(member:1.2.840.113556.1.4.1941:={{.UserDN}}))"
  deny_null_bind = true

  lifecycle {
    prevent_destroy = true

    precondition {
      condition = alltrue([
        for cluster in values(local.vault_clusters) :
        contains(["lab", "production"], cluster.ad_environment) &&
        can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", cluster.address)) &&
        cluster.auth_bind_password_version >= 1 &&
        cluster.auth_bind_password_version == floor(cluster.auth_bind_password_version) &&
        cluster.secrets_bind_password_version >= 1 &&
        cluster.secrets_bind_password_version == floor(cluster.secrets_bind_password_version)
      ])
      error_message = "Для каждого кластера требуется HTTPS URL, окружение AD и две целочисленные версии пароля от 1."
    }

    precondition {
      condition = length(distinct(local.vault_cluster_addresses)) == length(local.vault_cluster_addresses)
      error_message = "Кластеры Vault должны иметь разные адреса."
    }

    precondition {
      condition = length(distinct(local.rotation_assignments)) == length(local.rotation_assignments)
      error_message = "Один пользователь AD может иметь только одну роль ротации в своём окружении."
    }
  }
}

resource "vault_policy" "directory" {
  for_each = local.cluster.policies

  name = "ad-${each.key}"
  policy = jsonencode({
    path = {
      for secret_path, capabilities in each.value :
      secret_path => { capabilities = capabilities }
    }
  })
}

resource "vault_ldap_auth_backend_group" "directory" {
  for_each = local.cluster.group_policies

  backend = vault_ldap_auth_backend.directory.path
  groupname = lower(local.ad_groups[each.key].sam_account_name)
  policies = [for policy_id in each.value : vault_policy.directory[policy_id].name]

  lifecycle {
    precondition {
      condition = try(local.ad_groups[each.key].category, "security") == "security"
      error_message = "Политику Vault можно назначить только AD-группе категории security."
    }
  }
}
