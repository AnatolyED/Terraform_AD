#!/usr/bin/env bash
set -euo pipefail
umask 077

[[ $# -eq 2 && ( $1 == --check || $1 == --install ) ]] || {
  printf 'Usage: %s --check|--install CONFIG\n' "$0" >&2
  exit 2
}
mode=$1
source "$(realpath -- "$2")"
: "${GITLAB_URL:?}" "${GITLAB_CA_FILE:?}" "${GITLAB_PROJECT_ID:?}" "${OFFLINE_BUNDLE:?}"
: "${AD_HOST:?}" "${AD_CA_FILE:?}" "${AD_MANAGED_BASE_DN:?}" "${RUNNER_KIND:?}"
[[ $GITLAB_URL =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ && $GITLAB_PROJECT_ID =~ ^[0-9]+$ ]]
[[ $AD_HOST =~ ^[A-Za-z0-9.-]+$ && ${AD_MANAGED_BASE_DN,,} == ou=*,dc=* ]]
[[ $RUNNER_KIND == validate || $RUNNER_KIND == deploy ]]
for tool in docker curl openssl sha256sum; do command -v "$tool" >/dev/null; done
[[ $(docker info --format '{{.OSType}}/{{.Architecture}}') == linux/x86_64 ]]
docker compose version >/dev/null

bundle=$(realpath -- "$OFFLINE_BUNDLE")
gitlab_ca=$(realpath -- "$GITLAB_CA_FILE")
ad_ca=$(realpath -- "$AD_CA_FILE")
(cd "$bundle" && sha256sum -c SHA256SUMS)
curl -fsS --max-time 10 --cacert "$gitlab_ca" "$GITLAB_URL/.well-known/openid-configuration" >/dev/null
timeout 10 openssl s_client -brief -connect "${AD_CONNECT_IP:-$AD_HOST}:${AD_PORT:-636}" -servername "$AD_HOST" \
  -verify_hostname "$AD_HOST" -verify_return_error -CAfile "$ad_ca" </dev/null
for endpoint in "${VAULT_ENDPOINTS[@]:-}"; do
  [[ -n $endpoint ]] || continue
  vault_url=${endpoint%%|*}
  vault_ca=${endpoint#*|}
  [[ $vault_url =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ && -s $vault_ca ]]
  curl -fsS --max-time 10 --cacert "$vault_ca" "$vault_url/v1/sys/health?standbyok=true&perfstandbyok=true" >/dev/null
done
[[ $mode == --install ]] || exit 0

runner_image=terraform-ad/runner:19.5.1
helper_image=terraform-ad/runner-helper:19.5.1
terraform_image=terraform-ad/terraform:1.17.1
runner_name="terraform-ad-$GITLAB_PROJECT_ID-$RUNNER_KIND"
runner_home="${RUNNER_STATE_ROOT:-$PWD/.runner}/$runner_name"
mkdir -p -- "$runner_home"
runner_home=$(realpath -- "$runner_home")
docker image load -i "$bundle/runner-images.tar"
network=${RUNNER_JOB_NETWORK:-bridge}
mounts=(--network "$network" --mount "type=bind,source=$runner_home,target=/etc/gitlab-runner" --mount "type=bind,source=$gitlab_ca,target=/gitlab-ca.pem,readonly" --mount 'type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock')
registration=(--non-interactive --url "$GITLAB_URL" --name "$runner_name" --executor docker --tls-ca-file /gitlab-ca.pem --docker-image "$terraform_image" --docker-helper-image "$helper_image" --docker-pull-policy never --docker-network-mode "$network" --docker-volumes "$bundle/provider-mirror:/providers:ro")
for host in "${RUNNER_EXTRA_HOSTS[@]:-}"; do
  [[ -n $host ]] || continue
  mounts+=(--add-host "$host")
  registration+=(--docker-extra-hosts "$host")
done
fingerprint=$(printf '%s\0' "$GITLAB_PROJECT_ID" "$runner_image" "${registration[@]}" | sha256sum | cut -d ' ' -f1)
if [[ -e $runner_home/config.toml ]]; then
  [[ -s $runner_home/.deployment && $(cat "$runner_home/.deployment") == "$fingerprint" ]] || {
    printf 'Runner configuration differs for %s\n' "$runner_name" >&2
    exit 1
  }
else
  if [[ -z ${RUNNER_TOKEN:-} ]]; then
    read -rsp 'GitLab Runner authentication token: ' RUNNER_TOKEN
    printf '\n'
  fi
  [[ $RUNNER_TOKEN == glrt-* ]]
  export CI_SERVER_TOKEN="$RUNNER_TOKEN"
  docker run --rm "${mounts[@]}" -e CI_SERVER_TOKEN "$runner_image" register "${registration[@]}" >/dev/null
  unset RUNNER_TOKEN CI_SERVER_TOKEN
  printf '%s\n' "$fingerprint" > "$runner_home/.deployment"
fi
if docker container inspect "$runner_name" >/dev/null 2>&1; then
  [[ $(docker inspect --format '{{index .Config.Labels "terraform-ad.deployment"}}' "$runner_name") == "$fingerprint" ]]
  docker start "$runner_name" >/dev/null
else
  docker run -d --name "$runner_name" --restart unless-stopped \
    --label "terraform-ad.deployment=$fingerprint" "${mounts[@]}" "$runner_image" >/dev/null
fi
docker exec "$runner_name" gitlab-runner verify
