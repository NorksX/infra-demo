# Implementation Plan — WordPress + WooCommerce Hosting Platform (Ansible)

## ▶ CURRENT STATUS (keep this section up to date — read first when resuming)

**Last updated:** 2026-11-04 ~04:30

All tiers are implemented and committed. Tested on staging, and now on **production** (12 VMs).

**Done (committed):** skeleton/inventories/vault · common + security-hardening · database
(geerlingguy.mysql + galera-cluster) · NFS + Redis · haproxy-config (+keepalived) · web tier
(geerlingguy.php/nginx + wordpress-setup) · orchestration (serial, rolling_update.yml, verify.yml) ·
docs (README in Macedonian, docs/architecture.md, role READMEs) · VM_MEMORY_SCALE ·
production deploy (after a power cut + 4 bug fixes) → `site.yml` re-run `changed=0` on 12 hosts ·
production failover tests (results below).

**Production failover results (traffic through the VIP):** web node power-off 16/16 OK (sticky
client moved) · DB writer stopped 34/34 OK · Redis primary stopped 13/13 OK (runs uncached) ·
VIP failover (HAProxy stopped on the VIP holder) 1 failed of 55, ~1 s gap · NFS wp1→wp3 OK.

Production upgrade 7.0.8/11.1.2 → 7.1.4/11.2.1 done with `rolling_update.yml` (257/257 OK) and
committed; final production `site.yml` run `changed=0` on all 12 hosts; results are in README.md.
Production VMs destroyed afterwards (by agreement) to free RAM.

Fresh `.\deploy.ps1 -Environment staging` from zero (empty download cache): passed first try in
29 min (8 VMs + 19 min Ansible); second run `changed=0` on all 8 hosts. Results in README.md.

**Remaining:** nothing required. Staging VMs are left running for the user to look at.
Optional ideas: Storefront theme, Redis Sentinel for automatic replica promotion.
For the presentation laptop (24 GB): copy `.vault_pass_*`, `$env:VM_MEMORY_SCALE = "1.5"`.

**How to run things (control node = WSL):** `wsl -e bash -c "cd /mnt/c/Users/Boro/Desktop/infra && ./deploy.sh staging"`.
Use script files for anything with quotes (PowerShell mangles them). Only one environment fits in RAM.
SSH to a VM: `ssh -i files/deploy_key deploy@<ip>`. Vault passwords: `.vault_pass_<env>` (gitignored).

