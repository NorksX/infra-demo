# WordPress + WooCommerce хостинг платформа (Ansible)

Целосна автоматизација на повеќеслојна WordPress/WooCommerce платформа:
HAProxy load balancer (sticky sessions, health checks, keepalived VIP) →
4× Nginx + PHP-FPM → Redis (object cache и сесии) → MariaDB Galera кластер (3 нода),
со NFS споделено складиште за uploads. Две околини: **production** и **staging**.

> Документацијата се дополнува по делови како што се додава секој слој.

## Брз старт

Предуслови (Windows домаќин): VirtualBox 7.x, Vagrant 2.4+, WSL2 Ubuntu со Ansible.

```powershell
# Една команда: креирање на VM-и + целосна конфигурација
.\deploy.ps1 -Environment staging
```

Или чекор по чекор:

```bash
ENV=staging vagrant up          # (во PowerShell: $env:ENV="staging"; vagrant up)
./deploy.sh staging             # од WSL
```

## Структура

| Патека | Опис |
|---|---|
| `inventories/<env>/hosts.yml` | Хостови, IP адреси и големина на VM (го чита и `Vagrantfile`) |
| `inventories/<env>/group_vars/all/main.yml` | Поставки специфични за околината (домен, мрежа, VIP, верзии) |
| `inventories/<env>/group_vars/all/vault.yml` | Шифрирани тајни (Ansible Vault), посебни за секоја околина |
| `inventories/shared/group_vars/` | Заеднички поставки за двете околини (порти, firewall правила по слој) |
| `roles/` | Сопствени улоги; Galaxy улогите се инсталираат во `roles/galaxy/` |
| `playbooks/` | Playbook-и по слоеви, `site.yml` ги повикува по ред |
| `scripts/generate-vault.sh` | Генерира vault лозинка и шифриран vault со случајни тајни |

### Хиерархија на променливи

`deploy.sh` ги вчитува двата инвентари по овој редослед, така што околината
ги презапишува заедничките вредности:

```
-i inventories/shared/hosts.yml -i inventories/<env>/hosts.yml
```

1. `roles/<role>/defaults/` — стандардни вредности на улогата
2. `inventories/shared/group_vars/` — исто за production и staging
3. `inventories/<env>/group_vars/` — специфично за околината (+ vault)
4. `inventories/<env>/host_vars/` — специфично за хост

## Сопствени улоги

| Улога | Што прави |
|---|---|
| `common` | hostname, `/etc/hosts` од инвентарот, chrony, timezone, основни пакети, `deploy` корисник |
| `security-hardening` | UFW (правила по слој од `firewall_rules`), SSH зацврстување (`sshd -t` валидација), fail2ban, sysctl, автоматски безбедносни ажурирања |
| `galera-cluster` | Galera конфигурација (`60-galera.cnf`), безбеден bootstrap/опоравок, rolling restart, HTTP health check (порта 9200) за HAProxy |
| `nfs-server` | NFSv4 export за `wp-content/uploads`, дозволен само за WordPress нодовите (`root_squash`) |
| `nfs-client` | Монтирање на споделените uploads на секој WordPress нод (трајно во fstab) |

## Load balancer (HAProxy)

`haproxy-config` го генерира `haproxy.cfg` од инвентарот (секој нов хост во групата автоматски станува backend):

| Listener | Порта | Логика |
|---|---|---|
| `http` | 80 | 301 пренасочување кон HTTPS |
| `https` → `wordpress` | 443 | roundrobin, sticky sessions (`SERVERID` cookie), health check `GET /healthz`, `redispatch` при пад на нод |
| `mariadb` | 3306 | еден активен Galera нод, останатите `backup`; health check на порта 9200 (само `Synced` нодови) |
| `redis` | 6379 | tcp-check `AUTH` → `PING` → `info replication` — сообраќај добива само нодот со `role:master` |
| `stats` | 8404 | статистика со лозинка од vault (достапна само од приватната мрежа) |

- TLS сертификат (self-signed, SAN = домен + VIP) се генерира еднаш на првиот LB и се дистрибуира на останатите.
- `validate: haproxy -c -f %s` — неисправна конфигурација никогаш не се инсталира; handler-от прави `reload` без прекин на конекциите.
- Production: **keepalived** VIP (`192.168.56.10`) со unicast VRRP; приоритетите се во `host_vars/haproxy1.yml` и `haproxy2.yml`.
- fail2ban jail `haproxy-wp-login` на LB ги блокира (само 80/443) адресите со повеќе неуспешни најави на `wp-login.php`.

Redis го инсталира `geerlingguy.redis` (лозинка од vault, bind на приватната IP).
Во production `cache2` е реплика на `cache1` — дефинирано во `host_vars/cache2.yml` (`redis_replica_of`).

## База на податоци (MariaDB Galera)

`geerlingguy.mysql` го инсталира MariaDB и ги креира базата и корисникот за WordPress;
`galera-cluster` ги поврзува трите нода во multi-master кластер.

**Bootstrap и опоравок** — `playbooks/database.yml` е безбеден за повторно извршување во секоја состојба:

| Состојба | Што прави playbook-от |
|---|---|
| Свежа инсталација | bootstrap од `galera_cluster_bootstrap_node` (db1), останатите се приклучуваат еден по еден (SST со mariabackup) |
| Кластерот работи | ништо (`changed=0`); запрените нодови се стартуваат и чекаат `Synced` |
| Сите нодови се запрени | bootstrap од нодот со `safe_to_bootstrap: 1`, или со највисок `seqno` |
| Пад (crash, `seqno: -1`) | `galera_recovery` ја чита последната позиција од InnoDB, па се избира најновиот нод |

**Rolling restart** — промена на конфигурацијата никогаш не ги рестартира сите нодови истовремено.
Handler-от ги рестартира само нодовите чиј процес е постар од конфигурацијата, еден по еден,
чекајќи `Synced` и `wsrep_cluster_size = 3` пред следниот. Ако извршувањето прекине на половина,
следното извршување ги довршува преостанатите рестарти.

```bash
# Рачен rolling restart (на пр. по ажурирање на пакети)
ansible-playbook playbooks/galera_rolling_restart.yml \
  -i inventories/shared/hosts.yml -i inventories/staging/hosts.yml --vault-id staging@.vault_pass_staging
```

Тестирано на staging: свеж bootstrap, промена на конфигурација, запирање по ред (избран е последниот нод),
симулиран crash на сите три нода, и прекинат rolling restart.

## Ansible Vault

Секоја околина има своја vault лозинка (`.vault_pass_<env>`, не се commit-ира)
и свој шифриран `vault.yml`. Шемата е во `vault.example.yml`.

```bash
ansible-vault view inventories/staging/group_vars/all/vault.yml --vault-id staging@.vault_pass_staging
```
