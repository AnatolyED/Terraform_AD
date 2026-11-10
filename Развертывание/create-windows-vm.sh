#!/usr/bin/env bash
set -euo pipefail

iso=$(realpath -- "${1:?Pass the Windows Server ISO}")
name=${2:-terraform-ad-dc}
[[ -f $iso && -e /dev/kvm ]]
uri=qemu:///system
if virsh -c "$uri" dominfo "$name" >/dev/null 2>&1; then
  virsh -c "$uri" dominfo "$name"
  exit 0
fi
if ! virsh -c "$uri" net-list --name | grep -Fxq default; then
  virsh -c "$uri" net-start default
fi
virt-install --connect "$uri" --name "$name" --virt-type kvm \
  --memory 4096 --vcpus 2 --disk size=64,bus=sata \
  --cdrom "$iso" --osinfo detect=on,require=off --boot uefi \
  --network network=default,model=e1000e \
  --graphics vnc,listen=127.0.0.1 --noautoconsole --wait 0
printf 'Open %s in virt-manager and complete Windows Setup.\n' "$name"
