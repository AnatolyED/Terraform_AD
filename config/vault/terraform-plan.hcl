path "sys/auth" {
  capabilities = ["read"]
}

path "sys/mounts" {
  capabilities = ["read"]
}

path "sys/mounts/auth/ad-ldap/tune" {
  capabilities = ["read", "sudo"]
}

path "sys/mounts/auth/ad-ldap" {
  capabilities = ["read"]
}

path "sys/mounts/ad-creds" {
  capabilities = ["read"]
}

path "sys/mounts/ad-creds/tune" {
  capabilities = ["read"]
}

path "sys/policy/ad-*" {
  capabilities = ["read"]
}

path "sys/policies/acl/ad-*" {
  capabilities = ["read"]
}

path "sys/policies/password/terraform-ad-credentials" {
  capabilities = ["read"]
}

path "auth/ad-ldap/config" {
  capabilities = ["read"]
}

path "auth/ad-ldap/groups/*" {
  capabilities = ["read"]
}

path "ad-creds/config" {
  capabilities = ["read"]
}

path "ad-creds/static-role/*" {
  capabilities = ["read"]
}
