# nfs-client

Mounts the NFSv4 export from `nfs-server` at `wp-content/uploads` on every web
node (persisted in `fstab`, hard mount), so a file uploaded through one node
is served by all of them.

| Variable | Default |
|---|---|
| `nfs_client_server` | first host of the `storage` group |
| `nfs_client_export_path` | `/srv/nfs/wp-uploads` (must match `nfs_server_export_path`) |
| `nfs_client_mount_path` | `{{ wp_docroot }}/wp-content/uploads` |
| `nfs_client_mount_options` | `rw,hard,noatime,vers=4.2,_netdev` |

With `root_squash` on the server, root on a web node cannot write to the
mounted directory, so the mount point is only created while nothing is mounted.
See [nfs-server](../nfs-server/README.md) for the export side.
