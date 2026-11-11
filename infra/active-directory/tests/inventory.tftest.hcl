mock_provider "ad" {}

variables {
  inventory_root = "../../inventory"
  ad_ldap_url = "ldaps://dc1.lab.example:636"
  ad_managed_base_dn = "OU=Automation,DC=lab,DC=example"
}

run "lab_yaml" {
  command = plan

  variables {
    ad_inventory_environment = "lab"
    ad_user_passwords = {
      for id in keys(yamldecode(file("../../inventory/active-directory/lab/users.yaml"))) : id => "Mock-AD-Password-1!"
    }
  }
}

run "lab_yaml_explicit_membership" {
  command = plan

  variables {
    ad_inventory_environment = "lab"
    ad_user_passwords = {
      for id in keys(yamldecode(file("../../inventory/active-directory/lab/users.yaml"))) : id => "Mock-AD-Password-1!"
    }
  }

  assert {
    condition = toset(keys(yamldecode(file("${local.inventory_directory}/groups.yaml")))) == toset(["vault-readers"])
    error_message = "Тестовый инвентарь должен содержать отдельную управляемую группу Vault."
  }
}
