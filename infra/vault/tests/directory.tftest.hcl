mock_provider "vault" {}

variables {
  vault_ldap_url = "ldaps://dc1.lab.example:636"
  vault_ldap_auth_bind_dn = "CN=Lab Auth,OU=Services,DC=lab,DC=example"
  vault_ldap_auth_bind_password = "mock-auth-password"
  vault_ldap_auth_user_dn = "OU=Users,DC=lab,DC=example"
  vault_ldap_auth_group_dn = "OU=Groups,DC=lab,DC=example"
  vault_ldap_secrets_bind_dn = "CN=Lab Rotation,OU=Services,DC=lab,DC=example"
  vault_ldap_secrets_bind_password = "mock-secrets-password"
  vault_ldap_secrets_user_dn = "OU=Services,DC=lab,DC=example"
}

run "ldap_auth_and_static_rotation" {
  command = plan

  variables {
    vault_cluster_id = "vault-01"
  }

  assert {
    condition = alltrue([
      for group_id, group in vault_ldap_auth_backend_group.directory :
      group.groupname == lower(local.ad_groups[group_id].sam_account_name) &&
      toset(group.policies) == toset([for policy_id in local.cluster.group_policies[group_id] : "ad-${policy_id}"])
    ])
    error_message = "Политика должна назначаться по sAMAccountName группы из YAML AD."
  }

  assert {
    condition = vault_ldap_secret_backend.directory.schema == "ad" && alltrue([
      for role_id, role in vault_ldap_secret_backend_static_role.directory :
      role.username == local.ad_users[local.cluster.static_roles[role_id].user_id].sam_account_name
    ])
    error_message = "Роль ротации должна использовать сервисную учётку из YAML AD."
  }
}

run "independent_cluster" {
  command = plan

  variables {
    vault_cluster_id = "vault-02"
  }

  assert {
    condition = keys(vault_ldap_secret_backend_static_role.directory) == keys(local.cluster.static_roles) && keys(vault_ldap_auth_backend_group.directory) == keys(local.cluster.group_policies)
    error_message = "Роли и группы должны загружаться только для выбранного кластера."
  }
}
