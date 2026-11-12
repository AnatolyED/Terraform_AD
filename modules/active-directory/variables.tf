variable "managed_base_dn" {
  type = string
  nullable = false
}

variable "user_passwords" {
  type = map(string)
  sensitive = true
  ephemeral = true
  nullable = false
}

variable "inventory" {
  type = object({
    ou = map(object({
      name = string
      parent_id = optional(string)
      description = optional(string)
    }))
    groups = map(object({
      name = string
      sam_account_name = string
      ou_id = string
      scope = optional(string, "global")
      category = optional(string, "security")
      description = optional(string)
      membership = optional(object({
        user_ids = set(string)
        group_ids = set(string)
      }))
    }))
    users = map(object({
      name = string
      sam_account_name = string
      principal_name = string
      ou_id = string
      enabled = optional(bool, false)
      password_version = optional(number, 0)
      change_password_at_logon = optional(bool)
      display_name = optional(string)
      given_name = optional(string)
      surname = optional(string)
      email_address = optional(string)
      description = optional(string)
    }))
  })
  nullable = false

  validation {
    condition = alltrue([
      for ou in values(var.inventory.ou) :
      ou.parent_id == null || try(var.inventory.ou[ou.parent_id].parent_id == null, false)
    ])
    error_message = "Вложенная OU должна ссылаться на OU верхнего уровня."
  }

  validation {
    condition = alltrue(concat(
      [for group in values(var.inventory.groups) : contains(keys(var.inventory.ou), group.ou_id)],
      [for user in values(var.inventory.users) : contains(keys(var.inventory.ou), user.ou_id)]
    ))
    error_message = "ou_id должен указывать на OU из инвентаря."
  }

  validation {
    condition = length(distinct([
      for ou in values(var.inventory.ou) :
      jsonencode([ou.parent_id, lower(ou.name)])
    ])) == length(var.inventory.ou)
    error_message = "Имена OU должны быть уникальны в пределах родительской OU."
  }

  validation {
    condition = length(distinct(concat(
      [for group in values(var.inventory.groups) : lower(group.sam_account_name)],
      [for user in values(var.inventory.users) : lower(user.sam_account_name)]
    ))) == length(var.inventory.groups) + length(var.inventory.users)
    error_message = "sAMAccountName должен быть уникальным среди групп и пользователей."
  }

  validation {
    condition = length(distinct([
      for user in values(var.inventory.users) : lower(user.principal_name)
    ])) == length(var.inventory.users)
    error_message = "UPN должен быть уникальным среди пользователей."
  }

  validation {
    condition = length(distinct(concat(
      [for group in values(var.inventory.groups) : jsonencode([group.ou_id, lower(group.name)])],
      [for user in values(var.inventory.users) : jsonencode([user.ou_id, lower(user.name)])]
    ))) == length(var.inventory.groups) + length(var.inventory.users)
    error_message = "CN групп и пользователей должен быть уникальным в пределах OU."
  }

  validation {
    condition = alltrue([
      for user in values(var.inventory.users) :
      user.password_version >= 0 && user.password_version == floor(user.password_version)
    ])
    error_message = "password_version должен быть целым числом от 0."
  }

  validation {
    condition = alltrue([
      for id, group in var.inventory.groups : try(
        length(setsubtract(group.membership.user_ids, keys(var.inventory.users))) == 0 &&
        length(setsubtract(group.membership.group_ids, keys(var.inventory.groups))) == 0 &&
        !contains(group.membership.group_ids, id),
        group.membership == null
      )
    ])
    error_message = "Члены группы должны ссылаться на объекты из YAML. Ссылка группы на себя запрещена."
  }
}
