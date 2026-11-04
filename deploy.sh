#!/usr/bin/env bash
# Single entry point on the control node (WSL / Linux):
#
#   ./deploy.sh production|staging [extra ansible-playbook args]
#
# Installs Galaxy dependencies, makes sure the vault exists, and runs site.yml
# against the chosen environment. VMs must already be up (`vagrant up`), or use
# deploy.ps1 on Windows, which does both.
set -euo pipefail

ENV_NAME="${1:-production}"
shift || true
cd "$(dirname "$0")"

if [[ ! -d "inventory/${ENV_NAME}" ]]; then
  echo "Unknown environment '${ENV_NAME}' (expected production or staging)" >&2
  exit 1
fi

# Ansible refuses to read ansible.cfg from a world-writable dir; be explicit.
export ANSIBLE_CONFIG="$PWD/ansible.cfg"

chmod 600 files/deploy_key
bash scripts/generate-vault.sh "$ENV_NAME"

ansible-galaxy role install -r requirements.yml -p roles/galaxy
ansible-galaxy collection install -r requirements.yml -p collections

exec ansible-playbook site.yml \
  -i "inventory/${ENV_NAME}/hosts.yml" \
  "$@"
