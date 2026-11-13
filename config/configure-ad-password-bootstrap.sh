#!/bin/sh
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
  printf 'Usage: %s GITLAB_HTTPS_URL PROJECT_ID [PROTECTED_BRANCH] [AD_ENVIRONMENT]\n' "$0" >&2
  exit 2
fi
gitlab=${1%/}
project=$2
branch=${3:-main}
environment=${4:-production}
: "${VAULT_ADDR:?Set the HTTPS address of the selected Vault}"
case "$VAULT_ADDR" in https://*) ;; *) exit 2 ;; esac
case "$gitlab" in https://?*) ;; *) exit 2 ;; esac
if ! printf '%s\n' "$project" | grep -Eq '^[1-9][0-9]*$' ||
   ! printf '%s\n' "$environment" | grep -Eq '^[a-z][a-z0-9-]*$'; then
  printf '%s\n' 'Invalid GitLab project ID or AD environment.' >&2
  exit 2
fi

vault read auth/gitlab-jwt/config >/dev/null
mounts=$(vault secrets list -format=json)
if printf '%s' "$mounts" | jq -e 'has("ad-bootstrap/")' >/dev/null; then
  printf '%s' "$mounts" | jq -e '."ad-bootstrap/" | .type == "kv" and .options.version == "2"' >/dev/null ||
    { printf '%s\n' 'The ad-bootstrap mount must be KV v2.' >&2; exit 1; }
  vault read -format=json ad-bootstrap/config | jq -e '.data.cas_required == true' >/dev/null ||
    { printf '%s\n' 'Enable cas_required on the dedicated ad-bootstrap mount before continuing.' >&2; exit 1; }
else
  vault secrets enable -path=ad-bootstrap kv-v2
  vault write ad-bootstrap/config cas_required=true
fi

prefix="ad-bootstrap-$project-$environment"
vault write "sys/policies/password/$prefix" policy=- <<'HCL'
length = 32
rule "charset" {
  charset = "abcdefghijklmnopqrstuvwxyz"
  min-chars = 4
}
rule "charset" {
  charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  min-chars = 4
}
rule "charset" {
  charset = "0123456789"
  min-chars = 4
}
rule "charset" {
  charset = "!@#%^*-_+=?"
  min-chars = 4
}
HCL

path="ad-bootstrap/data/projects/$project/$environment/*"
vault policy write "$prefix-plan" - <<HCL
path "$path" {
  capabilities = ["create", "read"]
}
path "sys/policies/password/$prefix/generate" {
  capabilities = ["read"]
}
HCL

vault policy write "$prefix-apply" - <<HCL
path "$path" {
  capabilities = ["read"]
}
HCL

for mode in plan apply; do
  case "$mode" in
    plan) action=verify ;;
    apply) action=start ;;
  esac
  role="$prefix-$mode"
  jq -n --arg project "$project" --arg ref "$branch" \
    --arg environment "ad/$environment" --arg action "$action" \
    --arg aud "$gitlab/terraform/ad/bootstrap/$mode" --arg role "$role" '{
      role_type: "jwt", user_claim: "sub", bound_audiences: [$aud],
      bound_claims: {
        project_id: $project, ref: $ref, ref_type: "branch", ref_protected: "true",
        environment: $environment, environment_action: $action
      },
      token_policies: [$role], token_no_default_policy: true,
      token_type: "batch", token_ttl: 900
    }' | vault write "auth/gitlab-jwt/role/$role" -
done
