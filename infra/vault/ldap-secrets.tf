resource "vault_password_policy" "directory" {
  name = "terraform-ad-credentials"
  policy = <<-EOT
    length = 32

    rule "charset" {
      charset = "abcdefghijklmnopqrstuvwxyz"
      min-chars = 2
    }

    rule "charset" {
      charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
      min-chars = 2
    }

    rule "charset" {
      charset = "0123456789"
      min-chars = 2
    }

    rule "charset" {
      charset = "!@#%+=_-"
      min-chars = 2
    }
  EOT
}

resource "vault_ldap_secret_backend" "directory" {
  path = "ad-creds"
  url = var.vault_ldap_url
  certificate = local.ldap_ca_certificate
  insecure_tls = false
  binddn = var.vault_ldap_secrets_bind_dn
  bindpass_wo = var.vault_ldap_secrets_bind_password
  bindpass_wo_version = local.cluster.secrets_bind_password_version
  schema = "ad"
  userdn = var.vault_ldap_secrets_user_dn
  userattr = "sAMAccountName"
  password_policy = vault_password_policy.directory.name

  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_ldap_secret_backend_static_role" "directory" {
  for_each = local.cluster.static_roles

  mount = vault_ldap_secret_backend.directory.path
  role_name = each.key
  username = local.ad_users[each.value.user_id].sam_account_name
  rotation_period = each.value.rotation_period_seconds

  lifecycle {
    prevent_destroy = true

    precondition {
      condition = each.value.rotation_period_seconds >= 10 && each.value.rotation_period_seconds == floor(each.value.rotation_period_seconds)
      error_message = "Период ротации должен быть целым числом от 10 секунд."
    }

    precondition {
      condition = try(local.ad_users[each.value.user_id].enabled, false) && try(local.ad_users[each.value.user_id].change_password_at_logon, true) == false
      error_message = "Сервисная учётка должна быть активна и не требовать смены пароля при входе."
    }
  }
}
