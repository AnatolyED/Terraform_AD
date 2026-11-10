resource "ad_group_membership" "directory" {
  for_each = {
    for id, group in var.inventory.groups : id => group.membership if group.membership != null
  }

  group_id = ad_group.directory[each.key].id
  members = setunion(
    toset([for id in each.value.user_ids : ad_user.directory[id].id]),
    toset([for id in each.value.group_ids : ad_group.directory[id].id])
  )

  lifecycle {
    prevent_destroy = true
  }
}
