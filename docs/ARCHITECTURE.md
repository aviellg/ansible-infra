# Architecture & Design

## Overview & Ownership Boundary

`ansible-infra` manages infrastructure provisioning, OS bootstrapping, and containerized service deployment across environments (e.g., `homelab`, `work`).

- **Ansible Layer (Control & Orchestration):** Ansible owns the host configuration, security hardening, user management, and service orchestration files (Docker Compose definitions, environment files, Traefik dynamic configs).
- **Compose Layer (Workload Execution):** Docker Compose manages runtime container lifecycles, healthchecks, network attachments, and local volume mounts.
- **Service Isolation:** Service configuration definitions and templates live inside `roles/ansible-role-apps/services/` rather than at the root to keep orchestration and implementation cleanly separated.

## Storage Tiers

1. **Appdata (`DOCKERDIR/<service>/appdata`):** Service state, databases, application configs. Local to host, backed up regularly.
2. **Media / Bulk Data (`/mnt/...` or remote shares):** Large media assets and shared network storage (e.g. TrueNAS SMB/NFS mounts).
3. **Secrets / Dynamic Configs (`group_vars/*/vault.yml` & templates):** Encrypted at rest via Ansible Vault, rendered during deploy time.

## Routing & Security

- **Traefik Reverse Proxy:** Automatically routes incoming traffic to containers using Docker labels.
- **Socket Proxy:** Restricts Docker socket access so Traefik and other containers cannot execute privileged Docker commands.
- **Hardening:** Applies `devsec.hardening` OS and SSH hardening baseline rules to all nodes.
