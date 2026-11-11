#!/usr/bin/env bash
set -euo pipefail
umask 077

directory=$(cd -- "$(dirname -- "$0")" && pwd)
root=$(cd -- "$directory/../.." && pwd)
source "$(realpath -- "$1")"
: "${LAB_AD_CA_FILE:?}" "${LAB_AD_HOST:?}" "${LAB_AD_IP:?}" "${OFFLINE_BUNDLE:?}"
runtime=$(realpath -m -- "${LAB_RUNTIME:-$directory/.lab}")
LAB_RUNTIME=$runtime
LAB_GITLAB_PORT=${LAB_GITLAB_PORT:-8929}
LAB_VAULT_PORT=${LAB_VAULT_PORT:-8200}
export LAB_RUNTIME LAB_GITLAB_HOST LAB_GITLAB_PORT LAB_VAULT_HOST LAB_VAULT_PORT LAB_AD_HOST LAB_AD_IP
export LAB_GITLAB_BIND_IP LAB_VAULT_BIND_IP
tls="$runtime/tls"
gitlab_url="https://$LAB_GITLAB_HOST:${LAB_GITLAB_PORT:-8929}"
vault_url="https://$LAB_VAULT_HOST:${LAB_VAULT_PORT:-8200}"
project_path=${LAB_PROJECT_PATH:-terraform-ad-test}
branch=${LAB_GIT_BRANCH:-Test}
source_repo=${LAB_SOURCE_REPO:-$root}
source_ref=${LAB_SOURCE_REF:-HEAD}
domain=${LAB_AD_DOMAIN:-lab.example}
base_dn=${LAB_AD_MANAGED_BASE_DN:-OU=TerraformLab,DC=lab,DC=example}
identity_ou=${LAB_IDENTITY_OU:-Identity}
[[ $project_path =~ ^terraform-ad-[a-z0-9-]+$ && $domain =~ ^[a-zA-Z0-9.-]+$ && $identity_ou =~ ^[a-zA-Z0-9-]+$ ]]
git check-ref-format --branch "$branch" >/dev/null

for attempt in $(seq 1 90); do
  if curl -fsS --max-time 8 --cacert "$tls/lab-ca.pem" "$gitlab_url/.well-known/openid-configuration" 2>/dev/null |
    jq -e --arg issuer "$gitlab_url" '.issuer == $issuer' >/dev/null; then break; fi
  [[ $attempt -lt 90 ]] || { printf 'GitLab OIDC unavailable: %s\n' "$gitlab_url" >&2; exit 1; }
  sleep 5
done
curl -fsS --max-time 10 --cacert "$tls/lab-ca.pem" "$vault_url/v1/sys/health" >/dev/null
timeout 10 openssl s_client -brief -connect "$LAB_AD_IP:636" -servername "$LAB_AD_HOST" \
  -verify_hostname "$LAB_AD_HOST" -verify_return_error -CAfile "$LAB_AD_CA_FILE" </dev/null

project_runtime="$runtime/$project_path"
mkdir -p "$project_runtime"
token_file="$project_runtime/gitlab-token"
token_status=401
if [[ -s $token_file ]]; then
  token_status=$(curl -sS --max-time 15 --cacert "$tls/lab-ca.pem" -H "PRIVATE-TOKEN: $(cat "$token_file")" \
    -o /dev/null -w '%{http_code}' "$gitlab_url/api/v4/user")
fi
if [[ $token_status == 401 ]]; then
  token=$(docker compose -f "$directory/compose.yaml" --profile terraform exec -T gitlab gitlab-rails runner - <<'RUBY'
root = User.find_by_username('root')
ApplicationSetting.current.update!(signup_enabled: false)
token = root.personal_access_tokens.create!(name: 'terraform-ad-test-bootstrap', scopes: [:api, :create_runner, :write_repository], expires_at: Date.current + 2)
puts token.token
RUBY
)
  [[ $token == glpat-* ]]
  printf '%s\n' "$token" > "$token_file"
elif [[ $token_status != 200 ]]; then
  printf 'GitLab token verification failed: HTTP %s\n' "$token_status" >&2
  exit 1
fi
token=$(cat "$token_file")
api() {
  local method=$1 path=$2
  shift 2
  curl -fsS --max-time 50 --cacert "$tls/lab-ca.pem" -H "PRIVATE-TOKEN: $token" \
    -H 'Content-Type: application/json' -X "$method" "$gitlab_url/api/v4/$path" "$@"
}
if ! project=$(api GET "projects/root%2F$project_path" 2>/dev/null); then
  project=$(jq -nc --arg path "$project_path" '{name:$path,path:$path,visibility:"private",shared_runners_enabled:false}' |
    api POST projects --data-binary @-)
