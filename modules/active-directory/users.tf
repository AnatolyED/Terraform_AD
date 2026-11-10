resource "ad_user" "directory" {
  for_each = var.inventory.users

  name = each.value.name
  sam_account_name = each.value.sam_account_name
  principal_name = each.value.principal_name
  container = local.organizational_unit_dns[each.value.ou_id]
  enabled = each.value.enabled
  password = lookup(var.user_passwords, each.key, null)
  password_version = each.value.password_version
  change_password_at_logon = each.value.change_password_at_logon
  display_name = each.value.display_name
  given_name = each.value.given_name
  surname = each.value.surname
  email_address = each.value.email_address
  description = each.value.description

  lifecycle {
    prevent_destroy = true
  }
}
