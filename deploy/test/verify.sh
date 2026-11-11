#!/usr/bin/env bash
set -euo pipefail
umask 077

directory=$(cd -- "$(dirname -- "$0")" && pwd)
source "$(realpath -- "$1")"
runtime=$(realpath -m -- "${LAB_RUNTIME:-$directory/.lab}")
project_runtime="$runtime/${LAB_PROJECT_PATH:-terraform-ad-test}"
project_id=$(cat "$project_runtime/project-id")
gitlab_token=$(cat "$project_runtime/gitlab-token")
gitlab_url="https://$LAB_GITLAB_HOST:${LAB_GITLAB_PORT:-8929}/api/v4/projects/$project_id"
vault_url="https://$LAB_VAULT_HOST:${LAB_VAULT_PORT:-8200}/v1"
ca="$runtime/tls/lab-ca.pem"
domain=${LAB_AD_DOMAIN:-lab.example}
[[ $domain =~ ^[a-zA-Z0-9-]+\.(example|test)$ ]]
prefix=${LAB_ACCOUNT_PREFIX:-lab}
base_dn=${LAB_AD_MANAGED_BASE_DN:-OU=TerraformLab,DC=lab,DC=example}
probe="OU=ProtectedProbe,OU=${LAB_IDENTITY_OU:-Identity},$base_dn"
export LDAPTLS_CACERT="$LAB_AD_CA_FILE" LDAPTLS_REQCERT=demand
ldap_url="ldaps://$LAB_AD_HOST:636"
command -v ldapwhoami >/dev/null
command -v ldapdelete >/dev/null
ldap_password=$(mktemp "$project_runtime/ldap-password.XXXXXX")
trap 'rm -f "$ldap_password"' EXIT

gitlab_api() {
  local method=$1 path=$2
  shift 2
  curl -fsS --max-time 25 --cacert "$ca" -H "PRIVATE-TOKEN: $gitlab_token" -H 'Content-Type: application/json' \
    -X "$method" "$gitlab_url/$path" "$@"
}
login() {
  jq -ce --arg user "$1" '{password:.[$user]}' "$project_runtime/test-passwords.json" |
    curl -fsS --max-time 15 --cacert "$ca" -H 'Content-Type: application/json' --data-binary @- "$vault_url/auth/ad-ldap/login/$prefix-${1#lab-}"
}
credential() {
  curl -fsS --max-time 15 --cacert "$ca" -H "X-Vault-Token: $reader_token" "$vault_url/ad-creds/static-cred/lab-app"
}
bind() {
  printf '%s' "$2" > "$ldap_password"
  ldapwhoami -x -H "$ldap_url" -D "$1@$domain" -y "$ldap_password" >/dev/null
}

reader=$(login lab-reader)
jq -e '.auth.policies | index("ad-lab-app-read") != null' <<< "$reader" >/dev/null
reader_token=$(jq -er '.auth.client_token' <<< "$reader")
outsider_token=$(login lab-outsider | jq -er '.auth.client_token')
denied=$(curl -sS --max-time 15 --cacert "$ca" -o /dev/null -w '%{http_code}' \
  -H "X-Vault-Token: $outsider_token" "$vault_url/ad-creds/static-cred/lab-app")
[[ $denied == 403 ]]
printf 'LDAP policy granted to reader and denied to outsider\n'

ad_state=$(gitlab_api GET terraform/state/ad-lab)
vault_state=$(gitlab_api GET terraform/state/vault-vault-01)
[[ $(jq -er '.lineage' <<< "$ad_state") != "$(jq -er '.lineage' <<< "$vault_state")" ]]
jq -e --arg probe "$probe" 'any(.resources[]; .type == "ad_ou" and any(.instances[]; .index_key == "protected-probe" and .attributes.protected == true and (.attributes.dn | ascii_downcase) == ($probe | ascii_downcase)))' <<< "$ad_state" >/dev/null
jq -e --arg user "$prefix-app" 'any(.resources[]; .type == "vault_ldap_secret_backend_static_role" and any(.instances[]; .attributes.username == $user))' <<< "$vault_state" >/dev/null
printf 'AD and Vault state have distinct lineages\n'

if [[ -z ${LAB_AD_TF_PASSWORD:-} ]]; then read -rsp 'Terraform bind password for protected OU check: ' LAB_AD_TF_PASSWORD; printf '\n'; fi
terraform_upn=${LAB_AD_TF_UPN:-svc-terraform@$domain}
printf '%s' "$LAB_AD_TF_PASSWORD" > "$ldap_password"
ldapwhoami -x -H "$ldap_url" -D "$terraform_upn" -y "$ldap_password" >/dev/null
ldapsearch -LLL -x -H "$ldap_url" -D "$terraform_upn" -y "$ldap_password" \
  -b "$probe" -s base '(objectClass=organizationalUnit)' dn | grep -q '^dn:'
if deletion=$(ldapdelete -x -H "$ldap_url" -D "$terraform_upn" -y "$ldap_password" "$probe" 2>&1); then
  printf 'Protected test OU was unexpectedly deleted\n' >&2
  exit 1
fi
grep -Eqi 'insufficient access|access is denied' <<< "$deletion"
printf 'Protected test OU refused deletion by delegated account\n'

first=$(credential)
first_password=$(jq -er '.data.password' <<< "$first")
first_rotation=$(jq -er '.data.last_vault_rotation' <<< "$first")
bind "$prefix-app" "$first_password"
for attempt in $(seq 1 35); do
  next=$(credential)
  next_password=$(jq -er '.data.password' <<< "$next")
  if [[ $next_password != "$first_password" && $(jq -er '.data.last_vault_rotation' <<< "$next") != "$first_rotation" ]] && bind "$prefix-app" "$next_password"; then
    printf 'Scheduled rotation and new LDAPS bind verified\n'
    break
  fi
  [[ $attempt -lt 35 ]] || { printf 'Scheduled rotation was not observed\n' >&2; exit 1; }
  sleep 4
done

branch=${LAB_GIT_BRANCH:-Test}
if [[ ! -s $project_runtime/repeat-pipeline-id ]]; then
  jq -nc --arg branch "$branch" '{ref:$branch}' | gitlab_api POST pipeline --data-binary @- |
    jq -er '.id' > "$project_runtime/repeat-pipeline-id"
fi
repeat=$(cat "$project_runtime/repeat-pipeline-id")
for attempt in $(seq 1 90); do
  jobs=$(gitlab_api GET "pipelines/$repeat/jobs?per_page=100")
  jq -e 'all(.[]; .status != "failed" and .status != "canceled")' <<< "$jobs" >/dev/null
  plans=$(jq -r '.[] | select((.name == "ad:plan" or .name == "vault:plan: [vault-01]") and .status == "success") | .id' <<< "$jobs")
  if [[ $(wc -w <<< "$plans") -eq 2 ]]; then
    while read -r id; do
      trace=$(gitlab_api GET "jobs/$id/trace")
      grep -Fq 'No changes.' <<< "$trace"
    done <<< "$plans"
    printf 'Repeat plans show no changes for AD and Vault\n'
    exit 0
  fi
  sleep 4
done
printf 'Timed out waiting for repeat plans\n' >&2
exit 1
