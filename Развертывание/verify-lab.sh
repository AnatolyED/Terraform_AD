#!/usr/bin/env bash
set -euo pipefail
umask 077

directory=$(cd -- "$(dirname -- "$0")" && pwd)
runtime=${1:-"$directory/.lab"}
command -v ldapwhoami >/dev/null
port=$(sed -n 's/^LAB_GITLAB_PORT=//p' "$runtime/compose.env")
host=$(sed -n 's/^LAB_GITLAB_ACCESS_HOST=//p' "$runtime/compose.env")
ad_host=$(sed -n 's/^LAB_AD_HOST=//p' "$runtime/compose.env")
domain=$(sed -n 's/^LAB_AD_DOMAIN=//p' "$runtime/compose.env")
token=$(cat -- "$runtime/gitlab-token")
project=$(cat -- "$runtime/project-id")
compose() {
  docker compose --env-file "$runtime/compose.env" -f "$directory/compose.yaml" "$@"
}
read_credential() {
  local cluster=$1 service=$2 vault_token=$3
  printf '%s\n' "$vault_token" | compose exec -T "$cluster" sh -ec \
    'IFS= read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault read -format=json "$1"' vault "ad-creds/static-cred/$service"
}
bind_ad() {
  local user=$1 password=$2 file status=0
  file=$(mktemp "$runtime/ldap-password.XXXXXX")
  printf '%s' "$password" > "$file"
  LDAPTLS_CACERT="$runtime/tls/ad-ca.pem" LDAPTLS_REQCERT=demand \
    ldapwhoami -x -H "ldaps://$ad_host:636" -D "$user@$domain" -y "$file" >/dev/null || status=$?
  rm -f -- "$file"
  return "$status"
}

declare -A vault_tokens passwords timestamps verified
lineages=()
for suffix in 01 02 03 04 05; do
  cluster="vault-$suffix"
  service="lab-app-$suffix"
  reader=$(jq -er --arg cluster "$cluster" '.[$cluster].user' "$runtime/readers.json")
  response=$(jq -ce --arg cluster "$cluster" '.[$cluster] | {password}' "$runtime/readers.json" |
    compose exec -T "$cluster" vault write -format=json "auth/ad-ldap/login/$reader" -)
  jq -e --arg policy "ad-$service-read" '.auth.policies | index($policy) != null' <<< "$response" >/dev/null
  vault_tokens[$cluster]=$(jq -er '.auth.client_token' <<< "$response")
  credential=$(read_credential "$cluster" "$service" "${vault_tokens[$cluster]}")
  jq -e --arg service "$service" '.data.username == $service and .data.rotation_period == 60' <<< "$credential" >/dev/null
  passwords[$cluster]=$(jq -er '.data.password' <<< "$credential")
  timestamps[$cluster]=$(jq -er '.data.last_vault_rotation' <<< "$credential")
  bind_ad "$service" "${passwords[$cluster]}"
  state=$(curl -fsS --max-time 25 --cacert "$runtime/tls/gitlab-ca.pem" --header "PRIVATE-TOKEN: $token" \
    "https://${host:-localhost}:$port/api/v4/projects/$project/terraform/state/vault-$cluster")
  jq -e --arg service "$service" 'any(.resources[]; .type == "vault_ldap_secret_backend_static_role" and any(.instances[]; .attributes.username == $service))' <<< "$state" >/dev/null
  lineages+=("$(jq -er '.lineage' <<< "$state")")
  printf '%s LDAP, policy, service bind, and state verified.\n' "$cluster"
done
[[ $(printf '%s\n' "${lineages[@]}" | sort -u | wc -l) -eq 5 ]]
rotation_count=0
for attempt in $(seq 1 30); do
  for suffix in 01 02 03 04 05; do
    cluster="vault-$suffix"
    service="lab-app-$suffix"
    [[ -z ${verified[$cluster]:-} ]] || continue
    credential=$(read_credential "$cluster" "$service" "${vault_tokens[$cluster]}")
    next_password=$(jq -er '.data.password' <<< "$credential")
    next_timestamp=$(jq -er '.data.last_vault_rotation' <<< "$credential")
    if [[ $next_password != "${passwords[$cluster]}" && $next_timestamp != "${timestamps[$cluster]}" ]] && bind_ad "$service" "$next_password"; then
      verified[$cluster]=true
      ((rotation_count += 1))
      printf '%s scheduled rotation and new LDAPS bind verified.\n' "$cluster"
    fi
  done
  if [[ $rotation_count -eq 5 ]]; then
    exit 0
  fi
  sleep 4
done
printf 'Scheduled rotation was not observed on all five Vault instances.\n' >&2
exit 1
