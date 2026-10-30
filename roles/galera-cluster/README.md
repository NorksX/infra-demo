# galera-cluster

MariaDB Galera multi-master cluster on top of a MariaDB installed by
`geerlingguy.mysql`. Safe to run in any cluster state.

## What it does

- Renders `/etc/mysql/mariadb.conf.d/60-galera.cnf`: wsrep settings built from
  the inventory group (`gcomm://` address list, node name/address), SST via
  mariabackup, plus server tuning (`galera_cluster_mysqld_settings`).
- **Converges the cluster** (`tasks/cluster.yml`):
  - running cluster → only stopped nodes are started;
  - no Primary component → stops everything and bootstraps from the node with
    `safe_to_bootstrap: 1`, else the highest `seqno`; after a crash
    (`seqno: -1`) the position is recovered with `galera_recovery`;
  - fresh install → bootstraps `galera_cluster_bootstrap_node`.
  Nodes join one at a time (`delegate_to`), each waiting for `Synced`.
- Creates the SST account and a passwordless `unix_socket` account for health checks.
- Socket-activated HTTP endpoint on port 9200 for HAProxy: `200` when the node
  is Synced (or a mariabackup donor), `503` otherwise.

## Handlers

`Rolling restart Galera` restarts **only nodes whose MariaDB process is older
than their config file**, one by one, waiting for `Synced` and the full cluster
size in between. Because the check compares timestamps instead of relying on
"changed" state, a run that died half-way through a rolling restart is
finished by the next run.

## Entry points

| Entry point | Use |
|---|---|
| `main` | full configuration (playbooks/database.yml) |
| `cluster` | converge only; runs before geerlingguy.mysql so a stopped cluster can't hang it |
| `rolling_restart` | restart all (or `galera_cluster_restart_hosts`) nodes one by one |
| `verify` | assert every node is Primary, Synced and sees the whole cluster |

## Key variables

See `defaults/main.yml` and `meta/argument_specs.yml`. Required:
`galera_cluster_sst_password` (from the vault).
