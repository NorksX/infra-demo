# `files/` — local-only key material

`deploy_key` / `deploy_key.pub` is the SSH key pair for the `deploy` user. It is
generated automatically by the `Vagrantfile` on the first `vagrant up` and is
**not** committed (see `.gitignore`).

- `deploy_key.pub` is written into `/home/deploy/.ssh/authorized_keys` on every VM.
- `deploy_key` is used by Ansible (`private_key_file` in `ansible.cfg`).
  `deploy.sh` makes sure it has mode `0600`.

To regenerate it manually:

```bash
ssh-keygen -t ed25519 -N "" -C "deploy@wordpress-platform" -f files/deploy_key
vagrant provision --provision-with deploy-user
```
