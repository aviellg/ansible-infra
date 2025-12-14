# Ansible Role: Traefik

## Overview

This Ansible role sets up Traefik v3 as a reverse proxy on a Docker-based environment. It includes configurations for secure HTTP traffic, authentication, logging, and integration with Cloudflare DNS for automated SSL certificate management.

## Requirements

- Ansible 2.9+ installed on the control node
- Docker installed on the target node
- Access to a Cloudflare account with API tokens
- Basic understanding of Docker and Ansible
- **Ansible Role: [ansible-role-docker](https://github.com/yourusername/ansible-role-docker)**
- port 80 and 443 open on the target node
- point *.yourdomain.com in your DNS to the target node's IP

## Role Variables

- `PUID`: User ID for Docker processes
- `PGID`: Group ID for Docker processes
- `TZ`: Timezone configuration
- `USERDIR`: Home directory of the user
- `DOCKERDIR`: Directory for Docker files
- `DATADIR`: Directory for data storage
- `HOSTNAME`: Hostname of the server
- `DOMAINNAME_1`: Primary domain name
- `LOCAL_IPS`: Local IP addresses
- `CLOUDFLARE_IPS`: Cloudflare IP addresses
- `http_username`: Username for basic authentication
- `http_password`: Password for basic authentication
- `cloudflare_dns_api_token`: API token for Cloudflare DNS
- `docker_privileged_mode`: Boolean to set Docker container privileged mode (`true` for VMs, `false` for unprivileged LXC containers on Proxmox)

## Dependencies

No dependencies are required for this role.

## General Steps

1. **Firewall Configuration:**
   - Allow HTTP and HTTPS traffic through UFW firewall.

2. **Environment File:**
   - Create and populate a `.env` file with required environment variables.

3. **Secrets Management:**
   - Create secret files for `basic_auth_credentials` and `cf_dns_api_token`.

4. **Directory and File Setup:**
   - Create necessary directories for Traefik configuration and logging.
   - Create and set permissions for `acme.json`.
   - Create empty log files for Traefik.

5. **Socket Proxy Setup:**
   - Define `socket_proxy` network in `docker-compose-udms.yml`.
   - Create the `socket-proxy.yml` file, specifying privileged mode based on the `docker_privileged_mode` variable - veriables is managed by ansible task that check if it is using container or vm  .

6. **Traefik v3 Configuration:**
   - Create the `traefik.yml` file with all necessary configurations.
   - Include Traefik in the master Docker Compose file.

7. **TLS Options:**
   - Create `tls-opts.yml` for custom TLS configurations.

8. **Middleware Configuration:**
   - Create `middlewares-basic-auth.yml` for Traefik's basic authentication.
   - Create `chain-no-auth.yml` and `chain-basic-auth.yml` for middleware chains.

9. **Master Docker Compose Update:**
   - Update `docker-compose-udms.yml` to include paths for `socket-proxy.yml` and `traefik.yml`.

## Example Playbook

```yaml
- hosts: servers
  roles:
    - ansible-role-docker
    - ansible-role-traefik
