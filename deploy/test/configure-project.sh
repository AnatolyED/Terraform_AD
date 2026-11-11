#!/usr/bin/env bash
set -euo pipefail
umask 077

directory=$(cd -- "$(dirname -- "$0")" && pwd)
source "$(realpath -- "$1")"
project_runtime=$2
runtime=$(realpath -m -- "${LAB_RUNTIME:-$directory/.lab}")
tls="$runtime/tls"
gitlab_url="https://$LAB_GITLAB_HOST:${LAB_GITLAB_PORT:-8929}"
vault_url="https://$LAB_VAULT_HOST:${LAB_VAULT_PORT:-8200}"
project_id=$(cat "$project_runtime/project-id")
branch=${LAB_GIT_BRANCH:-Test}
domain=${LAB_AD_DOMAIN:-lab.example}
base_dn=${LAB_AD_MANAGED_BASE_DN:-OU=TerraformLab,DC=lab,DC=example}
domain_dn="DC=${domain//./,DC=}"
identity="OU=${LAB_IDENTITY_OU:-Identity},$base_dn"
cluster=vault-01
scope="vault/$cluster"
gitlab_token=$(cat "$project_runtime/gitlab-token")
vault_token=${LAB_VAULT_ADMIN_TOKEN:-}
if [[ -z $vault_token && -s $runtime/vault-init.json ]]; then
  vault_token=$(jq -er '.root_token' "$runtime/vault-init.json")
fi
if [[ -z $vault_token ]]; then read -rsp 'Test Vault bootstrap token: ' vault_token; printf '\n'; fi
if [[ -z ${LAB_AD_TF_PASSWORD:-} ]]; then read -rsp 'Terraform bind password: ' LAB_AD_TF_PASSWORD; printf '\n'; fi
if [[ -z ${LAB_AD_AUTH_PASSWORD:-} ]]; then read -rsp 'Vault LDAP bind password: ' LAB_AD_AUTH_PASSWORD; printf '\n'; fi
if [[ -z ${LAB_AD_ROTATION_PASSWORD:-} ]]; then read -rsp 'Vault rotation bind password: ' LAB_AD_ROTATION_PASSWORD; printf '\n'; fi
[[ -n $vault_token && -n $LAB_AD_TF_PASSWORD && -n $LAB_AD_AUTH_PASSWORD && -n $LAB_AD_ROTATION_PASSWORD ]]

vault_api() {
  local method=$1 path=$2
  shift 2
  curl -fsS --max-time 20 --cacert "$tls/lab-ca.pem" -H @<(printf 'X-Vault-Token: %s\n' "$vault_token") \
    -H 'Content-Type: application/json' -X "$method" "$vault_url/v1/$path" "$@"
}
gitlab_api() {
  local method=$1 path=$2
  shift 2
  curl -fsS --max-time 20 --cacert "$tls/lab-ca.pem" -H @<(printf 'PRIVATE-TOKEN: %s\n' "$gitlab_token") \
    -H 'Content-Type: application/json' -X "$method" "$gitlab_url/api/v4/projects/$project_id/$path" "$@"
}
variable() {
  local name=$1 value=$2 environment=$3 secret=${4:-false} type=${5:-env_var}
  local filter
  filter=$(jq -rn --arg scope "$environment" '$scope|@uri')
  if gitlab_api GET "variables/$name?filter%5Benvironment_scope%5D=$filter" >/dev/null 2>&1; then
    printf '%s' "$value" | jq -Rsc --arg type "$type" '{value:.,raw:true,protected:true,variable_type:$type}' |
      gitlab_api PUT "variables/$name?filter%5Benvironment_scope%5D=$filter" --data-binary @- >/dev/null
    return
  fi
  printf '%s' "$value" | jq -Rsc --arg key "$name" --arg environment "$environment" --arg type "$type" --argjson secret "$secret" \
    '{key:$key,value:.,environment_scope:$environment,protected:true,raw:true,masked_and_hidden:$secret,variable_type:$type}' |
    gitlab_api POST variables --data-binary @- >/dev/null
}

if ! vault_api GET sys/auth | jq -e '(.data // .)["gitlab-jwt/"].type == "jwt"' >/dev/null; then
  vault_api POST sys/auth/gitlab-jwt --data '{"type":"jwt"}' >/dev/null
