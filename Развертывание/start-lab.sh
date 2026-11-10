#!/usr/bin/env bash
set -euo pipefail
umask 077

directory=$(cd -- "$(dirname -- "$0")" && pwd)
repo=$(git -C "$directory" rev-parse --show-toplevel)
[[ -f $repo/fix/ad-provider.lock.hcl ]]
bundle=$(cd -- "${1:?Pass the offline bundle directory}" && pwd)
apply=${2:-}
[[ -z $apply || $apply == --apply ]]
for tool in docker git curl jq openssl sha256sum tar; do
  command -v "$tool" >/dev/null || { printf 'Missing command: %s\n' "$tool" >&2; exit 1; }
done

: "${LAB_AD_HOST:?Set the test Windows DC FQDN}"
: "${LAB_AD_IP:?Set the test Windows DC IP}"
: "${LAB_AD_CA_FILE:?Set the path to the LDAPS CA PEM}"
[[ -s $LAB_AD_CA_FILE ]]
LAB_AD_DOMAIN=${LAB_AD_DOMAIN:-lab.example}
LAB_AD_BASE_DN=${LAB_AD_BASE_DN:-OU=TerraformLab,DC=lab,DC=example}
LAB_AD_TF_UPN=${LAB_AD_TF_UPN:-svc-terraform@$LAB_AD_DOMAIN}
LAB_AD_AUTH_DN=${LAB_AD_AUTH_DN:-CN=svc-auth,CN=Users,DC=lab,DC=example}
LAB_AD_ROTATION_DN=${LAB_AD_ROTATION_DN:-CN=svc-rotation,CN=Users,DC=lab,DC=example}
LAB_GITLAB_PORT=${LAB_GITLAB_PORT:-8929}
LAB_GITLAB_ACCESS_HOST=${LAB_GITLAB_ACCESS_HOST:-localhost}
LAB_RUNTIME=$(realpath -m "${LAB_RUNTIME:-"$directory/.lab"}")
if [[ -e $LAB_RUNTIME/compose.env ]]; then
  printf 'This lab has already been initialized at %s.\n' "$LAB_RUNTIME" >&2
  exit 1
fi
mkdir -p "$LAB_RUNTIME/tls" "$LAB_RUNTIME/project"
tr -d '\r' < "$LAB_AD_CA_FILE" > "$LAB_RUNTIME/tls/ad-ca.pem"
timeout 12 openssl s_client -connect "$LAB_AD_IP:636" -servername "$LAB_AD_HOST" \
  -verify_hostname "$LAB_AD_HOST" -CAfile "$LAB_RUNTIME/tls/ad-ca.pem" -verify_return_error \
  </dev/null > "$LAB_RUNTIME/ldaps-check.log" 2>&1

if [[ -z ${LAB_AD_TF_PASSWORD:-} ]]; then
  read -rsp 'Terraform AD bind password: ' LAB_AD_TF_PASSWORD
  printf '\n'
fi
if [[ -z ${LAB_AD_AUTH_PASSWORD:-} ]]; then
  read -rsp 'Vault LDAP auth bind password: ' LAB_AD_AUTH_PASSWORD
  printf '\n'
fi
if [[ -z ${LAB_AD_ROTATION_PASSWORD:-} ]]; then
  read -rsp 'Vault LDAP rotation bind password: ' LAB_AD_ROTATION_PASSWORD
  printf '\n'
fi
[[ -n $LAB_AD_TF_PASSWORD && -n $LAB_AD_AUTH_PASSWORD && -n $LAB_AD_ROTATION_PASSWORD ]]

(
  cd -- "$bundle"
  sha256sum -c SHA256SUMS
  docker image load -i images.tar
)

tls="$LAB_RUNTIME/tls"
openssl req -x509 -newkey rsa:3072 -nodes -days 30 -subj '/CN=Terraform AD Lab CA' \
  -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -keyout "$tls/ca.key" -out "$tls/gitlab-ca.pem" 2>"$LAB_RUNTIME/cert.log"
openssl req -new -newkey rsa:3072 -nodes -subj '/CN=gitlab.terraform.test' \
  -keyout "$tls/gitlab.key" -out "$tls/gitlab.csr" 2>>"$LAB_RUNTIME/cert.log"
printf '%s\n' 'subjectAltName=DNS:gitlab.terraform.test,DNS:localhost,IP:127.0.0.1' \
  'extendedKeyUsage=serverAuth' > "$tls/gitlab.ext"
