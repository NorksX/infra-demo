# wordpress-setup

WordPress + WooCommerce on a web node that already has PHP-FPM
(`geerlingguy.php`) and Nginx (`geerlingguy.nginx`).

## What it does

- **wp-cli**: versioned phar, SHA-512 checksum from the release, `/usr/local/bin/wp` symlink.
- **Core**: `wp core download` at `wordpress_setup_version`. When the version
  changes, only core files are replaced (`--skip-content`) and the schema is
  upgraded with `wp core update-db`.
- **Config** (all templates):
  - `wp-config.php`: DB through the HAProxy VIP, Redis, salts (all from the
    vault), HTTPS detection behind the proxy, `DISALLOW_FILE_MODS`,
    `DISABLE_WP_CRON`; mode `0640 root:www-data`.
  - dedicated PHP-FPM pool with Redis-backed PHP sessions (replaces `www`).
  - Nginx vhost: real client IP from the load balancers, no PHP execution in
    uploads, `/healthz`.
  - `healthz.php`: 200 when PHP and the database work; Redis reported, not required.
- **Plugins**: WooCommerce and Redis Object Cache at pinned versions (files on
  every node, activation once); the `object-cache.php` drop-in; bundled
  Akismet/Hello Dolly removed.
- **Store**: one idempotent `wp eval-file` script sets currency/address, turns
  off "coming soon" mode, creates the shop pages, enables cash on delivery and
  creates sample products by SKU. It prints `changed=N`, so Ansible only
  reports a change when something changed.
- **Cron**: `wp cron event run --due-now` every 5 minutes, only on
  `wordpress_setup_primary_node`.

## Permissions

Code is owned by root and read-only for PHP. Only `wp-content/uploads` (NFS,
`root_squash`) is writable by `www-data`. That's also why database and upload
work runs as `www-data` (`become_user`), and code changes run as root.

## Handlers

`Reload php-fpm` and `Reload nginx`: each runs a config test (`php-fpm8.3 -t`,
`nginx -t`) before the graceful reload.

## Key variables

See `defaults/main.yml` and `meta/argument_specs.yml`. Required (vault):
`wordpress_setup_admin_password`, `wordpress_setup_db_password`,
`wordpress_setup_redis_password`, `wordpress_setup_salts`.
