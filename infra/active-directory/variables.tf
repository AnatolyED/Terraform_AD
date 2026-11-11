variable "ad_inventory_environment" {
  type = string
  description = "Окружение инвентаря AD."
  nullable = false

  validation {
    condition = var.ad_inventory_environment == "production"
    error_message = "В ветке main поддерживается только окружение AD production."
  }
}

variable "ad_ldap_url" {
  type = string
  description = "LDAPS URL контроллера домена."
  nullable = false

  validation {
    condition = can(regex("^ldaps://[A-Za-z0-9.-]+(:[0-9]+)?$", var.ad_ldap_url))
    error_message = "Требуется URL вида ldaps://dc.example.com:636."
  }
}

variable "ad_managed_base_dn" {
  type = string
  description = "DN существующей OU с делегированными правами."
  nullable = false

  validation {
    condition = startswith(lower(trimspace(var.ad_managed_base_dn)), "ou=") && strcontains(lower(var.ad_managed_base_dn), ",dc=")
    error_message = "Требуется DN выделенной OU в домене AD."
  }
}

variable "ad_user_passwords" {
  type = map(string)
  description = "Пароли AD по идентификаторам пользователей из YAML."
  default = {}
  sensitive = true
  ephemeral = true
  nullable = false
}
