#!/usr/bin/env bash
# Creates the vault password file and an encrypted vault with random secrets
# for one environment. Safe to re-run: existing files are never overwritten.
#
#   scripts/generate-vault.sh production|staging
set -euo pipefail

ENV_NAME="${1:?usage: $0 production|staging}"
cd "$(dirname "$0")/.."

PASS_FILE=".vault_pass_${ENV_NAME}"
VAULT_FILE="inventory/${ENV_NAME}/group_vars/all/vault.yml"

# A committed vault without its password file (e.g. a fresh clone): a new
# password could never decrypt it, so stop instead of creating one.
if [[ ! -f "$PASS_FILE" && -f "$VAULT_FILE" ]]; then
  echo "ERROR: $VAULT_FILE exists but $PASS_FILE is missing." >&2
  echo "Copy $PASS_FILE from the machine that created the vault, or delete the vault to start fresh." >&2
  exit 1
fi

if [[ ! -f "$PASS_FILE" ]]; then
  python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
  echo "Created $PASS_FILE (keep it safe, it is gitignored)"
fi

if [[ -f "$VAULT_FILE" ]]; then
  echo "$VAULT_FILE already exists, leaving it unchanged"
  exit 0
fi

python3 - "$VAULT_FILE" <<'EOF'
import secrets, string, sys

def pw(n=24):
    return secrets.token_urlsafe(n)[:n]

def salt():
    # WordPress salts: 64 printable chars; avoid quotes/backslashes for PHP/YAML safety.
    alphabet = string.ascii_letters + string.digits + "!#$%&()*+,-./:;<=>?@[]^_{|}~"
    return "".join(secrets.choice(alphabet) for _ in range(64))

keys = ["AUTH_KEY", "SECURE_AUTH_KEY", "LOGGED_IN_KEY", "NONCE_KEY",
        "AUTH_SALT", "SECURE_AUTH_SALT", "LOGGED_IN_SALT", "NONCE_SALT"]

with open(sys.argv[1], "w") as f:
    f.write("---\n")
    for name in ["mysql_root_password", "wp_db_password", "galera_sst_password",
                 "redis_password", "wp_admin_password", "haproxy_stats_password"]:
        f.write(f'vault_{name}: "{pw()}"\n')
    # keepalived VRRP auth uses only the first 8 characters.
    f.write(f'vault_keepalived_auth_password: "{pw(8)}"\n')
    f.write("vault_wp_salts:\n")
    for k in keys:
        f.write(f"  {k}: '{salt()}'\n")
EOF

ansible-vault encrypt "$VAULT_FILE" --vault-id "${ENV_NAME}@${PASS_FILE}" --encrypt-vault-id "$ENV_NAME"
echo "Created encrypted $VAULT_FILE"
