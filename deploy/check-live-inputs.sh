#!/bin/sh
set -eu

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

require_file() {
  [ -s "$1" ] || fail "Required file is missing or empty: $1"
}

case "$1" in
  infra/active-directory)
    printf '%s\n' "$TF_VAR_ad_inventory_environment" | grep -Eq '^[a-z][a-z0-9-]*$' || fail 'Invalid AD inventory environment'
    directory="$TF_VAR_inventory_root/active-directory/$TF_VAR_ad_inventory_environment"
    for file in ou.yaml groups.yaml users.yaml; do
      require_file "$directory/$file"
    done
    : "${AD_USERNAME:?Required: AD_USERNAME}" "${AD_PASSWORD:?Required: AD_PASSWORD}"
    : "${TF_VAR_ad_ldap_url:?Required: TF_VAR_ad_ldap_url}" "${TF_VAR_ad_managed_base_dn:?Required: TF_VAR_ad_managed_base_dn}"
    require_file "${AD_TLS_CA_CERT_FILE:?Required: AD_TLS_CA_CERT_FILE}"
    ;;
  infra/vault)
    require_file "$TF_VAR_inventory_root/vault/clusters.yaml"
    : "${TF_VAR_vault_cluster_id:?Required: TF_VAR_vault_cluster_id}"
    : "${TF_VAR_vault_ldap_url:?Required: TF_VAR_vault_ldap_url}"
    : "${TF_VAR_vault_ldap_auth_bind_dn:?Required: TF_VAR_vault_ldap_auth_bind_dn}"
    : "${TF_VAR_vault_ldap_auth_bind_password:?Required: TF_VAR_vault_ldap_auth_bind_password}"
    : "${TF_VAR_vault_ldap_auth_user_dn:?Required: TF_VAR_vault_ldap_auth_user_dn}"
    : "${TF_VAR_vault_ldap_auth_group_dn:?Required: TF_VAR_vault_ldap_auth_group_dn}"
    : "${TF_VAR_vault_ldap_secrets_bind_dn:?Required: TF_VAR_vault_ldap_secrets_bind_dn}"
    : "${TF_VAR_vault_ldap_secrets_bind_password:?Required: TF_VAR_vault_ldap_secrets_bind_password}"
    : "${TF_VAR_vault_ldap_secrets_user_dn:?Required: TF_VAR_vault_ldap_secrets_user_dn}"
    : "${TF_VAR_vault_gitlab_jwt:?Required: GitLab ID token}"
    require_file "${VAULT_CACERT:?Required: VAULT_CACERT}"
    require_file "${TF_VAR_vault_ldap_ca_file:?Required: TF_VAR_vault_ldap_ca_file}"
    ;;
  *) fail 'Unknown Terraform root' ;;
esac
