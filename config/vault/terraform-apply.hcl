path "sys/auth/ad-ldap" {
  capabilities = ["create", "update", "sudo"]
}

path "sys/mounts/ad-creds" {
  capabilities = ["create", "read", "update", "sudo"]
}

path "sys/policy/ad-*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "sys/policies/acl/ad-*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "sys/policies/password/terraform-ad-credentials" {
  capabilities = ["create", "read", "update", "delete"]
}

path "auth/ad-ldap/config" {
  capabilities = ["create", "read", "update"]
}

path "auth/ad-ldap/groups/*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "ad-creds/config" {
  capabilities = ["create", "read", "update"]
}

path "ad-creds/static-role/*" {
  capabilities = ["create", "read", "update"]
}
