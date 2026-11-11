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
lab_inventory="$repo/inventory/active-directory/lab"
mkdir -p "$lab_inventory" "$repo/inventory/vault"
cp "$root/inventory/active-directory/lab/"*.yaml "$lab_inventory/"
cp "$root/inventory/vault/clusters.yaml" "$repo/inventory/vault/clusters.yaml"
sed -i "s/^  name: Identity$/  name: $identity_ou/" "$lab_inventory/ou.yaml"
sed -i -e "s/@lab\.example/@$domain/g" \
  -e "s/^  \(sam_account_name\|principal_name\): lab-/  \1: $prefix-/" "$lab_inventory/users.yaml"
sed -i "s/^  sam_account_name: vault-readers$/  sam_account_name: $prefix-readers/" "$lab_inventory/groups.yaml"
sed -i "s|^  address: .*|  address: $vault_url|" "$repo/inventory/vault/clusters.yaml"