fi
project_id=$(jq -er '.id' <<< "$project")
printf '%s\n' "$project_id" > "$project_runtime/project-id"
repo="$project_runtime/project"
if [[ ! -s $project_runtime/source-commit ]]; then
  mkdir -p "$repo"
  git -C "$repo" init --initial-branch "$branch"
  git -C "$repo" config core.fileMode false
  git -C "$repo" fetch --no-tags "$source_repo" "$source_ref"
  source_commit=$(git -C "$repo" rev-parse FETCH_HEAD)
  git -C "$repo" checkout -B "$branch" "$source_commit"
  bash "$directory/stage-inventory.sh" "$repo" "$domain" "$identity_ou" "$vault_url" "${LAB_ACCOUNT_PREFIX:-lab}"
  git -C "$repo" add -- inventory
  if ! git -C "$repo" diff --cached --quiet; then
    git -C "$repo" -c user.name='Terraform AD Test' -c user.email=terraform-ad-test@localhost commit -m 'Configure isolated test inventory'
  fi
  auth=$(printf 'oauth2:%s' "$token" | base64 -w0)
  GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=http.sslCAInfo GIT_CONFIG_VALUE_0="$tls/lab-ca.pem" \
    GIT_CONFIG_KEY_1=http.extraHeader GIT_CONFIG_VALUE_1="Authorization: Basic $auth" \
    git -C "$repo" push -o ci.skip "$gitlab_url/root/$project_path.git" "$branch"
  printf '%s\n' "$source_commit" > "$project_runtime/source-commit"
else
  git -C "$repo" fetch --no-tags "$source_repo" "$source_ref"
  [[ $(git -C "$repo" rev-parse FETCH_HEAD) == "$(cat "$project_runtime/source-commit")" ]] || {
    printf 'Source ref differs from the original test project\n' >&2
    exit 1
  }
fi
actual_commit=$(git -C "$repo" rev-parse HEAD)
api GET "projects/$project_id/repository/branches/$branch" |
  jq -e --arg commit "$actual_commit" '.commit.id == $commit and .default' >/dev/null
for attempt in $(seq 1 15); do
  if api GET "projects/$project_id/repository/branches/$branch" | jq -e '.protected' >/dev/null; then break; fi
  if [[ $attempt -eq 1 ]]; then
    jq -nc --arg branch "$branch" '{name:$branch,push_access_level:40,merge_access_level:40}' |
      api POST "projects/$project_id/protected_branches" --data-binary @- >/dev/null 2>"$project_runtime/protect-branch.log" || true
  fi
  [[ $attempt -lt 15 ]] || { printf 'Default test branch is not protected\n' >&2; exit 1; }
  sleep 2
done

for kind in validate deploy; do
  tag=terraform-docker
  access=not_protected
  if [[ $kind == deploy ]]; then tag=terraform-deploy; access=ref_protected; fi
  runner_config="$project_runtime/runner-$kind.local.env"
  {
    printf 'GITLAB_URL=%q\nGITLAB_CA_FILE=%q\nGITLAB_PROJECT_ID=%q\nOFFLINE_BUNDLE=%q\n' "$gitlab_url" "$tls/lab-ca.pem" "$project_id" "$OFFLINE_BUNDLE"
    printf 'AD_HOST=%q\nAD_CA_FILE=%q\nAD_MANAGED_BASE_DN=%q\nRUNNER_KIND=%q\n' "$LAB_AD_HOST" "$LAB_AD_CA_FILE" "$base_dn" "$kind"
    printf 'AD_CONNECT_IP=%q\n' "$LAB_AD_IP"
    printf 'RUNNER_STATE_ROOT=%q\nRUNNER_JOB_NETWORK=%q\n' "$runtime/runners" terraform-ad-debian12-test
    printf 'RUNNER_EXTRA_HOSTS=(%q)\nVAULT_ENDPOINTS=(%q)\n' "$LAB_AD_HOST:$LAB_AD_IP" "$vault_url|$tls/lab-ca.pem"
  } > "$runner_config"
  runner_token_file="$project_runtime/runner-$kind.token"
  if [[ ! -s $runtime/runners/terraform-ad-$project_id-$kind/config.toml ]]; then
    if [[ ! -s $runner_token_file ]]; then
      jq -nc --argjson id "$project_id" --arg tag "$tag" --arg access "$access" \
        '{runner_type:"project_type",project_id:$id,tag_list:[$tag],run_untagged:false,locked:true,access_level:$access}' |
        api POST user/runners --data-binary @- | jq -er '.token' > "$runner_token_file"
    fi
    export RUNNER_TOKEN=$(cat "$runner_token_file")
  fi
  bash "$root/deploy/install-runner.sh" --install "$runner_config"
  unset RUNNER_TOKEN
  rm -f "$runner_token_file"
done

if [[ ! -s $project_runtime/pipeline-id ]]; then
  bash "$directory/configure-project.sh" "$1" "$project_runtime"
  jq -nc --arg branch "$branch" '{ref:$branch}' | api POST "projects/$project_id/pipeline" --data-binary @- |
    jq -er '.id' > "$project_runtime/pipeline-id"
fi
printf 'Source commit: %s\nPipeline: %s/root/%s/-/pipelines/%s\n' \
  "$(cat "$project_runtime/source-commit")" "$gitlab_url" "$project_path" "$(cat "$project_runtime/pipeline-id")"
