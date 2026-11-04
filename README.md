# WordPress + WooCommerce хостинг платформа (Ansible)

Целосна автоматизација на повеќеслојна e-commerce платформа: од чисти Ubuntu 24.04 виртуелни
машини до функционална WooCommerce продавница со **една команда**.

**HAProxy** (L7, sticky sessions, health checks, **keepalived VIP**) → **4× Nginx + PHP-FPM**
(WordPress + WooCommerce) → **Redis** (object cache и сесии, primary/replica) → **MariaDB Galera**
(multi-master, 3 нода), со **NFS** споделено складиште за uploads. Две околини: **production** и **staging**.

- [Архитектура](#архитектура)
- [Исполнување на барањата](#исполнување-на-барањата)
- [Брз старт](#брз-старт)
- [Структура на проектот](#структура-на-проектот)
- [Ansible Vault](#ansible-vault)
- [Улоги](#улоги)
- [Слоеви](#слоеви)
- [Оркестрација и deployment стратегија](#оркестрација-и-deployment-стратегија)
- [Тестирање](#тестирање)
- [Решавање проблеми](#решавање-проблеми)
- [English summary](#english-summary)

## Архитектура

```
                            Клиент (прелистувач)
                                    │ HTTPS :443  (HTTP :80 → 301)
                                    ▼
                  ┌────────── VIP 192.168.56.10 (keepalived) ──────────┐
                  │  haproxy1 (MASTER, prio 150)   haproxy2 (BACKUP)   │
                  │  :443 → wordpress   :3306 → mariadb                │
                  │  :6379 → redis      :8404 stats                    │
                  └───────┬───────────────────────┬──────────┬─────────┘
       HTTP :80, cookie   │                       │ :3306    │ :6379
       SERVERID,          ▼                       ▼          ▼
       GET /healthz  ┌─────────┬─────────┬─────────┬─────────┐   ┌──────────────────────┐
                     │  wp1    │  wp2    │  wp3    │  wp4    │   │ cache1 ──▶ cache2    │
                     │ Nginx + PHP-FPM + WordPress/WooCommerce│   │ primary    replica   │
                     └────┬────┴────┬────┴────┬────┴────┬────┘   └──────────────────────┘
                          │  DB и Redis преку VIP (HAProxy)       HAProxy праќа само на role:master
                          │
                          │ NFSv4 wp-content/uploads          ┌──────────────────────────┐
                          └────────────▶ nfs1                 │ db1 ◀──▶ db2 ◀──▶ db3    │
                                                              │ Galera multi-master      │
                                                              │ (запишува db1, другите   │
                                                              │  се backup во HAProxy)   │
                                                              └──────────────────────────┘
```

Детален дијаграм (Mermaid), порти и firewall правила: [docs/architecture.md](docs/architecture.md).

| Околина | Мрежа | Хостови | RAM |
|---|---|---|---|
| production | `192.168.56.0/24`, VIP `.10` | haproxy1–2, wp1–4, cache1–2, db1–3, nfs1 (12 VM) | ~6.2 GB |
| staging | `192.168.57.0/24` | haproxy1, wp1–2, cache1, db1–3, nfs1 (8 VM) | ~4.6 GB |

Staging има ист код и иста структура, само помалку нодови. Galera останува со 3 нода поради кворум.

## Исполнување на барањата

| Барање | Каде |
|---|---|
| Целосна автоматизација со една команда | `.\deploy.ps1 -Environment production` → `vagrant up` + `deploy.sh` → `site.yml` |
| `roles/`, `inventory/`, `group_vars/`, `host_vars/` | `roles/`, `inventory/{production,staging}/{hosts.yml,group_vars,host_vars}`, `group_vars/` (заеднички) |
| Galaxy улоги | `geerlingguy.mysql`, `geerlingguy.php`, `geerlingguy.nginx`, `geerlingguy.redis` (`requirements.yml`, фиксни верзии) |
| ≥ 3 сопствени улоги | **`wordpress-setup`, `haproxy-config`, `galera-cluster`, `security-hardening`**, плус `common`, `nfs-server`, `nfs-client` |
| Ansible Vault | `inventory/<env>/group_vars/all/vault.yml` (посебни тајни по околина), `.vault_pass` во `ansible.cfg`, `no_log` |
| Идемпотентност | второ извршување на `site.yml` → `changed=0` на сите хостови (тестирано) |
| Handlers | reload haproxy/nginx/php-fpm (со config test), rolling restart Galera, exportfs, fail2ban, ssh, sysctl … |
| Jinja2 темплејти | `haproxy.cfg`, `keepalived.conf`, `wp-config.php`, `60-galera.cnf`, Nginx vhost, PHP-FPM pool, `sshd`, `jail.local`, `exports`, `/etc/hosts` … |
| production и staging | `inventory/production`, `inventory/staging` |
| serial, delegate_to, rolling updates | `webservers.yml` (`serial: 50%`), `rolling_update.yml` (`serial: 1` + drain на LB), `galera-cluster` (`delegate_to` при bootstrap/restart) |
| README + архитектурен дијаграм | овој документ, [docs/architecture.md](docs/architecture.md), README во секоја улога |

## Брз старт

### Предуслови (Windows домаќин)

1. **VirtualBox 7.x** и **Vagrant 2.4+**.
2. **WSL2 Ubuntu** како Ansible контролен нод:

   ```bash
   # во WSL (како root: wsl -u root)
   apt-get install -y python3-venv sshpass
   python3 -m venv /opt/ansible
   /opt/ansible/bin/pip install ansible-core ansible-lint yamllint
   ln -s /opt/ansible/bin/ansible* /usr/local/bin/
   ```

3. Вистински Linux дозволи на `/mnt/c` (во спротивно Ansible не го чита `ansible.cfg`,
   а SSH го одбива клучот) — `/etc/wsl.conf`, па `wsl --shutdown`:

   ```ini
   [automount]
   options = "metadata,umask=22,fmask=111"
   ```

### Една команда

```powershell
.\deploy.ps1 -Environment staging      # или production
```

Ова: креира VM-и од `inventory/<env>/hosts.yml` → генерира SSH клуч, vault лозинка и шифриран vault
(ако ги нема) → инсталира Galaxy улоги/колекции → извршува `site.yml` → **end-to-end тест** со вистинска нарачка.

Чекор по чекор (на пр. само Ansible делот):

```bash
ENV=staging vagrant up        # PowerShell: $env:ENV="staging"; vagrant up
./deploy.sh staging           # од WSL; дополнителни аргументи одат кон ansible-playbook
./deploy.sh staging --tags haproxy --limit loadbalancers
```

### Друг компјутер

- Ископирајте ја `.vault_pass` (не е во git). Без неа шифрираните vault-ови не можат да се отворат,
  а `deploy.sh` застанува со јасна порака. Алтернатива: избришете ги двата `vault.yml` и ќе се
  генерираат нова лозинка и нови тајни.
- Поголеми VM-и на посилен домаќин (на пр. 24 GB RAM): `$env:VM_MEMORY_SCALE = "1.5"; .\deploy.ps1`
  — ги множи сите `vb_memory` од инвентарот (VM-ите што веќе постојат треба `vagrant reload`).

### Пристап до продавницата

Додајте во `C:\Windows\System32\drivers\etc\hosts`:

```
192.168.56.10  shop.local             # production (VIP)
192.168.57.11  staging.shop.local     # staging
```

| Што | Адреса |
|---|---|
| Продавница | `https://shop.local/shop/` (self-signed сертификат) |
| Администрација | `https://shop.local/wp-admin/` — корисник `admin` |
| HAProxy статистика | `http://192.168.56.11:8404/` — корисник `admin` |

Лозинките се во vault-от:

```bash
ansible-vault view inventory/production/group_vars/all/vault.yml
```

## Структура на проектот

```
├── deploy.ps1 / deploy.sh        # една команда (Windows / контролен нод)
├── Vagrantfile                   # VM-и од inventory/$ENV/hosts.yml
├── ansible.cfg, requirements.yml
├── site.yml                      # целиот deployment, по слоеви (import_playbook)
├── bootstrap.yml  common.yml  database.yml  storage.yml  cache.yml
├── loadbalancers.yml  webservers.yml  verify.yml
├── rolling_update.yml            # zero-downtime ажурирање на web слојот
├── galera_rolling_restart.yml
├── tasks/haproxy_backend_status.yml
├── group_vars/                   # исто за двете околини: all/main.yml + по слој (galera, wordpress …)
├── inventory/
│   ├── production/
│   │   ├── hosts.yml
│   │   ├── group_vars/all/{main.yml, vault.yml, vault.example.yml}
│   │   └── host_vars/{haproxy1,haproxy2,cache2}.yml
│   └── staging/   (иста структура)
├── roles/
│   ├── common/  security-hardening/  galera-cluster/  haproxy-config/
│   ├── wordpress-setup/  nfs-server/  nfs-client/
│   └── galaxy/                   # geerlingguy.* (се инсталираат, не се commit-ираат)
├── scripts/generate-vault.sh
└── docs/architecture.md
```

Секоја сопствена улога има `defaults/`, `tasks/`, `handlers/`, `templates/`, `meta/main.yml`,
**`meta/argument_specs.yml`** (типизирана валидација на параметрите) и `README.md`.

### Хиерархија на променливи

Околината се избира само со инвентарот: `ansible-playbook -i inventory/staging/hosts.yml site.yml`.
Од најслаб кон најсилен (редоследот на Ansible за предност на променливите):

1. `roles/<role>/defaults/` — стандардни вредности на улогата
2. `inventory/<env>/group_vars/all/` — специфично за околината (домен, мрежа, VIP, верзии) + vault
3. `group_vars/` до playbook-ите (playbook group_vars) — исто за production и staging
   (на пр. firewall правила и Galaxy поставки по слој)
4. `inventory/<env>/host_vars/` — специфично за хост (keepalived приоритет, Redis реплика)

Playbook `group_vars` имаат предност пред inventory `group_vars`, па секоја променлива е дефинирана
**само на едно место**: или е иста насекаде (`group_vars/`), или зависи од околината (`inventory/<env>/`).
Затоа playbook-ите се во коренот на проектот, до `group_vars/`, а `ansible.cfg` има `playbook_dir = .`
за и ad-hoc командите да ги читаат.

## Ansible Vault

- Лозинката е во скриената датотека **`.vault_pass`** (во `.gitignore`), зададена во `ansible.cfg`
  (`vault_password_file = .vault_pass`), па playbook-ите се извршуваат без прашање за лозинка.
- Секоја околина има **свои тајни** во шифриран `inventory/<env>/group_vars/all/vault.yml`
  (различни случајни вредности за production и staging).
- Шифрираниот `vault.yml` **се commit-ира** (вообичаена пракса) — без лозинката е бескорисен.
- `scripts/generate-vault.sh <env>` ги создава лозинката и vault-от со случајни вредности ако не постојат.
- Шема (лажни вредности): `vault.example.yml`. Конвенција: `x_vault` во vault → `x: "{{ x_vault }}"` во `main.yml`,
  па сите имиња на променливи се видливи без дешифрирање.
- Тајните: MariaDB root, WordPress DB, Galera SST, Redis, WordPress admin, 8 WordPress salts, HAProxy stats, VRRP.
- Задачите што ракуваат со тајни имаат `no_log: true`; датотеките со тајни се `0640`/`0600`.

```bash
ansible-vault view  inventory/staging/group_vars/all/vault.yml
ansible-vault edit  inventory/staging/group_vars/all/vault.yml
# нова лозинка: rekey на двата vault-а, па замена на датотеката
ansible-vault rekey inventory/*/group_vars/all/vault.yml --new-vault-password-file .vault_pass.new \
  && mv .vault_pass.new .vault_pass
```

## Улоги

### Galaxy (фиксни верзии во `requirements.yml`)

| Улога | Користење |
|---|---|
| `geerlingguy.mysql` 6.5.0 | MariaDB (не MySQL) + база и корисник за WordPress; конфигурацијата оди во `mariadb.conf.d/50-server.cnf` |
| `geerlingguy.php` 6.1.0 | PHP 8.3 + модули (mysql, redis, intl, gd, imagick …), `php.ini`, OPcache |
| `geerlingguy.nginx` 3.3.1 | Nginx; vhost-от доаѓа од `wordpress-setup` |
| `geerlingguy.redis` 2.0.0 | Redis со лозинка; репликација од `host_vars` |

### Сопствени

| Улога | Што прави |
|---|---|
| [`wordpress-setup`](roles/wordpress-setup/README.md) | wp-cli (проверен checksum), WordPress core + WooCommerce + Redis Object Cache, `wp-config.php` од vault, PHP-FPM pool, Nginx vhost, `/healthz`, поставки на продавницата, cron само на еден нод |
| [`haproxy-config`](roles/haproxy-config/README.md) | `haproxy.cfg` со динамички backends од инвентарот, sticky sessions, health checks, stats, TLS, keepalived VIP |
| [`galera-cluster`](roles/galera-cluster/README.md) | wsrep конфигурација, безбеден bootstrap/опоравок, rolling restart, HTTP health check за HAProxy |
| [`security-hardening`](roles/security-hardening/README.md) | UFW правила по слој, SSH зацврстување, fail2ban, sysctl, безбедносни ажурирања |
| [`common`](roles/common/README.md) | hostname, `/etc/hosts` од инвентарот, chrony, timezone, `deploy` корисник |
| [`nfs-server`, `nfs-client`](roles/nfs-server/README.md) | NFSv4 споделени uploads |

## Слоеви

### База на податоци (MariaDB Galera)

`geerlingguy.mysql` го инсталира MariaDB и ги креира базата и корисникот; `galera-cluster` ги поврзува
трите нода во multi-master кластер. `database.yml` е безбеден во секоја состојба:

| Состојба | Што прави playbook-от |
|---|---|
| Свежа инсталација | bootstrap од `db1`, останатите се приклучуваат **еден по еден** (SST со mariabackup) |
| Кластерот работи | ништо (`changed=0`); запрените нодови се стартуваат и чекаат `Synced` |
| Сите нодови се запрени | bootstrap од нодот со `safe_to_bootstrap: 1` (последниот што излегол), или со највисок `seqno` |
| Пад (crash, `seqno: -1`) | `galera_recovery` ја чита последната позиција од InnoDB, па се избира најновиот нод |

Опоравокот се извршува и **пред** `geerlingguy.mysql`, бидејќи неговото „start MariaDB“ би висело ако
целиот кластер е запрен. Промена на конфигурацијата прави **rolling restart**: само нодовите чиј процес
е постар од конфигурацијата, еден по еден, со чекање на `Synced` — ако извршувањето прекине на половина,
следното ги довршува преостанатите рестарти.

HAProxy праќа запишувања само на `db1` (другите се `backup`) — избегнува Galera certification конфликти,
а failover е автоматски. Health check-от (порта 9200) враќа 200 само кога нодот е `Synced`.

### Cache и складиште

- **Redis** (`geerlingguy.redis`): лозинка од vault, bind на приватната IP, `allkeys-lru`.
  DB 0 = WordPress object cache, DB 1 = PHP сесии. Во production `cache2` е реплика на `cache1`
  (`host_vars/cache2.yml`); HAProxy праќа клиенти само на нодот што пријавува `role:master`.
- **NFS** (`nfs-server`/`nfs-client`): NFSv4-only export на `wp-content/uploads` само за web нодовите,
  `root_squash`. Слика качена преку еден нод се служи од сите.

### Load balancer (HAProxy)

`haproxy-config` го генерира `haproxy.cfg` од инвентарот (нов хост во групата → нов backend):

| Listener | Порта | Логика |
|---|---|---|
| `http` | 80 | 301 кон HTTPS |
| `https` → `wordpress` | 443 | roundrobin, **sticky sessions** (`SERVERID` cookie), health check `GET /healthz`, `redispatch` при пад |
| `mariadb` | 3306 | еден активен Galera нод + `backup`; health check :9200 |
| `redis` | 6379 | tcp-check `AUTH` → `PING` → `info replication` → само `role:master` |
| `stats` | 8404 | статистика со лозинка од vault |

- TLS (self-signed, SAN = домен + VIP) се генерира еднаш на првиот LB и се копира на останатите.
- `validate: haproxy -c -f %s` — неисправна конфигурација никогаш не се инсталира; reload без прекин на конекциите.
- **keepalived** (production): unicast VRRP, VIP оди на haproxy2 ако haproxy1 или неговиот HAProxy падне.
- fail2ban jail `haproxy-wp-login` на LB блокира (само 80/443) адреси со многу неуспешни најави.

### Web (Nginx + PHP-FPM + WordPress)

- **Код** (`/var/www/wordpress`) е во сопственост на root, само за читање за PHP; единствено uploads (NFS)
  е запишлив. `DISALLOW_FILE_MODS` — кодот го менува само Ansible.
- **Верзии** се фиксни: staging = WordPress 7.1.4 / WooCommerce 11.2.1, production е една верзија назад
  (7.0.8 / 11.1.2) — новата верзија прво се тестира во staging, па оди во production со `rolling_update.yml`.
- **Еднократни операции** (инсталација, plugin-и, поставки) само на `wp1` (`run_once` + `delegate_to`).
- **Тајни** само во `wp-config.php` и PHP-FPM pool-от (`0640`), никогаш во `php.ini`.
- `/healthz`: 200 кога PHP-FPM и базата работат; Redis е само „degraded“ (WordPress работи и без cache).
- WooCommerce: EUR, адреса во Скопје, „coming soon“ исклучено, страници, наплата при испорака, 5 примерни производи.

## Оркестрација и deployment стратегија

| Playbook | Стратегија |
|---|---|
| `site.yml` | bootstrap → common/hardening → база → NFS → Redis → **HAProxy → web** → verify (LB е пред web бидејќи WordPress ги користи MariaDB и Redis преку HAProxy) |
| `webservers.yml` | `serial: 50%` + `max_fail_percentage: 0` — ако една половина падне, извршувањето застанува, другата продолжува да служи |
| `rolling_update.yml` | `serial: 1`: проверка дека други нодови се UP → **drain на секој LB** (`delegate_to`) и чекање да завршат конекциите → ажурирање → враќање дури кога HAProxy health check-от го пријави нодот UP |
| `galera_rolling_restart.yml` | рестарт на Galera нодовите еден по еден, со чекање на `Synced` |
| `verify.yml` | end-to-end тест од контролниот нод преку VIP: HTTP→HTTPS, sticky cookie, продавница, **вистинска нарачка** преку WooCommerce Store API (потоа се брише) |

Други `delegate_to` / `run_once`: TLS сертификат (haproxy1), инсталација на WordPress (wp1),
приклучување и рестартирање на Galera нодови, drain/enable на секој load balancer.

```bash
# Нова верзија: inventory/production/group_vars/all/main.yml → wordpress_version / woocommerce_version, па:
ansible-playbook rolling_update.yml -i inventory/production/hosts.yml

# Rolling restart на Galera (на пр. по ажурирање на пакети)
ansible-playbook galera_rolling_restart.yml -i inventory/production/hosts.yml
```

## Тестирање

Квалитет: `ansible-lint` (профил **production**) и `yamllint` — 0 грешки.

| # | Тест | Резултат |
|---|---|---|
| 1 | Свежи VM-и + една команда (`.\deploy.ps1 -Environment staging`, празен cache за преземања) | успешно од прв обид: **29 мин** (8 VM-и + 19 мин Ansible), 0 грешки, нарачка во `verify.yml` |
| 2 | Второ извршување на `site.yml` | `changed=0` на сите хостови |
| 3 | Промена на темплејт → само соодветниот handler | на пр. Galera: само тие нодови, еден по еден |
| 4 | Galera: свеж bootstrap / запирање по ред / crash на сите три / прекинат rolling restart | кластерот секогаш се враќа, без загуба на податоци (избран е нодот со најнови податоци) |
| 5 | Репликација: запис на db2 и db3 → читање на db1 | ✔ |
| 6 | Rolling update 7.1.4 → 7.1.3 → 7.1.4 под ~5 барања/s | 97/97 и 112/112 одговори 200 |
| 7 | NFS: датотека запишана на wp1 → видлива на wp2 | ✔ (`root_squash` го одбива root) |
| 8 | End-to-end нарачка преку HAProxy (Store API, наплата при испорака) | ✔ (`verify.yml`, на секое извршување) |
| 9 | Firewall: Galera/Redis/web порти недостапни од надвор | ✔ |

**Production (12 VM), со сообраќај ~4–5 барања/s преку VIP за време на секој тест:**

| # | Тест | Резултат |
|---|---|---|
| P1 | Deploy од нула со `deploy.ps1` (прекинат со нестанок на струја, па продолжен) | успешно; повторно извршување `changed=0` на сите 12 хоста + нарачка во `verify.yml` |
| P2 | HAProxy запрен на нодот со VIP | VIP на другиот LB за ~1 s; **1 од 55** барања неуспешно (во моментот на падот) |
| P3 | wp2 исклучен (клиент со `SERVERID=wp2`) | **16/16** OK; клиентот автоматски префрлен на друг нод |
| P4 | MariaDB запрен на db1 (writer) | **34/34** OK; db2 презема, db1 се враќа со IST и е `Synced` |
| P5 | Redis primary (cache1) запрен | **13/13** OK; сајтот работи без cache (`redis=degraded`), cache2 е реплика (`master_link_status:up`) |
| P6 | NFS: датотека од wp1 → читање на wp3 | ✔ |
| P7 | Вистинско ажурирање 7.0.8 / WC 11.1.2 → 7.1.4 / WC 11.2.1 (`rolling_update.yml`) | **257/257** одговори 200; секој нод drain-иран на двата LB; checksum проверка на core и plugin датотеки |

Грешки откриени и поправени со овие тестови (види git историја): Redis Object Cache 3.0 бара
`WP_REDIS_GRACEFUL` (без него пад на Redis → 500 на секоја страница), побавни health checks,
VIP се враќаше назад (`nopreempt`), бавно преземање од wordpress.org (сега еднаш на контролниот нод),
стар `alloptions` во Redis по ажурирање (flush на object cache), детекција на Galera по `wsrep_on`.

## Решавање проблеми

| Симптом | Причина / решение |
|---|---|
| `Ansible is being run in a world writable directory` | вклучете `metadata` во `/etc/wsl.conf` (види предуслови) или `export ANSIBLE_CONFIG=$PWD/ansible.cfg` |
| `UNPROTECTED PRIVATE KEY FILE` | `chmod 600 files/deploy_key` (`deploy.sh` го прави тоа) |
| `vagrant up` чека SSH по рестарт | VM-ите се зацврстени; KEX алгоритмите за Vagrant (net-ssh) се дозволени во `security-hardening` |
| Galera не стартува по рестарт на сите VM-и | `./deploy.sh <env> --limit galera` — опоравокот го избира најновиот нод |
| Сајтот враќа 503 | `http://<lb>:8404/` — кои backends се DOWN; `curl http://<wp>/healthz` на нодот |
| VM не стартува по нестанок на струја (`VERR_VD_VMDK_INVALID_HEADER`) | дискот е оштетен: `vagrant destroy -f` и повторно `.\deploy.ps1` — сè се креира одново |
| Најава од прелистувачот е блокирана | fail2ban на LB: `sudo fail2ban-client set haproxy-wp-login unbanip <ip>` |

## English summary

Ansible automation for a multi-tier WordPress + WooCommerce hosting platform (course project, option A).
`.\deploy.ps1 -Environment production` creates 12 Ubuntu 24.04 VMs (Vagrant + VirtualBox) and configures
HAProxy with a keepalived VIP, sticky sessions and health checks; 4 Nginx + PHP-FPM WordPress nodes;
a 3-node MariaDB Galera cluster (safe bootstrap/recovery, rolling restarts); Redis primary/replica for the
object cache and PHP sessions; and NFS for shared uploads. It finishes with an end-to-end test that places a
real order. Custom roles: `wordpress-setup`, `haproxy-config`, `galera-cluster`, `security-hardening`
(plus `common`, `nfs-server`, `nfs-client`); Galaxy roles: `geerlingguy.mysql/php/nginx/redis`.
Secrets are in per-environment Ansible Vaults. Re-runs are idempotent (`changed=0`), and
`rolling_update.yml` upgrades the web tier one node at a time with zero downtime.
