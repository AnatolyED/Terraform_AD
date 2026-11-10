mock_provider "ad" {}

variables {
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

run "production_yaml" {
  command = plan

  variables {
    ad_inventory_environment = "production"
    ad_user_passwords = {
      for id in keys(yamldecode(file("../../inventory/active-directory/production/users.yaml"))) : id => "Mock-AD-Password-1!"
    }
  }
}
