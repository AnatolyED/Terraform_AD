#!/usr/bin/env bash
set -euo pipefail

directory=$(cd -- "$(dirname -- "$0")" && pwd)
root=$(cd -- "$directory/../.." && pwd)
repo=$1
domain=$2
identity_ou=$3
vault_url=$4
prefix=$5
[[ $domain =~ ^[a-zA-Z0-9-]+\.(example|test)$ && $identity_ou =~ ^[a-zA-Z0-9-]+$ ]]
[[ $vault_url =~ ^https://[A-Za-z0-9.-]+:[0-9]+$ && $prefix =~ ^[a-z][a-z0-9]{0,9}$ ]]
adm_inventory="$repo/data/active-directory/adm"
mkdir -p "$adm_inventory" "$repo/data/vault"
cp "$root/data/active-directory/adm/"*.yaml "$adm_inventory/"
cp "$root/data/vault/clusters.yaml" "$repo/data/vault/clusters.yaml"
sed -i "s/^  name: Identity$/  name: $identity_ou/" "$adm_inventory/ou.yaml"
sed -i -e "s/@adm\.example/@$domain/g" \
  -e "s/^  \(sam_account_name\|principal_name\): adm-/  \1: $prefix-/" "$adm_inventory/users.yaml"
sed -i "s/^  sam_account_name: vault-readers$/  sam_account_name: $prefix-readers/" "$adm_inventory/groups.yaml"
sed -i "s|^  address: .*|  address: $vault_url|" "$repo/data/vault/clusters.yaml"
