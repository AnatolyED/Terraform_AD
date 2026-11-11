#!/usr/bin/env bash
set -euo pipefail
umask 077

[[ $# -eq 3 && ( $1 == --check || $1 == --tls || $1 == --start ) && ( $2 == terraform || $2 == vault ) ]] || {
  printf 'Usage: %s --check|--tls|--start terraform|vault CONFIG\n' "$0" >&2
  exit 2
}
mode=$1
role=$2
config=$(realpath -- "$3")
directory=$(cd -- "$(dirname -- "$0")" && pwd)
source "$config"
: "${OFFLINE_BUNDLE:?}" "${ADM_AD_HOST:?}" "${ADM_AD_IP:?}" "${ADM_GITLAB_HOST:?}" "${ADM_VAULT_HOST:?}"
ADM_RUNTIME=$(realpath -m -- "${ADM_RUNTIME:-$directory/.adm}")
ADM_GITLAB_PORT=${ADM_GITLAB_PORT:-8929}
ADM_VAULT_PORT=${ADM_VAULT_PORT:-8200}
[[ $ADM_GITLAB_HOST =~ ^[A-Za-z0-9.-]+$ && $ADM_VAULT_HOST =~ ^[A-Za-z0-9.-]+$ ]]
[[ $ADM_GITLAB_PORT =~ ^[0-9]+$ && $ADM_VAULT_PORT == 8200 ]]
export ADM_RUNTIME ADM_AD_HOST ADM_AD_IP ADM_GITLAB_HOST ADM_GITLAB_PORT ADM_VAULT_HOST ADM_VAULT_PORT
export ADM_GITLAB_BIND_IP ADM_VAULT_BIND_IP
for tool in docker curl openssl sha256sum jq; do command -v "$tool" >/dev/null; done
[[ $(docker info --format '{{.OSType}}/{{.Architecture}}') == linux/x86_64 ]]
docker compose version >/dev/null
if [[ $role == terraform ]]; then
  (cd -- "$OFFLINE_BUNDLE" && sha256sum -c SHA256SUMS && sha256sum -c GITLAB-SHA256SUMS)
  image_archive=gitlab-image.tar
else
  (cd -- "$OFFLINE_BUNDLE" && sha256sum -c VAULT-SHA256SUMS)
  image_archive=vault-image.tar
fi
compose() {
  docker compose --file "$directory/compose.yaml" --profile "$role" "$@"
}
compose config --quiet
[[ $mode != --check ]] || exit 0

tls="$ADM_RUNTIME/tls"
mkdir -p -- "$tls"
chmod 0755 "$tls"
gitlab_url="https://$ADM_GITLAB_HOST:$ADM_GITLAB_PORT"
vault_url="https://$ADM_VAULT_HOST:$ADM_VAULT_PORT"
if [[ $mode == --tls ]]; then
  [[ $role == terraform ]]
  if [[ ! -e $tls/adm-ca.pem ]]; then
    openssl req -x509 -newkey rsa:3072 -nodes -days 30 -subj '/CN=Terraform AD Test CA' \
      -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
      -keyout "$ADM_RUNTIME/adm-ca.key" -out "$tls/adm-ca.pem" 2>"$ADM_RUNTIME/tls.log"
    for service in gitlab vault; do
      host=$ADM_GITLAB_HOST
      [[ $service != vault ]] || host=$ADM_VAULT_HOST
      openssl req -new -newkey rsa:3072 -nodes -subj "/CN=$host" \
        -keyout "$tls/$service.key" -out "$ADM_RUNTIME/$service.csr" 2>>"$ADM_RUNTIME/tls.log"
      printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$host" > "$ADM_RUNTIME/$service.ext"
      openssl x509 -req -in "$ADM_RUNTIME/$service.csr" -CA "$tls/adm-ca.pem" -CAkey "$ADM_RUNTIME/adm-ca.key" \
        -CAcreateserial -days 30 -sha256 -extfile "$ADM_RUNTIME/$service.ext" -out "$tls/$service.pem" 2>>"$ADM_RUNTIME/tls.log"
    done
    chmod 0644 "$tls"/*.pem
  fi
  for service in gitlab vault; do
    host=$ADM_GITLAB_HOST
    [[ $service != vault ]] || host=$ADM_VAULT_HOST
    [[ -s $tls/$service.key ]]
    openssl verify -CAfile "$tls/adm-ca.pem" -verify_hostname "$host" "$tls/$service.pem"
  done
  exit 0
fi

service=gitlab
host=$ADM_GITLAB_HOST
[[ $role != vault ]] || { service=vault; host=$ADM_VAULT_HOST; }
[[ -s $tls/$service.key ]]
openssl verify -CAfile "$tls/adm-ca.pem" -verify_hostname "$host" "$tls/$service.pem"
fingerprint=$(printf '%s\0' "$service" "$gitlab_url" "$vault_url" "$ADM_AD_HOST" "$ADM_AD_IP" "${ADM_GITLAB_BIND_IP:-}" "${ADM_VAULT_BIND_IP:-}" | sha256sum | cut -d ' ' -f1)
marker="$ADM_RUNTIME/$service.deployment"
if [[ -e $marker ]]; then
  [[ $(cat "$marker") == "$fingerprint" ]] || { printf 'Lab settings differ for %s\n' "$service" >&2; exit 1; }
else
  printf '%s\n' "$fingerprint" > "$marker"
fi
docker image load -i "$OFFLINE_BUNDLE/$image_archive"
if [[ $role == vault ]]; then
  cat > "$tls/vault.hcl" <<EOF
ui = true
disable_mlock = true
api_addr = "$vault_url"
cluster_addr = "https://$ADM_VAULT_HOST:8201"
storage "raft" {
  path = "/vault/file"
  node_id = "terraform-ad-adm"
}
listener "tcp" {
  address = "0.0.0.0:8200"
  tls_cert_file = "/test-tls/vault.pem"
  tls_key_file = "/test-tls/vault.key"
}
EOF
  chmod 0644 "$tls/vault.hcl"
  if [[ $(stat -c '%a' "$tls/vault.key") == 600 ]]; then
    docker run --rm --user 0 --network none --entrypoint /bin/sh \
      --mount "type=bind,source=$tls,target=/test-tls" terraform-ad-lab/vault:2.2.1 \
      -ec 'chown vault:vault /test-tls/vault.key; chmod 0600 /test-tls/vault.key'
  fi
fi
compose up -d --pull never "$service"

if [[ $role == terraform ]]; then
  bash "$directory/bootstrap-gitlab.sh" "$config"
  exit 0
fi

vault_api() {
  local path=$1
  shift
  curl -fsS --max-time 8 --cacert "$tls/adm-ca.pem" "$vault_url/v1/sys/$path" "$@"
}
for attempt in $(seq 1 45); do
  if status=$(vault_api seal-status 2>/dev/null); then break; fi
  [[ $attempt -lt 45 ]] || { compose ps; exit 1; }
  sleep 2
done
if [[ $(jq -r '.initialized' <<< "$status") == false ]]; then
  [[ ! -e $ADM_RUNTIME/vault-init.json ]] || { printf 'Existing Vault keys do not match this storage\n' >&2; exit 1; }
  vault_api init -X PUT --data '{"secret_shares":1,"secret_threshold":1}' > "$ADM_RUNTIME/vault-init.json"
fi
if [[ $(jq -r '.sealed' <<< "$status") == true ]]; then
  jq -ce '{key: .keys_base64[0]}' "$ADM_RUNTIME/vault-init.json" |
    vault_api unseal -X PUT --data-binary @- | jq -e '.sealed == false' >/dev/null
fi
printf 'Vault ready: %s\n' "$vault_url"
