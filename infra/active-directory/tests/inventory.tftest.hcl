mock_provider "ad" {}

variables {
  inventory_root = "../../data"
  ad_ldap_url = "ldaps://dc1.adm.example:636"
  ad_managed_base_dn = "OU=Automation,DC=adm,DC=example"
}

run "adm_yaml" {
  command = plan

  variables {
    ad_inventory_environment = "adm"
    ad_user_passwords = {
      for id in keys(yamldecode(file("../../data/active-directory/adm/users.yaml"))) : id => "Mock-AD-Password-1!"
    }
  }
}

run "adm_yaml_explicit_membership" {
  command = plan

  variables {
    ad_inventory_environment = "adm"
    ad_user_passwords = {
      for id in keys(yamldecode(file("../../data/active-directory/adm/users.yaml"))) : id => "Mock-AD-Password-1!"
    }
  }

  assert {
    condition = toset(keys(yamldecode(file("${local.inventory_directory}/groups.yaml")))) == toset(["vault-readers"])
    error_message = "Тестовый инвентарь должен содержать отдельную управляемую группу Vault."
  }
}
