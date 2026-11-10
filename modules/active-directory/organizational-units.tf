locals {
  organizational_unit_dns = merge(
    { for id, ou in ad_ou.top_level : id => ou.dn },
    { for id, ou in ad_ou.child : id => ou.dn }
  )
}

resource "ad_ou" "top_level" {
  for_each = {
    for id, ou in var.inventory.organizational_units : id => ou if ou.parent_id == null
  }

  name = each.value.name
  path = var.managed_base_dn
  description = each.value.description
  protected = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "ad_ou" "child" {
  for_each = {
    for id, ou in var.inventory.organizational_units : id => ou if ou.parent_id != null
  }

  name = each.value.name
  path = ad_ou.top_level[each.value.parent_id].dn
  description = each.value.description
  protected = true

  lifecycle {
    prevent_destroy = true
  }
}
