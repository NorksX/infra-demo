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
| `inventories/<env>/group_vars/all/vault.yml` | Шифрирани тајни (Ansible Vault), посебни за секоја околина |
| `group_vars/all/defaults.yml` | Заеднички стандардни вредности (верзии, порти) |
| `roles/` | Сопствени улоги; Galaxy улогите се инсталираат во `roles/galaxy/` |
| `playbooks/` | Playbook-и по слоеви, `site.yml` ги повикува по ред |
| `scripts/generate-vault.sh` | Генерира vault лозинка и шифриран vault со случајни тајни |

## Ansible Vault

Секоја околина има своја vault лозинка (`.vault_pass_<env>`, не се commit-ира)
и свој шифриран `vault.yml`. Шемата е во `vault.example.yml`.

```bash
ansible-vault view inventories/staging/group_vars/all/vault.yml --vault-id staging@.vault_pass_staging
```