fi
if configured=$(vault_api GET auth/gitlab-jwt/role/terraform-plan 2>/dev/null); then
  jq -e --arg id "$project_id" '.data.bound_claims.project_id == $id' <<< "$configured" >/dev/null || {
    printf 'Vault already belongs to a different test project\n' >&2
    exit 1
  }
fi
jq -nc --arg issuer "$gitlab_url" --rawfile ca "$tls/lab-ca.pem" \
  '{oidc_discovery_url:$issuer,bound_issuer:$issuer,oidc_discovery_ca_pem:$ca}' |
  vault_api POST auth/gitlab-jwt/config --data-binary @- >/dev/null
for phase in plan apply; do
  jq -nc --rawfile policy "$directory/../../config/vault/terraform-$phase.hcl" '{policy:$policy}' |
    vault_api PUT "sys/policies/acl/terraform-ad-$phase" --data-binary @- >/dev/null
  action=verify
  policies='["terraform-ad-plan"]'
  if [[ $phase == apply ]]; then action=start; policies='["terraform-ad-plan","terraform-ad-apply"]'; fi
  jq -nc --arg aud "$gitlab_url/terraform/vault/$phase" --arg project "$project_id" --arg branch "$branch" \
    --arg env "$scope" --arg action "$action" --argjson policies "$policies" \
    '{role_type:"jwt",user_claim:"sub",bound_audiences:[$aud],bound_claims:{project_id:$project,ref_type:"branch",ref:$branch,ref_protected:"true",environment:$env,environment_action:$action},token_policies:$policies,token_explicit_max_ttl:900}' |
    vault_api POST "auth/gitlab-jwt/role/terraform-$phase" --data-binary @- >/dev/null
done

passwords="$project_runtime/test-passwords.json"
if [[ ! -s $passwords ]]; then
  jq -nc --arg reader "T1a!$(openssl rand -hex 18)" --arg outsider "T2a!$(openssl rand -hex 18)" --arg app "T3a!$(openssl rand -hex 18)" \
    '{"lab-reader":$reader,"lab-outsider":$outsider,"lab-app":$app}' > "$passwords"
fi
ad_ca=$(tr -d '\r' < "$LAB_AD_CA_FILE")
ad_ca+=$'\n'
vault_ca=$(cat "$tls/lab-ca.pem")
vault_ca+=$'\n'
variable AD_DEPLOY_ENABLED true '*'
variable AD_DEPLOY_ENVIRONMENT lab '*'
variable VAULT_DEPLOY_MODE single '*'
variable VAULT_TARGET_ID "$cluster" '*'
variable AD_USERNAME "${LAB_AD_TF_UPN:-svc-terraform@$domain}" ad/lab
variable AD_PASSWORD "$LAB_AD_TF_PASSWORD" ad/lab true
variable AD_TLS_CA_CERT_FILE "$ad_ca" ad/lab false file
variable TF_VAR_ad_ldap_url "ldaps://$LAB_AD_HOST:636" ad/lab
variable TF_VAR_ad_managed_base_dn "$base_dn" ad/lab
variable TF_VAR_ad_user_passwords "$(cat "$passwords")" ad/lab true
variable VAULT_CACERT "$vault_ca" "$scope" false file
variable TF_VAR_vault_ldap_url "ldaps://$LAB_AD_HOST:636" "$scope"
variable TF_VAR_vault_ldap_ca_file "$ad_ca" "$scope" false file
variable TF_VAR_vault_ldap_auth_bind_dn "${LAB_AD_AUTH_DN:-CN=svc-auth,CN=Users,$domain_dn}" "$scope"
variable TF_VAR_vault_ldap_auth_bind_password "$LAB_AD_AUTH_PASSWORD" "$scope" true
variable TF_VAR_vault_ldap_auth_user_dn "$identity" "$scope"
variable TF_VAR_vault_ldap_auth_group_dn "OU=Groups,$identity" "$scope"
variable TF_VAR_vault_ldap_secrets_bind_dn "${LAB_AD_ROTATION_DN:-CN=svc-rotation,CN=Users,$domain_dn}" "$scope"
variable TF_VAR_vault_ldap_secrets_bind_password "$LAB_AD_ROTATION_PASSWORD" "$scope" true
variable TF_VAR_vault_ldap_secrets_user_dn "OU=Services,$identity" "$scope"
