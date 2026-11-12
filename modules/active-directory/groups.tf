resource "ad_group" "directory" {
  for_each = var.inventory.groups

  name = each.value.name
  sam_account_name = each.value.sam_account_name
  container = local.ou_dns[each.value.ou_id]
  scope = each.value.scope
  category = each.value.category
  description = each.value.description

  lifecycle {
    prevent_destroy = true
  }
}
