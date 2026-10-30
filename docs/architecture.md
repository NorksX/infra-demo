# Архитектура / Architecture

## Сообраќај / Request flow (production)

```mermaid
flowchart TB
    client([Клиент / Browser])

    subgraph LB["Load balancer tier — haproxy-config"]
        direction LR
        vip{{"VIP 192.168.56.10<br/>keepalived (VRRP)"}}
        h1["haproxy1 .11<br/>priority 150"]
        h2["haproxy2 .12<br/>priority 100"]
        vip -.-> h1
        vip -.-> h2
    end

    subgraph WEB["Web tier — geerlingguy.php + geerlingguy.nginx + wordpress-setup"]
        direction LR
        wp1["wp1 .21<br/>Nginx + PHP-FPM<br/>WordPress + WooCommerce<br/>(cron, one-off DB work)"]
        wp2["wp2 .22"]
        wp3["wp3 .23"]
        wp4["wp4 .24"]
    end

    subgraph DB["Database tier — geerlingguy.mysql + galera-cluster"]
        direction LR
        db1[("db1 .41<br/>writer")]
        db2[("db2 .42<br/>backup")]
        db3[("db3 .43<br/>backup")]
        db1 <-->|wsrep| db2
        db2 <-->|wsrep| db3
        db3 <-->|wsrep| db1
    end

    subgraph CACHE["Cache tier — geerlingguy.redis"]
        direction LR
        c1[("cache1 .31<br/>primary")]
        c2[("cache2 .32<br/>replica")]
        c1 -->|replicaof| c2
    end

    nfs[("nfs1 .51<br/>NFSv4 uploads<br/>nfs-server")]

    client -->|"HTTPS :443 (HTTP :80 → 301)"| vip
    h1 -->|"HTTP :80, sticky SERVERID,<br/>check GET /healthz"| WEB
    WEB -->|"MariaDB :3306 via VIP"| vip
    WEB -->|"Redis :6379 via VIP<br/>object cache + sessions"| vip
    h1 -->|":3306, check :9200 (Synced)"| DB
    h1 -->|":6379, check role:master"| CACHE
    WEB ---|"wp-content/uploads<br/>nfs-client"| nfs
```

Staging (`192.168.57.0/24`) has the same structure with one HAProxy (no VIP),
2 web nodes and 1 Redis; Galera stays at 3 nodes because quorum needs them.

## Порти и firewall / Ports and firewall (UFW, `security-hardening`)

| Host group | Open port | Allowed from |
|---|---|---|
| all | 22/tcp | anywhere (lab) |
| loadbalancers | 80, 443 | anywhere |
| loadbalancers | 8404 (stats) | private subnet |
| loadbalancers | 3306, 6379 | web nodes |
| loadbalancers | all protocols (VRRP) | the other load balancer |
| wordpress | 80 | load balancers |
| galera | 3306 | load balancers, cluster members |
| galera | 4567, 4568, 4444 | cluster members |
| galera | 9200 (health) | load balancers |
| redis | 6379 | load balancers, Redis peers |
| storage | 2049 | web nodes |

## Deployment order (`site.yml`)

```mermaid
flowchart LR
    a[bootstrap] --> b[common +<br/>security-hardening] --> c[database] --> d[storage] --> e[cache] --> f[loadbalancers] --> g["webservers<br/>(serial 50%)"] --> h[verify]
```

The load balancer tier comes **before** the web tier: WordPress reaches MariaDB
and Redis through HAProxy, so `wp core install` needs HAProxy to exist.
