# security-hardening

Baseline hardening for every host. All parts can be toggled and tuned.

## What it does

- **UFW**: default deny incoming. SSH is allowed *before* the firewall is
  enabled. Per-tier rules come from `firewall_rules` in group_vars:

  ```yaml
  firewall_rules:
    - { port: 3306, from_hosts: "{{ groups['loadbalancers'] }}", comment: MariaDB }
    - { port: 443, comment: HTTPS }              # from anywhere
    - { from_hosts: [haproxy2], comment: VRRP }  # all protocols from a peer
  ```

  `from_hosts` takes inventory hostnames and resolves them to their IPs.
- **SSH**: `sshd_config.d/10-hardening.conf` (no root, no passwords,
  `AllowUsers`, modern algorithms), validated with `sshd -t` before install.
- **fail2ban**: `sshd` jail (journal backend), plus extra jails from
  `fail2ban_jails`, each with its own filter regex. Bans are port-scoped
  (`nftables-multiport`).
- **sysctl**: `/etc/sysctl.d/90-hardening.conf` from a dict.
- **Updates**: unattended security upgrades.

## Handlers

`Restart ssh`, `Restart fail2ban`, `Apply sysctl`.

## Key variables

See `defaults/main.yml` and `meta/argument_specs.yml`.
