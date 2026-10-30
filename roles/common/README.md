# common

Base OS setup for every platform host:

- hostname = inventory name; `/etc/hosts` rendered from the inventory (every
  host plus the site name pointing at the load balancer VIP);
- timezone and chrony (Galera and TLS need correct clocks);
- base packages;
- the `deploy` user Ansible connects as: only the project key
  (`authorized_key` with `exclusive`), passwordless sudo validated with `visudo`.

Handler: `Restart chrony`. Variables: `defaults/main.yml`, `meta/argument_specs.yml`.
