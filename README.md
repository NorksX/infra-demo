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

## Ansible Vault

Секоја околина има своја vault лозинка (`.vault_pass_<env>`, не се commit-ира)
и свој шифриран `vault.yml`. Шемата е во `vault.example.yml`.

```bash
ansible-vault view inventories/staging/group_vars/all/vault.yml --vault-id staging@.vault_pass_staging
```