openssl x509 -req -in "$tls/gitlab.csr" -CA "$tls/gitlab-ca.pem" -CAkey "$tls/ca.key" \
  -CAcreateserial -days 30 -sha256 -extfile "$tls/gitlab.ext" -out "$tls/gitlab.pem" 2>>"$LAB_RUNTIME/cert.log"
chmod 0644 "$tls/gitlab-ca.pem"

compose_env="$LAB_RUNTIME/compose.env"
{
  printf 'LAB_RUNTIME=%s\nLAB_AD_HOST=%s\nLAB_AD_IP=%s\nLAB_AD_DOMAIN=%s\nLAB_GITLAB_PORT=%s\nLAB_GITLAB_ACCESS_HOST=%s\n' "$LAB_RUNTIME" "$LAB_AD_HOST" "$LAB_AD_IP" "$LAB_AD_DOMAIN" "$LAB_GITLAB_PORT" "$LAB_GITLAB_ACCESS_HOST"
  for suffix in 01 02 03 04 05; do
    printf 'VAULT_ROOT_%s=lab-%s\n' "$suffix" "$(openssl rand -hex 32)"
  done
} > "$compose_env"
compose() {
  docker compose --env-file "$compose_env" -f "$directory/compose.yaml" "$@"
}
compose up -d --pull never

issuer="https://gitlab.terraform.test:$LAB_GITLAB_PORT"
host_url="https://$LAB_GITLAB_ACCESS_HOST:$LAB_GITLAB_PORT"
for attempt in $(seq 1 90); do
  if curl -fsS --max-time 5 --cacert "$tls/gitlab-ca.pem" "$host_url/.well-known/openid-configuration" |
    jq -e --arg issuer "$issuer" '.issuer == $issuer' >/dev/null; then
    break
  fi
  [[ $attempt -lt 90 ]]
  sleep 5
done

token=$(compose exec -T gitlab gitlab-rails runner - <<'RUBY'
root = User.find_by_username("root")
ApplicationSetting.current.update!(signup_enabled: false)
token = root.personal_access_tokens.create!(name: "terraform-ad-lab", scopes: [:api, :create_runner, :write_repository], expires_at: Date.current + 2)
puts token.token
RUBY
)
[[ -n $token ]]
printf '%s\n' "$token" > "$LAB_RUNTIME/gitlab-token"
api() {
  local method=$1 path=$2
  shift 2
  curl -fsS --max-time 45 --cacert "$tls/gitlab-ca.pem" --header "PRIVATE-TOKEN: $token" \
    --header 'Content-Type: application/json' --request "$method" "$host_url/api/v4/$path" "$@"
}
project=$(api POST projects --data '{"name":"Terraform AD Lab","path":"terraform-ad-lab","visibility":"private","shared_runners_enabled":false}')
project_id=$(jq -er '.id' <<< "$project")
printf '%s\n' "$project_id" > "$LAB_RUNTIME/project-id"
runner=$(jq -nc --argjson id "$project_id" '{runner_type:"project_type",project_id:$id,tag_list:"terraform-docker,terraform-deploy",description:"Terraform lab Docker Runner",run_untagged:false,locked:true,access_level:"ref_protected"}')
runner_token=$(api POST user/runners --data "$runner" | jq -er '.token')
compose exec -T runner gitlab-runner register --non-interactive --url "$issuer" \
  --token "$runner_token" --executor docker --tls-ca-file /lab-ca.pem \
  --docker-image terraform-ad-lab/terraform:1.17.1 --docker-helper-image terraform-ad-lab/runner-helper:19.5.1 \
  --docker-pull-policy never --docker-network-mode terraform-ad-lab-network \
  --docker-extra-hosts "$LAB_AD_HOST:$LAB_AD_IP" --docker-volumes "$bundle/provider-mirror:/providers:ro" \
  > "$LAB_RUNTIME/runner-registration.log" 2>&1
compose restart runner
unset runner_token

variable() {
  local name=$1 value=$2 scope=$3 secret=${4:-false} type=${5:-env_var}
  jq -nc --arg key "$name" --arg value "$value" --arg scope "$scope" --arg type "$type" \
    --argjson secret "$secret" '{key:$key,value:$value,environment_scope:$scope,variable_type:$type,protected:true,raw:true,masked_and_hidden:$secret}' |
    api POST "projects/$project_id/variables" --data-binary @- >/dev/null
}
vault_admin() {
  local cluster=$1
  shift
  compose exec -T "$cluster" sh -ec 'export VAULT_TOKEN="$VAULT_DEV_ROOT_TOKEN_ID"; exec vault "$@"' vault "$@"
}

