# haproxy-config

HAProxy for the whole platform, generated from the inventory: adding a host to
`wordpress`, `galera` or `redis` adds it as a backend server on the next run.

## Listeners

| Name | Port | Behaviour |
|---|---|---|
| `http` | 80 | 301 to HTTPS |
| `https` → `wordpress` | 443 | roundrobin, sticky `SERVERID` cookie, `GET /healthz` checks, `option redispatch` |
| `mariadb` | 3306 | one active Galera node, the others `backup`; checked on :9200 (galera-cluster) |
| `redis` | 6379 | `tcp-check`: AUTH → PING → `info replication`, expects `role:master` |
| `stats` | 8404 | stats page, credentials from the vault |

Admin socket: `/run/haproxy/admin.sock` (used by `rolling_update.yml` to drain servers).

## Also

- **TLS**: one self-signed certificate (SAN: domain + VIP), generated on the
  first load balancer (`run_once` + `delegate_to`) and copied to the others.
- **keepalived** (`haproxy_config_keepalived_enabled`): unicast VRRP, gives up
  the VIP when HAProxy stops; priorities via `keepalived_priority` in host_vars.
- **Logging**: to rsyslog over 127.0.0.1 UDP. Ubuntu's rsyslog AppArmor profile
  rejects the packaged socket inside HAProxy's chroot. The log feeds the
  `haproxy-wp-login` fail2ban jail.

## Handlers

`Reload haproxy` (seamless master-worker reload; the config is checked with
`haproxy -c` before it is installed), `Reload keepalived`, `Restart rsyslog`.

## Key variables

See `defaults/main.yml` and `meta/argument_specs.yml`. Required (vault):
`haproxy_config_redis_password`, `haproxy_config_stats_password`.
