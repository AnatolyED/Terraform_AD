mock_provider "ad" {
  override_during = plan

  mock_resource "ad_ou" {
    defaults = {
      dn = "OU=Mock,OU=Automation,DC=adm,DC=example"
    }
  }

  mock_resource "ad_user" {
    defaults = {
      id = "11111111-1111-1111-1111-111111111111"
    }
  }

  mock_resource "ad_group" {
    defaults = {
      id = "22222222-2222-2222-2222-222222222222"
    }
  }
}

variables {
  managed_base_dn = "OU=Automation,DC=adm,DC=example"
  user_passwords = {}
}

run "explicit_membership" {
  command = plan

  module {
    source = "../../modules/active-directory"
  }

  variables {
    inventory = {
      ou = {
        identity = { name = "Identity" }
        users = { name = "Users", parent_id = "identity" }
      }
      users = {
        reader = {
          name = "ADM Reader"
          sam_account_name = "adm-reader"
          principal_name = "adm-reader@adm.example"
          ou_id = "users"
        }
      }
      groups = {
        readers = {
          name = "Readers"
          sam_account_name = "adm-readers"
          ou_id = "identity"
          membership = { user_ids = ["reader"], group_ids = [] }
        }
        unmanaged = {
          name = "Unmanaged"
          sam_account_name = "adm-unmanaged"
          ou_id = "identity"
        }
      }
    }
  }

  assert {
    condition = ad_ou.child["users"].path == ad_ou.top_level["identity"].dn
    error_message = "Вложенная OU должна использовать DN родителя."
  }

  assert {
    condition = ad_user.directory["reader"].container == ad_ou.child["users"].dn && !ad_user.directory["reader"].enabled
    error_message = "Пользователь должен находиться в целевой OU и быть отключён по умолчанию."
  }

  assert {
    condition = toset(keys(ad_group_membership.directory)) == toset(["readers"]) && ad_group_membership.directory["readers"].members == toset([ad_user.directory["reader"].id])
    error_message = "Членство должно применяться только к явно выбранной группе."
  }
}

run "reject_unknown_ou" {
  command = plan

  module {
    source = "../../modules/active-directory"
  }

  variables {
    inventory = {
      ou = {}
      users = {}
      groups = {
        readers = {
          name = "Readers"
          sam_account_name = "adm-readers"
          ou_id = "absent"
        }
      }
    }
  }

  expect_failures = [var.inventory]
}
