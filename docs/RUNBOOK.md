# Runbook & Operations

## Day-2 Operations

### Common Commands
- **Dry-run deployment:** `make check`
- **Full infrastructure & apps deploy:** `make deploy`
- **Application updates only:** `make apps`
- **Check node reachability:** `make ping`
- **Edit environment secrets:** `make vault-edit ENV=homelab`
- **Reset service appdata:** `make reset SERVICE=<name>`

### Where Logs Live
- **Docker Container Logs:** `docker logs -f <container_name>`
- **Traefik Access & Error Logs:** Inside Traefik container stdout or configured log files in `DOCKERDIR/traefik/logs`
- **System Auth / Security Logs:** `/var/log/auth.log` or `journalctl -u ssh`

### Configuration Provenance
Generated configuration files contain a provenance header linking back to their Jinja2 source template in `roles/ansible-role-apps/`. Do not edit generated configuration on target hosts directly; edit the template in the repo and run `make apps`.
