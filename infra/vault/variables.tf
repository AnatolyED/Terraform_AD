variable "inventory_root" {
  type = string
  description = "Каталог YAML-инвентаря."
  nullable = false
}

variable "vault_cluster_id" {
  type = string
  description = "Ключ кластера Vault из YAML."
  nullable = false

  validation {
    condition = contains(keys(local.vault_clusters), var.vault_cluster_id)
    error_message = "Кластер Vault должен быть описан в inventory/vault/clusters.yaml."
  }
}

variable "vault_ldap_url" {
  type = string
  description = "LDAPS URL контроллера домена."
  nullable = false

  validation {
    condition = can(regex("^ldaps://[A-Za-z0-9.-]+(:[0-9]+)?$", var.vault_ldap_url))
    error_message = "Требуется URL вида ldaps://dc.example.com:636."
  }
}

variable "vault_ldap_ca_file" {
  type = string
  description = "Путь к PEM цепочки CA AD."
  default = null
}

variable "vault_ldap_auth_bind_dn" {
  type = string
  description = "DN bind-учётки LDAP auth."
  nullable = false
}

variable "vault_ldap_auth_bind_password" {
  type = string
  description = "Пароль bind-учётки LDAP auth."
  sensitive = true
  ephemeral = true
  nullable = false
}

variable "vault_ldap_auth_user_dn" {
  type = string
  description = "База поиска пользователей LDAP auth."
  nullable = false
}

variable "vault_ldap_auth_group_dn" {
  type = string
  description = "База поиска групп LDAP auth."
  nullable = false
}

variable "vault_ldap_secrets_bind_dn" {
  type = string
  description = "DN bind-учётки LDAP secrets engine."
  nullable = false

  validation {
    condition = lower(trimspace(var.vault_ldap_secrets_bind_dn)) != lower(trimspace(var.vault_ldap_auth_bind_dn))
    error_message = "LDAP auth и LDAP secrets engine требуют разные bind-учётки."
  }
}

variable "vault_ldap_secrets_bind_password" {
  type = string
  description = "Пароль bind-учётки LDAP secrets engine."
  sensitive = true
  ephemeral = true
  nullable = false
}

variable "vault_ldap_secrets_user_dn" {
  type = string
  description = "База поиска сервисных учёток для ротации."
  nullable = false
}

variable "vault_use_gitlab_jwt" {
  type = bool
  description = "Включить аутентификацию через GitLab JWT."
  default = false
  nullable = false
}

variable "vault_gitlab_role" {
  type = string
  description = "Роль GitLab JWT в Vault."
  default = null
  ephemeral = true
}

variable "vault_gitlab_jwt" {
  type = string
  description = "ID token текущего задания GitLab."
  default = null
  sensitive = true
  ephemeral = true
}