lab_repo="$LAB_RUNTIME/project"
git -C "$repo" archive HEAD .gitlab-ci.yml .gitattributes .gitignore config infra inventory modules | tar -x -C "$lab_repo"
sed -i 's|name: docker.io/hashicorp/terraform:.*|name: terraform-ad-lab/terraform:1.17.1|' "$lab_repo/.gitlab-ci.yml"
sed -i '/^    - export TF_CLI_CONFIG_FILE=/a\    - export SSL_CERT_FILE="$CI_SERVER_TLS_CA_FILE"' "$lab_repo/.gitlab-ci.yml"
for file in "$lab_repo/infra/active-directory/versions.tf" "$lab_repo/modules/active-directory/versions.tf"; do
  sed -i 's/version = "0\.5\.0"/version = "0.6.0-ou-dacl.lab.1"/' "$file"
done
cp -- "$repo/fix/ad-provider.lock.hcl" "$lab_repo/infra/active-directory/.terraform.lock.hcl"
printf '%s\n' 'disable_checkpoint = true' 'provider_installation {' '  filesystem_mirror {' '    path = "/providers"' '  }' '}' > "$lab_repo/config/terraform.tfrc"

lab_inventory="$lab_repo/inventory/active-directory/lab"
printf 'identity:\n  name: Identity\nusers:\n  name: Users\n  parent_id: identity\ngroups:\n  name: Groups\n  parent_id: identity\nservices:\n  name: Services\n  parent_id: identity\n' > "$lab_inventory/organizational-units.yaml"
: > "$lab_inventory/users.yaml"
: > "$lab_inventory/groups.yaml"
: > "$lab_repo/inventory/vault/clusters.yaml"
passwords='{}'
readers='{}'
identity="OU=Identity,$LAB_AD_BASE_DN"
ad_ca=$(cat -- "$tls/ad-ca.pem")
ad_ca+=$'\n'
for suffix in 01 02 03 04 05; do
  cluster="vault-$suffix"
  reader="lab-reader-$suffix"
  service="lab-app-$suffix"
  group="lab-readers-$suffix"
  reader_password="T1a!$(openssl rand -hex 14)"
  app_password="T2a!$(openssl rand -hex 14)"
  passwords=$(jq -c --arg reader "$reader" --arg app "$service" --arg rp "$reader_password" --arg ap "$app_password" '.+{($reader):$rp,($app):$ap}' <<< "$passwords")
  readers=$(jq -c --arg key "$cluster" --arg user "$reader" --arg password "$reader_password" '.+{($key):{user:$user,password:$password}}' <<< "$readers")
  for entry in "$reader:users" "$service:services"; do
    user=${entry%%:*}
    ou=${entry##*:}
    cat >> "$lab_inventory/users.yaml" <<EOF
$user:
  name: $user
  sam_account_name: $user
  principal_name: $user@$LAB_AD_DOMAIN
  ou_id: $ou
  enabled: true
  change_password_at_logon: false
EOF
  done
  cat >> "$lab_inventory/groups.yaml" <<EOF
$group:
  name: $group
  sam_account_name: $group
  ou_id: groups
  membership:
    user_ids: [$reader]
    group_ids: []
EOF
  cat >> "$lab_repo/inventory/vault/clusters.yaml" <<EOF
$cluster:
  address: https://$cluster:8200
  ad_environment: lab
  auth_bind_password_version: 1
  secrets_bind_password_version: 1
  policies:
    $service-read:
      ad-creds/static-cred/$service: [read]
  group_policies:
    $group: [$service-read]
  static_roles:
    $service:
      user_id: $service
      rotation_period_seconds: 60
EOF
  compose cp "$cluster:/tmp/vault-ca.pem" "$tls/$cluster.pem"
  scope="vault/$cluster"
  variable VAULT_CACERT "$(cat -- "$tls/$cluster.pem")" "$scope" false file
  variable TF_VAR_vault_ldap_url "ldaps://$LAB_AD_HOST:636" "$scope"
  variable TF_VAR_vault_ldap_ca_file "$ad_ca" "$scope" false file
  variable TF_VAR_vault_ldap_auth_bind_dn "$LAB_AD_AUTH_DN" "$scope"
  variable TF_VAR_vault_ldap_auth_bind_password "$LAB_AD_AUTH_PASSWORD" "$scope" true
  variable TF_VAR_vault_ldap_auth_user_dn "$identity" "$scope"
  variable TF_VAR_vault_ldap_auth_group_dn "OU=Groups,$identity" "$scope"
  variable TF_VAR_vault_ldap_secrets_bind_dn "$LAB_AD_ROTATION_DN" "$scope"
  variable TF_VAR_vault_ldap_secrets_bind_password "$LAB_AD_ROTATION_PASSWORD" "$scope" true
  variable TF_VAR_vault_ldap_secrets_user_dn "OU=Services,$identity" "$scope"
  vault_admin "$cluster" auth enable -path=gitlab-jwt jwt
  vault_admin "$cluster" write auth/gitlab-jwt/config oidc_discovery_url="$issuer" bound_issuer="$issuer" oidc_discovery_ca_pem=@/gitlab-ca.pem
  for phase in plan apply; do
    vault_admin "$cluster" policy write "terraform-ad-$phase" - < "$lab_repo/config/vault/terraform-$phase.hcl"
    action=verify
    policies='["terraform-ad-plan"]'
    if [[ $phase == apply ]]; then
      action=start
      policies='["terraform-ad-plan","terraform-ad-apply"]'
    fi
    jq -nc --arg audience "$issuer/terraform/vault/$phase" --arg project "$project_id" \
      --arg cluster "$cluster" --arg action "$action" --argjson policies "$policies" \
      '{role_type:"jwt",user_claim:"sub",bound_audiences:[$audience],bound_claims:{project_id:$project,ref_type:"branch",ref:"main",ref_protected:"true",environment:("vault/"+$cluster),environment_action:$action},token_policies:$policies,token_explicit_max_ttl:900}' |
      vault_admin "$cluster" write "auth/gitlab-jwt/role/terraform-$phase" -
  done
done
printf '%s\n' "$readers" > "$LAB_RUNTIME/readers.json"
variable AD_DEPLOY_ENABLED true '*'
variable VAULT_DEPLOY_MODE all '*'
variable AD_USERNAME "$LAB_AD_TF_UPN" ad/lab
variable AD_PASSWORD "$LAB_AD_TF_PASSWORD" ad/lab true
variable AD_TLS_CA_CERT_FILE "$ad_ca" ad/lab false file
variable TF_VAR_ad_ldap_url "ldaps://$LAB_AD_HOST:636" ad/lab
variable TF_VAR_ad_managed_base_dn "$LAB_AD_BASE_DN" ad/lab
variable TF_VAR_ad_user_passwords "$passwords" ad/lab true

git -C "$lab_repo" init --initial-branch main
git -C "$lab_repo" -c user.name='Terraform AD Lab' -c user.email=lab@localhost add --all
git -C "$lab_repo" -c user.name='Terraform AD Lab' -c user.email=lab@localhost commit -m 'Initialize isolated Terraform lab'
auth=$(printf 'oauth2:%s' "$token" | base64 -w0)
git -C "$lab_repo" -c http.sslCAInfo="$tls/gitlab-ca.pem" -c http.extraHeader="Authorization: Basic $auth" \
  push -o ci.skip "$host_url/root/terraform-ad-lab.git" main
for attempt in $(seq 1 15); do
  if api GET "projects/$project_id/repository/branches/main" | jq -e '.protected' >/dev/null; then
    break
  fi
  if [[ $attempt -eq 15 ]]; then
    api POST "projects/$project_id/protected_branches" --data '{"name":"main","push_access_level":40,"merge_access_level":40}' >/dev/null
    api GET "projects/$project_id/repository/branches/main" | jq -e '.protected' >/dev/null
  else
    sleep 2
  fi
done
pipeline_id=$(api POST "projects/$project_id/pipeline" --data '{"ref":"main"}' | jq -er '.id')
printf '%s\n' "$pipeline_id" > "$LAB_RUNTIME/pipeline-id"
printf 'Pipeline: %s/root/terraform-ad-lab/-/pipelines/%s\n' "$host_url" "$pipeline_id"
if [[ $apply == --apply ]]; then
  bash "$directory/apply-lab.sh" "$LAB_RUNTIME"
fi
