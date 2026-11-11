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
: "${OFFLINE_BUNDLE:?}" "${LAB_AD_HOST:?}" "${LAB_AD_IP:?}" "${LAB_GITLAB_HOST:?}" "${LAB_VAULT_HOST:?}"
LAB_RUNTIME=$(realpath -m -- "${LAB_RUNTIME:-$directory/.lab}")
LAB_GITLAB_PORT=${LAB_GITLAB_PORT:-8929}
LAB_VAULT_PORT=${LAB_VAULT_PORT:-8200}
[[ $LAB_GITLAB_HOST =~ ^[A-Za-z0-9.-]+$ && $LAB_VAULT_HOST =~ ^[A-Za-z0-9.-]+$ ]]
[[ $LAB_GITLAB_PORT =~ ^[0-9]+$ && $LAB_VAULT_PORT == 8200 ]]
export LAB_RUNTIME LAB_AD_HOST LAB_AD_IP LAB_GITLAB_HOST LAB_GITLAB_PORT LAB_VAULT_HOST LAB_VAULT_PORT
export LAB_GITLAB_BIND_IP LAB_VAULT_BIND_IP
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

tls="$LAB_RUNTIME/tls"
mkdir -p -- "$tls"
chmod 0755 "$tls"
gitlab_url="https://$LAB_GITLAB_HOST:$LAB_GITLAB_PORT"
vault_url="https://$LAB_VAULT_HOST:$LAB_VAULT_PORT"
if [[ $mode == --tls ]]; then
  [[ $role == terraform ]]
  if [[ ! -e $tls/lab-ca.pem ]]; then
    openssl req -x509 -newkey rsa:3072 -nodes -days 30 -subj '/CN=Terraform AD Test CA' \
      -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
      -keyout "$LAB_RUNTIME/lab-ca.key" -out "$tls/lab-ca.pem" 2>"$LAB_RUNTIME/tls.log"
    for service in gitlab vault; do
      host=$LAB_GITLAB_HOST
      [[ $service != vault ]] || host=$LAB_VAULT_HOST
      openssl req -new -newkey rsa:3072 -nodes -subj "/CN=$host" \
        -keyout "$tls/$service.key" -out "$LAB_RUNTIME/$service.csr" 2>>"$LAB_RUNTIME/tls.log"
      printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$host" > "$LAB_RUNTIME/$service.ext"
      openssl x509 -req -in "$LAB_RUNTIME/$service.csr" -CA "$tls/lab-ca.pem" -CAkey "$LAB_RUNTIME/lab-ca.key" \
        -CAcreateserial -days 30 -sha256 -extfile "$LAB_RUNTIME/$service.ext" -out "$tls/$service.pem" 2>>"$LAB_RUNTIME/tls.log"
    done
    chmod 0644 "$tls"/*.pem
  fi
  for service in gitlab vault; do
    host=$LAB_GITLAB_HOST
    [[ $service != vault ]] || host=$LAB_VAULT_HOST
    [[ -s $tls/$service.key ]]
    openssl verify -CAfile "$tls/lab-ca.pem" -verify_hostname "$host" "$tls/$service.pem"
  done
  exit 0
fi

service=gitlab
host=$LAB_GITLAB_HOST
[[ $role != vault ]] || { service=vault; host=$LAB_VAULT_HOST; }
[[ -s $tls/$service.key ]]
openssl verify -CAfile "$tls/lab-ca.pem" -verify_hostname "$host" "$tls/$service.pem"
fingerprint=$(printf '%s\0' "$service" "$gitlab_url" "$vault_url" "$LAB_AD_HOST" "$LAB_AD_IP" "${LAB_GITLAB_BIND_IP:-}" "${LAB_VAULT_BIND_IP:-}" | sha256sum | cut -d ' ' -f1)
marker="$LAB_RUNTIME/$service.deployment"
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
cluster_addr = "https://$LAB_VAULT_HOST:8201"
storage "raft" {
  path = "/vault/file"
  node_id = "terraform-ad-test"
}
listener "tcp" {
  address = "0.0.0.0:8200"
  tls_cert_file = "/lab-tls/vault.pem"
  tls_key_file = "/lab-tls/vault.key"
}
EOF
  chmod 0644 "$tls/vault.hcl"
  if [[ $(stat -c '%a' "$tls/vault.key") == 600 ]]; then
    docker run --rm --user 0 --network none --entrypoint /bin/sh \
      --mount "type=bind,source=$tls,target=/lab-tls" terraform-ad-lab/vault:2.2.1 \
      -ec 'chown vault:vault /lab-tls/vault.key; chmod 0600 /lab-tls/vault.key'
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
  curl -fsS --max-time 8 --cacert "$tls/lab-ca.pem" "$vault_url/v1/sys/$path" "$@"
}
for attempt in $(seq 1 45); do
  if status=$(vault_api seal-status 2>/dev/null); then break; fi
  [[ $attempt -lt 45 ]] || { compose ps; exit 1; }
  sleep 2
done
if [[ $(jq -r '.initialized' <<< "$status") == false ]]; then
  [[ ! -e $LAB_RUNTIME/vault-init.json ]] || { printf 'Existing Vault keys do not match this storage\n' >&2; exit 1; }
  vault_api init -X PUT --data '{"secret_shares":1,"secret_threshold":1}' > "$LAB_RUNTIME/vault-init.json"
fi
if [[ $(jq -r '.sealed' <<< "$status") == true ]]; then
  jq -ce '{key: .keys_base64[0]}' "$LAB_RUNTIME/vault-init.json" |
    vault_api unseal -X PUT --data-binary @- | jq -e '.sealed == false' >/dev/null
fi
printf 'Vault ready: %s\n' "$vault_url"
