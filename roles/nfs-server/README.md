# nfs-server / nfs-client

**nfs-server** exports `nfs_server_export_path` over NFSv4 only (so the
firewall needs nothing but 2049/tcp), and only to the hosts in
`nfs_server_clients` (the web tier), with `root_squash`. The directory belongs
to uid/gid 33 (`www-data` on Ubuntu). Handlers: `Reload exports`
(`exportfs -ra`), `Restart nfs-server`.

**nfs-client** (separate role) mounts the export at
`wp-content/uploads` on every web node (`fstab`, hard mount), so a file
uploaded through one node is served by all of them.
