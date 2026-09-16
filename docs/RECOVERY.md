# Disaster Recovery & Restoration

## Recovery Procedures

### 1. Control Machine Rebuild
1. Clone `ansible-infra` repository:
   ```bash
   git clone https://github.com/aviellg/ansible-infra.git ~/ansible/ansible-infra
   cd ~/ansible/ansible-infra
   ```
2. Run control machine bootstrap:
   ```bash
   ./setup.sh
   ```
3. Place vault password files at `~/.ansible/vault_pass_homelab` and `~/.ansible/vault_pass_work`.
4. Run `ansible-galaxy install -r requirements.yml`.

### 2. Service Restore from Backup
1. Stop running containers for the service:
   ```bash
   docker compose -f <path-to-compose.yml> down
   ```
2. Restore appdata from backrest / restic / snapshot into `{{ DOCKERDIR }}/<service>/appdata`.
3. Re-run `make apps` or `ansible-playbook apps.yml --limit <host>`.

### 3. Full Node Rebuild
1. Destroy failed VM or provision new VM on Proxmox:
   ```bash
   ansible-playbook site.yml --limit <host>
   ```
2. Restore persistent appdata mounts from backup repository.
3. Restart application stack via `make apps`.

## Backup Layer Overview
| Layer | Target | Mechanism | Frequency |
|---|---|---|---|
| Infrastructure & Config | Control Repository | Git & Encrypted Vault | Continuous on commit |
| Application Data | `DOCKERDIR/*/appdata` | Backrest / Restic to TrueNAS | Daily / Hourly |
| Proxmox VMs | Proxmox OS & Disk | Proxmox Backup Server (PBS) | Daily |
