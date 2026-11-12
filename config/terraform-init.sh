#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
terraform_root=$1
shift

case "${TERRAFORM_SOURCE:-upstream}" in
  upstream) export TF_CLI_CONFIG_FILE="$project_dir/config/terraform.tfrc" ;;
  yandex) export TF_CLI_CONFIG_FILE="$project_dir/config/terraform.yandex.tfrc" ;;
  *) printf '%s\n' 'TERRAFORM_SOURCE must be upstream or yandex' >&2; exit 1 ;;
esac

case "$terraform_root" in
  infra/active-directory|infra/vault) cd "$project_dir/$terraform_root" ;;
  *) printf '%s\n' 'Unknown Terraform root' >&2; exit 1 ;;
esac

if [ "$terraform_root" = infra/active-directory ]; then
  archive=terraform-provider-ad_0.6.0-ou-dacl.1_linux_amd64.zip
  expected_sha=a4cfc6b83cb6ac779ae536e4078128875d3dc38d2c413791903155357a8ca515
  package_dir=.providers/registry.terraform.io/isometry/ad
  archive_path="$package_dir/$archive"
  release_url="https://github.com/AnatolyED/terraform-provider-ad-ou-dacl/releases/download/v0.6.0-ou-dacl.1/$archive"
  download_url=${AD_PROVIDER_RELEASE_URL:-$release_url}

  case "$download_url" in
    https://*) ;;
    *) printf '%s\n' 'AD_PROVIDER_RELEASE_URL must use HTTPS' >&2; exit 1 ;;
  esac

  if ! printf '%s  %s\n' "$expected_sha" "$archive_path" | sha256sum -c - >/dev/null 2>&1; then
    mkdir -p "$package_dir"
    download=$(mktemp "$package_dir/download.XXXXXXXX")
    trap 'rm -f -- "$download"' EXIT
    if ! wget -q -O "$download" "$download_url"; then
      printf '%s\n' 'Cannot download the pinned AD provider. Check GitHub or AD_PROVIDER_RELEASE_URL.' >&2
      exit 1
    fi
    printf '%s  %s\n' "$expected_sha" "$download" | sha256sum -c -
    mv -f -- "$download" "$archive_path"
    trap - EXIT
  fi
fi

exec terraform init -lockfile=readonly -no-color "$@"