**Gotchas already solved (don't re-investigate):** world-writable /mnt/c → wsl.conf metadata ·
Vagrant net-ssh needs ecdh-sha2-nistp256 KEX · rsyslog AppArmor blocks HAProxy chroot socket → UDP 127.0.0.1:514 ·
fail2ban log file must be owned by syslog · Jinja `'\t'` isn't a tab · ansible-core 2.19+ needs boolean
conditionals · community.mysql → ansible.mysql · MK addresses need `state` in WooCommerce ·
haproxy module `wait` doesn't wait for health checks → explicit poll · deploy.ps1 must not use
ErrorActionPreference=Stop (stderr warnings kill runs) · package ships its own 60-galera.cnf → detect
Galera by `wsrep_on = ON` · Vagrant machine names must include the env · redis-cache 3.0 needs
WP_REDIS_GRACEFUL · power cut can corrupt VMDKs → destroy and redeploy.

---

Project 2, Option A: HAProxy (L7, sticky sessions, health checks) → 4× Nginx + PHP-FPM WordPress/WooCommerce
→ Redis (object cache + PHP sessions) → MariaDB Galera 3-node multi-master. Two environments: `production`, `staging`.
Goal: **one command** takes clean Ubuntu VMs to a working shop, and re-running it changes nothing.

---

## 1. Key decisions

| Topic | Decision | Why |
|---|---|---|
| VM OS | **Ubuntu 24.04 LTS** (`bento/ubuntu-24.04` box) | Supported by all four geerlingguy roles; ships MariaDB 10.11 + `galera-4` in the main repos |
| Hypervisor | **VirtualBox 7.2 + Vagrant 2.4.9** on this Windows host | Static IPs on host-only networks work out of the box (Vagrant's Hyper-V provider can't set static IPs). Tested: runs fine on top of Hyper-V |
| Ansible control node | **WSL2 Ubuntu**, ansible-core in `/opt/ansible` venv, `/etc/wsl.conf` automount `metadata` | Default NAT networking already reaches the host-only networks (tested), so mirrored mode is **not** needed. `metadata` gives real file modes on `/mnt/c`, so Ansible reads `ansible.cfg` and SSH accepts the 0600 key |
| VM definitions | The `Vagrantfile` **reads `inventories/<env>/hosts.yml`** | One source of truth for hostnames/IPs. `ENV=staging vagrant up` brings up the other environment |
| "Clean OS" boundary | Vagrant only creates VMs and drops one SSH public key for a `deploy` user (like cloud-init would) | Everything else (packages, users, hardening, apps) is done by Ansible |
| WordPress source | `wp core download --version=<pinned>` + `wp plugin install woocommerce --version=<pinned>` | Pinned versions, so runs are reproducible and idempotent. Versions live in `group_vars` |
| Shared uploads | **NFS server VM** (`nfs1`) exporting `wp-content/uploads` to all wp nodes | Option A requires shared storage for uploads |
| DB access from WP | WP → **HAProxy TCP frontend :3306** → db1 active, db2/db3 `backup` | Avoids Galera write conflicts (standard practice) while the cluster stays multi-master. Failover is automatic |
| Redis HA | cache1 primary, cache2 replica; WP/PHP reach Redis through a **HAProxy TCP frontend that only sends traffic to the node reporting `role:master`** | Shows health-check logic without adding Sentinel complexity (Sentinel = stretch goal) |
| LB HA | haproxy1 + haproxy2 with **keepalived VIP** | `haproxy[1:2]` is pointless without a floating IP |
| TLS | Self-signed cert generated by `community.crypto` on the LB, HTTP→HTTPS redirect | Realistic setup, no external dependency |
| Role names | Keep the assignment's exact names (`wordpress-setup`, `haproxy-config`, …) | The grader checks for them. ansible-lint's `role-name` rule gets skipped in `.ansible-lint` |
| Language | Code/comments in English, **README in Macedonian** (+ short English section) | Course language. ⚠ confirm |

## 2. Infrastructure layout

### Production — `192.168.56.0/24` (12 VMs, ~6.8 GB RAM)

| Host | IP | Group | vCPU / RAM |
|---|---|---|---|
| *VIP* | 192.168.56.10 | keepalived | — |
| haproxy1, haproxy2 | .11, .12 | `loadbalancers` | 1 / 384 MB |
| wp1–wp4 | .21–.24 | `wordpress` | 1 / 640 MB |
| cache1, cache2 | .31, .32 | `redis` | 1 / 384 MB |
| db1–db3 | .41–.43 | `galera` | 1 / 768 MB |
| nfs1 | .51 | `storage` | 1 / 384 MB |

### Staging — `192.168.57.0/24` (8 VMs, ~4.7 GB RAM)
haproxy1 (single LB, `keepalived_enabled: false`), wp1–wp2, cache1, db1–db3 (Galera needs 3 for quorum), nfs1.

> Sizes were cut because only ~9.5 GB of the 16 GB is free while normal apps are open.

> With 16 GB of host RAM, **only one environment runs at a time**. Both are fully defined and tested, just not at the same time.

### Request flow
```
Client ─HTTPS─► VIP (keepalived) ─► HAProxy[1:2] ──HTTP, cookie SERVERID──► Nginx+PHP-FPM wp[1:4]
                                     │  :3306 tcp (mysql-check) ──► Galera db1 (db2,db3 backup)
                                     │  :6379 tcp (role:master)  ──► Redis cache1 / cache2
                                     └  :8404 stats (vault creds)
wp[1:4] ──NFS──► nfs1:/srv/nfs/wp-uploads
```

## 3. Repository structure

```
infra/
├── ansible.cfg                 # inventory default, roles_path, forks=15, pipelining, callbacks
├── requirements.yml            # galaxy roles (pinned) + collections (community.general, community.mysql, ansible.posix, community.crypto)
├── Vagrantfile                 # parses inventories/$ENV/hosts.yml
├── Makefile / deploy.sh        # `./deploy.sh production` = galaxy install + site.yml (the single command)
├── site.yml                    # imports all playbooks below, in order
├── playbooks/
│   ├── bootstrap.yml           # wait for SSH, python, apt cache (raw-safe)
│   ├── common.yml              # common + security-hardening on all hosts
│   ├── database.yml            # geerlingguy.mysql → galera-cluster
│   ├── storage.yml             # nfs-server
│   ├── cache.yml               # geerlingguy.redis (+ replication include)
│   ├── webservers.yml          # geerlingguy.php, geerlingguy.nginx, wordpress-setup (serial, drained via delegate_to)
│   ├── loadbalancers.yml       # haproxy-config (+ keepalived)
│   ├── rolling_update.yml      # zero-downtime WP/WooCommerce/PHP config update
│   ├── galera_rolling_restart.yml
│   └── verify.yml              # end-to-end smoke tests
├── inventories/
│   ├── production/
│   │   ├── hosts.yml
│   │   ├── group_vars/
│   │   │   ├── all/{main.yml,vault.yml}      # vault.yml = ansible-vault encrypted
│   │   │   ├── loadbalancers.yml  wordpress.yml  redis.yml  galera.yml  storage.yml
│   │   └── host_vars/  haproxy1.yml (keepalived MASTER/prio), db1.yml (galera bootstrap node), …
│   └── staging/   (same shape, smaller)
├── group_vars/all/defaults.yml # env-independent defaults (versions, ports) — inventory group_vars override these
├── roles/
│   ├── common/                 # custom: hostname, /etc/hosts from inventory, chrony (Galera needs time sync), base pkgs, deploy user
│   ├── security-hardening/     # custom (required)
│   ├── galera-cluster/         # custom (required)
│   ├── wordpress-setup/        # custom (required)
│   ├── haproxy-config/         # custom (required) — incl. keepalived
│   ├── nfs-server/  nfs-client # custom (extra)
│   └── (galaxy roles installed into roles/galaxy/ — gitignored)
├── docs/architecture.md        # Mermaid diagram + rendered PNG
├── .ansible-lint  .yamllint  .gitignore (.vault_pass, roles/galaxy/, .vagrant/)
└── README.md
```

Every custom role gets the full standard layout: `defaults/ tasks/ handlers/ templates/ meta/ (argument_specs.yml) vars/ README.md`.
`meta/argument_specs.yml` gives typed parameter validation, which helps the 20-point custom-roles criterion.

## 4. Role designs

### Galaxy roles (pinned in `requirements.yml`)
- **geerlingguy.mysql**: overrides `mysql_packages: [mariadb-server, mariadb-client, mariadb-backup, galera-4]`, `mysql_daemon: mariadb`, root password and DB/user come from the vault. The DB/user are created **only on db1** (`run_once`); Galera replicates them.
- **geerlingguy.php**: PHP 8.3 FPM + `php-mysql, php-redis, php-gd, php-intl, php-mbstring, php-xml, php-zip, php-curl, php-bcmath, php-imagick`, OPcache tuned, `session.save_handler=redis`.
- **geerlingguy.nginx**: base install and `nginx.conf` only. The WordPress vhost is our own template from `wordpress-setup`.
- **geerlingguy.redis**: bind to the private IP, `requirepass` from the vault, `redis_includes` → a replication include rendered by a small task (`replicaof` on cache2).

### Custom: `galera-cluster` (most complex)
- Templates `/etc/mysql/mariadb.conf.d/60-galera.cnf` with `wsrep_cluster_address` built from `groups['galera']`, `wsrep_node_address/name` from host facts, `wsrep_sst_method=mariabackup` (SST user/password from the vault), `binlog_format=ROW`, `innodb_autoinc_lock_mode=2`.
- **Bootstrap logic (idempotent):**
  1. Check `SHOW STATUS LIKE 'wsrep_cluster_size'` on all nodes. If size == number of nodes, skip bootstrap entirely.
  2. If no node is running: read `/var/lib/mysql/grastate.dat`, pick the node with `safe_to_bootstrap: 1` (default `galera_bootstrap_node` = db1), run `galera_new_cluster` on it.
  3. Join the remaining nodes with `serial: 1`, waiting until `wsrep_local_state_comment == Synced` before moving to the next node.
- Handler: `restart mariadb (rolling)`, which never restarts all nodes at once.
- Creates the HAProxy health-check user (`haproxy_check`, no password, host restricted to the LB IPs).

### Custom: `wordpress-setup`
- Installs wp-cli (checksum-verified, `creates:`), creates the site user, the docroot and the `wp-content/uploads` NFS mount point.
- `wp core download` (guarded by `creates: wp-includes/version.php`, version-pinned).
- **`wp-config.php.j2`**: DB host = LB VIP:3306, Redis host/port/password, 8 salts from the vault, `WP_HOME` per environment, `FORCE_SSL_ADMIN` + `$_SERVER['HTTPS']` detection behind the proxy, `DISABLE_WP_CRON=true`.
- `wp core install` and WooCommerce + `redis-cache` plugin install/activate are **`run_once` + `delegate_to: wp1`** (the DB is shared), guarded by `wp core is-installed` / `wp plugin is-active`. Code files are installed on every node.
- WooCommerce bootstrap: store pages, currency (MKD), a few sample products (WC's bundled `sample_products.csv`), so the shop is visibly working.
- Templates: Nginx vhost (`real_ip` from the LB IPs, PHP-FPM socket, static caching, `/healthz` → `healthz.php` that checks DB + Redis) and PHP-FPM pool.
- Permissions: code `root:www-data 0644/0755`, uploads `www-data` writable only.
- System cron `wp cron event run --due-now` **only on the first wp host** (avoids duplicate runs).
- Handlers: `reload nginx`, `reload php-fpm`.

### Custom: `haproxy-config`
- `haproxy.cfg.j2`, built dynamically:
  - `frontend https` (443, TLS) + `http` (80 → 301 redirect)
  - `backend wordpress`: `balance roundrobin`, `cookie SERVERID insert indirect nocache`, `option httpchk GET /healthz` with `http-check expect status 200`, one `server` line per host in `groups['wordpress']` (IP from `hostvars`)
  - `listen galera` (tcp 3306): `option mysql-check user haproxy_check`, db1 active + others `backup`
  - `listen redis` (tcp 6379): `tcp-check send AUTH…/PING/info replication`, `expect string role:master`
  - `listen stats` :8404 with vault credentials and an admin socket at `/run/haproxy/admin.sock`, used for rolling drain
- `validate: haproxy -c -f %s` on the template. Handler `reload haproxy`.
- keepalived template (VRRP, `vrrp_script chk_haproxy`, priority from `host_vars`, auth password from the vault), toggled by `keepalived_enabled`.

### Custom: `security-hardening`
- **UFW**: default deny incoming. Per-group rules come from a `firewall_rules` list in `group_vars` (e.g. db: 3306/4567/4568/4444 only from the private subnet; redis: 6379 only from the LBs; nfs: 2049 only from the wp nodes; LB: 80/443 from anywhere). SSH is always allowed **before** enabling UFW.
- **SSH**: template `sshd_config.d/10-hardening.conf` (no root login, no passwords, `AllowUsers deploy`, MaxAuthTries 3, modern ciphers). `validate: sshd -t -f %s`, and handler `restart ssh` (Ubuntu 24.04 uses ssh.socket, so handle that).
- **fail2ban**: `jail.local.j2` with the `sshd` jail, plus an `nginx-wp-login` jail on wp nodes (works because of real_ip).
- unattended-upgrades (security only), sysctl hardening, `deploy` user with sudo.

### Custom: `common`, `nfs-server`, `nfs-client`
Small, focused roles: `/etc/hosts` from the inventory, chrony, timezone, base packages; NFS export template restricted to `groups['wordpress']` IPs plus a handler `exportfs -ra`; `ansible.posix.mount` on clients.

## 5. Orchestration & deployment strategy (10 pts)

- **site.yml order:** bootstrap → common/hardening (all) → database → storage → cache → **loadbalancers → webservers** → verify.
  The LB tier must come before the web tier: WordPress reaches MariaDB and Redis through the HAProxy VIP, so `wp core install` needs HAProxy to exist. WP backends simply show DOWN until the web tier is up.
- **webservers.yml:** `serial: "50%"`, `max_fail_percentage: 0`. On re-runs, each batch is drained from HAProxy (`community.general.haproxy state=drain`, `delegate_to` each LB in a loop), updated, health-checked with `uri` → `/healthz`, then re-enabled. This only happens when the LB already exists (first run skips it).
- **rolling_update.yml** (e.g. `-e wordpress_version=6.x.y woocommerce_version=…`): `serial: 1`, pre_tasks drain + `wait_for` connections to drop, update, run `wp core update-db` once, health check, post_tasks enable. It fails fast and leaves the remaining nodes untouched.
- **galera_rolling_restart.yml:** `serial: 1`, waits for `Synced` + `wsrep_cluster_size == 3` before continuing; the node is set to `drain`/`maint` in the HAProxy galera listen.
- Other `delegate_to` / `run_once` uses: DB creation on db1, WP install on wp1, cert generation on haproxy1 then distributed to haproxy2.

## 6. Vault & secrets (10 pts)

- `inventories/<env>/group_vars/all/vault.yml` is encrypted per environment and has **different secrets per env**. Vault IDs `--vault-id production@.vault_pass_production` / `staging@.vault_pass_staging`.
- The **encrypted vault is committed** (standard practice, a fresh clone works with just the password). Only `.vault_pass_*` is gitignored. `scripts/generate-vault.sh <env>` creates both with random secrets if they don't exist.
- Pattern: `vault_db_root_password` in vault.yml ↔ `db_root_password: "{{ vault_db_root_password }}"` in plain `main.yml`, so variables stay discoverable without decrypting.
- Secrets: MariaDB root / WP DB user / SST user, Redis password, WP admin password, 8 WP salts, HAProxy stats password, keepalived auth.
- `no_log: true` on every task that handles secrets. `.vault_pass*` is gitignored. The README shows `--ask-vault-pass` and the password-file variant.
- An `vault.example.yml` (unencrypted, fake values) is included so graders can see the schema.

## 7. Execution phases (what I'll do once resources are available)

Each phase ends with a check before moving on.

| # | Phase | Done when |
|---|---|---|
| 0 ✅ | **Tooling:** ansible-core 2.21 in WSL venv, `wsl.conf` metadata mount, VirtualBox 7.2 + Vagrant 2.4.9, `git init` | `ansible --version` works in WSL, `vagrant --version` works |
| 1 ✅ | **Skeleton:** dir structure, ansible.cfg, inventories (both envs), requirements.yml, Vagrantfile reading the inventory, vault files, deploy.sh/deploy.ps1 | `vagrant up` (staging nfs1) → `./deploy.sh staging` is green, lint clean |
| 2 | **common + security-hardening** | SSH still works after the run; `ufw status` correct; second run `changed=0` |
| 3 | **Database:** geerlingguy.mysql + galera-cluster | `wsrep_cluster_size=3`; write on db2 → read on db3; kill all → re-bootstrap works |
| 4 | **Storage + cache:** nfs, redis primary/replica | Mount visible on wp nodes; `INFO replication` on cache2 shows the master link up |
| 5 | **Web tier:** php, nginx, wordpress-setup, WooCommerce + sample data | `curl wpN/healthz` = 200 on every node; shop page renders |
| 6 | **LB tier:** haproxy-config + keepalived + TLS | `https://VIP` serves the shop; stats page lists all backends UP; sticky cookie present |
| 7 | **Orchestration playbooks:** rolling_update, galera_rolling_restart, verify | Rolling update while a `curl` loop runs → zero non-200s |
| 8 | **Idempotency & failure tests** (below) on staging, then a full **production** run from freshly destroyed VMs | All tests pass on both envs |
| 9 | **Quality:** ansible-lint (production profile) + yamllint clean, role READMEs, argument_specs | 0 lint errors |
| 10 | **Docs:** README (MK), architecture diagram (Mermaid + PNG), usage, vault, rolling update, troubleshooting, test evidence | — |

### Verification checklist (Phase 8; results get recorded in the README)
1. Fresh `vagrant destroy -f && vagrant up && ./deploy.sh staging` → success with **one command**.
2. Immediate second run → `changed=0 failed=0` on all hosts.
3. Change a template variable (e.g. PHP `memory_limit`) → only that handler fires.
4. Stop `wp2` → HAProxy marks it DOWN and the site stays up. A sticky user gets re-routed.
5. Stop `db1` → WP keeps working through db2 (HAProxy backup). Start db1 → it rejoins via IST.
6. Stop `haproxy1` → the VIP moves to haproxy2 within a few seconds.
7. Stop Redis `cache1` → the site stays up (object cache degrades gracefully). Documented limitation: no auto-promotion without Sentinel.
8. Upload an image on wp1 → it's served from wp3 (NFS).
9. Place a WooCommerce test order end-to-end (cash-on-delivery gateway).

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| 16 GB RAM is tight | One env at a time, minimal RAM per VM, `linked_clone`, no GUI. Fallback: cloud VMs (same inventory, different IPs) |
| VirtualBox under Hyper-V (WSL2 keeps Hyper-V on) is slower | Acceptable for this scale. Fallback: Hyper-V VMs with an internal NAT switch and static IPs set by a bootstrap script |
| Ansible ignores `ansible.cfg` in world-writable `/mnt/c` | Set `ANSIBLE_CONFIG` explicitly in `deploy.sh`, or enable `metadata` in `wsl.conf` |
| Locking ourselves out with UFW/SSH hardening | Allow SSH before enabling UFW; `sshd -t` validation; Vagrant console as backdoor |
| Galera bootstrap not idempotent / split-brain | State detection via `wsrep_cluster_size` + `grastate.dat` before any bootstrap; `serial: 1` joins |
| geerlingguy.mysql defaults to MySQL on Ubuntu | Explicit `mysql_packages`/`mysql_daemon` overrides; tested in Phase 3 |
| Redis replica has no auto-failover | Documented; Sentinel as stretch goal |

## 9. Stretch goals (only after everything above is green)
Redis Sentinel (custom role), Molecule tests for 1–2 custom roles, GitHub Actions running ansible-lint, Prometheus node/haproxy exporters, WordPress Multisite toggle.

---

## 10. What I need from you before starting autonomously

> **Resolved (2026-10-30):** VirtualBox 7.2 + Vagrant installed; WSL control node set up (root via `wsl -u root`, no password needed);
> README in Macedonian, currency **EUR**, domains `shop.local` / `staging.shop.local`; vault passwords auto-generated into gitignored `.vault_pass_<env>`.

1. **Install (needs admin):** VirtualBox 7.1.x and Vagrant 2.4.x on Windows. Or tell me if you'd rather use cloud VMs / a Proxmox server. In that case send API access/credentials and I'll switch the provisioning layer and keep everything else.
2. **Permission to change WSL config** (`%UserProfile%\.wslconfig` → `networkingMode=mirrored`, which restarts WSL) and to install Ansible inside WSL Ubuntu (I'll need the WSL user's sudo password, or passwordless sudo).
3. **Confirm:** README in Macedonian? Store currency MKD? Domain names (default: `shop.local` for production, `staging.shop.local` for staging, via hosts file)?
4. **Vault password:** I'll generate one into a gitignored `.vault_pass` unless you want to set it yourself.
5. **MCP servers:** none are strictly required, since I can run everything through the shell. A GitHub MCP/`gh` login only matters if you want the project pushed to a repo.
