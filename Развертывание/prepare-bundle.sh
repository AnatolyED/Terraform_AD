#!/usr/bin/env bash
set -euo pipefail
umask 077

directory=$(cd -- "$(dirname -- "$0")" && pwd)
ad_archive=${1:?Pass the verified AD provider ZIP}
output=${2:-"$directory/.bundle"}
mkdir -p "$output"
output=$(cd -- "$output" && pwd)
mirror="$output/provider-mirror/registry.terraform.io"
mkdir -p "$mirror/isometry/ad" "$mirror/hashicorp/vault"

ad_name=terraform-provider-ad_0.6.0-ou-dacl.lab.1_linux_amd64.zip
vault_name=terraform-provider-vault_5.13.0_linux_amd64.zip
ad_sha=2d28f3e9ec4a6a7c65ee42ffd001bf7f2df56e454d38e72590fb9f32b8f67076
vault_sha=1dfb6e74d1c7e22b4b3b477cabb36572b25c3e9746b75007e4e97a2c54ea7b24

printf '%s  %s\n' "$ad_sha" "$ad_archive" | sha256sum -c -
cp -- "$ad_archive" "$mirror/isometry/ad/$ad_name"
if [[ -n ${VAULT_PROVIDER_ZIP:-} ]]; then
  cp -- "$VAULT_PROVIDER_ZIP" "$mirror/hashicorp/vault/$vault_name"
else
  if ! curl -fSsL --connect-timeout 8 --max-time 40 --retry 2 \
    "https://terraform-mirror.yandexcloud.net/registry.terraform.io/hashicorp/vault/$vault_name" \
    -o "$mirror/hashicorp/vault/$vault_name"; then
    [[ ${ALLOW_ORIGIN:-0} == 1 ]] || exit 1
    curl -fSsL --connect-timeout 8 --max-time 40 \
      "https://releases.hashicorp.com/terraform-provider-vault/5.13.0/$vault_name" \
      -o "$mirror/hashicorp/vault/$vault_name"
  fi
fi
printf '%s  %s\n' "$vault_sha" "$mirror/hashicorp/vault/$vault_name" | sha256sum -c -

prepare_image() {
  local source=$1 target=$2
  if ! docker image inspect "$source" >/dev/null 2>&1; then
    docker image pull --platform linux/amd64 "$source"
  fi
  [[ $(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$source") == linux/amd64 ]]
  docker image tag "$source" "$target"
}

prepare_image "${GITLAB_IMAGE:-docker.io/gitlab/gitlab-ce@sha256:bb79dc86267c557fd11e7feb0cd9dd506dd02e991ecdd6cae11ca7d7e5d36fc3}" terraform-ad-lab/gitlab:19.5.1
prepare_image "${RUNNER_IMAGE:-docker.io/gitlab/gitlab-runner@sha256:86a371df46b076bb4c510bca1751d428177d2567bd88e4047613bc7fa92d1a0e}" terraform-ad-lab/runner:19.5.1
prepare_image "${HELPER_IMAGE:-registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper@sha256:ca7cc8f66a6c6931281aa2ae974b62f80111a4f578cabc442b1d39388a0dee91}" terraform-ad-lab/runner-helper:19.5.1
prepare_image "${VAULT_IMAGE:-docker.io/hashicorp/vault@sha256:962a92876e168d68eaaa24b0b8b49bbce1cb63024060a67bba95cd158a366fc2}" terraform-ad-lab/vault:2.2.1
prepare_image "${TERRAFORM_IMAGE:-docker.io/hashicorp/terraform@sha256:a5d5a5a892c98f60fcbfa81eac2a40fc19e7b3fa7719bccae10ff6111d22524a}" terraform-ad-lab/terraform:1.17.1

docker image save -o "$output/images.tar" terraform-ad-lab/gitlab:19.5.1 terraform-ad-lab/runner:19.5.1 \
  terraform-ad-lab/runner-helper:19.5.1 terraform-ad-lab/vault:2.2.1 terraform-ad-lab/terraform:1.17.1
(
  cd -- "$output"
  sha256sum images.tar "provider-mirror/registry.terraform.io/isometry/ad/$ad_name" \
    "provider-mirror/registry.terraform.io/hashicorp/vault/$vault_name" > SHA256SUMS
)
printf 'Bundle prepared: %s\n' "$output"
