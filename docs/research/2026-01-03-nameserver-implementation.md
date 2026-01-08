---
date: 2026-01-03T14:30:00-05:00
researcher: Claude
git_commit: (no commits yet)
branch: main
repository: nameservers
topic: "Completing Nameserver Terraform Implementation"
tags: [research, codebase, terraform, knot-dns, knot-resolver, nutanix]
status: complete
last_updated: 2026-01-03
last_updated_by: Claude
---

# Research: Completing Nameserver Terraform Implementation

**Date**: 2026-01-03T14:30:00-05:00
**Researcher**: Claude
**Git Commit**: (no commits yet)
**Branch**: main
**Repository**: nameservers

## Research Question

How to complete the partial Terraform implementation to configure three nameservers with dual IPs, running Knot Resolver and Knot DNS (authoritative) with specific network requirements.

## Summary

The codebase contains Terraform borrowed from a Kubernetes project that needs significant restructuring for nameserver deployment. Key findings:

1. **Current State**: Terraform defines k8s workers with two NICs (kubernetes/workload subnets) - needs conversion to nameservers with two IPs on same subnet
2. **Templates Need Work**: Three config templates exist with `CLAUDE:` hints marking incomplete sections
3. **Architecture Required**: 3 nameservers, each with resolver IP + authoritative IP, 1 primary + 2 secondary authoritative servers
4. **Network Requirements**: Specific protocol/listener configurations differ between primary and secondary authoritative servers

## Detailed Findings

### Current Terraform Structure

The Terraform is structured for a Kubernetes cluster, not nameservers:

| File | Current Purpose | Needs Conversion |
|------|-----------------|------------------|
| `main.tf:1-34` | Cluster/subnet data sources, cloud image, user_data local | Add `management` subnet data source |
| `primary.tf:1-65` | k8s worker VMs with two NICs | Convert to primary nameserver VM |
| `secondary.tf:1-65` | Duplicate of primary.tf | Convert to secondary nameserver VMs (keep separate) |
| `variables.tf:1-96` | Has `primaries`/`resolvers` vars | Update to `primary`/`secondaries`, add `management_subnet` |
| `output.tf:1-21` | k8s node IPs | Update for nameserver IPs |
| `providers.tf:1-26` | Nutanix provider | Keep as-is |

### CLAUDE: Hints Found

**user-data.tftpl:137-139**:
```
#CLAUDE: if this is a primary, write the appropriate knot primary config
#CLAUDE: if this is a secondary, write the appropriate knot secondary config
#CLAUDE: write the appropriate knot resolver config
```

**kresd.conf.tftpl:5**:
```
--CLAUDE: Nutanix IPAM should be managing all of the needed IPs, our terraform should take care of that
```

**kresd.conf.tftpl:28-29**:
```
--CLAUDE: for each of secondary ip
```

**primary.conf.tftpl:4**:
```
#CLAUDE: Nutanix IPAM should be managing all of the needed IPs, our terraform should take care of that
```

**primary.conf.tftpl:14**:
```
#CLAUDE: listen on both ${priamry_ip} and ${primary_ipv6} for QUIC and TLS
```

**primary.conf.tftpl:19-25**:
```
#CLAUDE: for each secondary
...
#CLAUDE: end for each
```

**primary.conf.tftpl:30**:
```
secret: #CLAUDE: generated TSIG key
```

**primary.conf.tftpl:35**:
```
address: #CLAUDE: allowed client IPs from terraform parameters
```

**secondary.conf.tftpl:13**:
```
#CLAUDE: update to listen on this secondary's IP and IPV6 for QUIC and TLS
```

### Required Architecture

Based on user requirements and `params.yaml`:

| Server | Role | Resolver IP | Auth IP | Auth Mode |
|--------|------|-------------|---------|-----------|
| cooper | Primary Auth + Resolver | 10.105.0.252 | IPAM-assigned | UDP/TCP/TLS/QUIC on IPv4 |
| maltman | Secondary Auth + Resolver | 10.105.0.253 | IPAM-assigned | localhost UDP/TCP, IPv4 TLS/QUIC |
| stillman | Secondary Auth + Resolver | 10.105.0.254 | IPAM-assigned | localhost UDP/TCP, IPv4 TLS/QUIC |

**Note**: IPv4 only per user clarification. IPv6 disabled.

### Network Configuration Requirements

**Resolver (all 3 servers)** - IPv4 only:
- Listen on resolver IP: ports 53 (UDP/TCP), 853 (TLS), 8853 (QUIC)
- Forward internal zones to authoritative servers over TLS

**Primary Authoritative** - IPv4 only:
- Listen: resolver IP + auth IP on port 53 (UDP/TCP)
- Listen: resolver IP + auth IP on port 853 (TLS/QUIC)
- Accept zone updates from OctoDNS (TSIG authenticated)
- Notify secondaries of zone changes

**Secondary Authoritative** - IPv4 only:
- Listen: 127.0.0.1 only on port 53 (UDP/TCP) - for local resolver
- Listen: auth IP on port 853 (TLS/QUIC) - for external queries
- Accept NOTIFY from primary
- Zone transfer from primary over QUIC

### Nutanix VM Configuration

Each VM has two NICs:

| NIC | Subnet | IPs | Purpose |
|-----|--------|-----|---------|
| NIC1 | `infra` | 2 IPs (both via IPAM) | Resolver IP (specific: 10.105.0.252-254) + Authoritative IP (auto) |
| NIC2 | `management` | 1 IP (IPAM auto) | Management/SSH access |

The Nutanix provider supports multiple IPs per NIC via `ip_endpoint_list`. Implementation:
1. Request specific resolver IPs (10.105.0.252-254) on NIC1
2. Let IPAM assign authoritative IPs on NIC1 (second IP)
3. Let IPAM assign management IP on NIC2

Variables needed: `subnet` (existing, value: `infra`), `management_subnet` (new, value: `management`)

### File Structure Decision

Keep `primary.tf` and `secondary.tf` separate due to significant config differences:

| Aspect | Primary | Secondary |
|--------|---------|-----------|
| Auth listeners | Full (all interfaces, all protocols) | Restricted (localhost UDP/TCP, external TLS/QUIC) |
| Zone role | Master, accepts updates | Slave, receives NOTIFY |
| TSIG key | Defined, used for OctoDNS ACL | Not needed |
| Remote config | Points to secondaries | Points to primary |
| Template vars | `secondaries` list, `tsig_key`, `acl_addresses` | `primary_ip`, `primary_hostname` |

### Template Variables Needed

For resolver template:
- `resolver_ip` - IPv4 address
- `resolver_ipv6` - IPv6 address (if available, or derive)
- `primary_ip` - Primary authoritative IPv4
- `secondary_ips` - List of secondary authoritative IPs

For primary authoritative template:
- `primary_ip` / `primary_ipv6` - This server's IPs
- `secondaries` - List of {ip, ipv6, hostname} for each secondary
- `tsig_key` - Generated TSIG secret
- `acl_addresses` - OctoDNS client IPs

For secondary authoritative template:
- `secondary_ip` / `secondary_ipv6` - This server's IPs
- `primary_ip` / `primary_ipv6` - Primary server IPs
- `primary_hostname` - For certificate validation

## Code References

- `deploy/terraform/main.tf:1-34` - Data sources and user_data template
- `deploy/terraform/primary.tf:1-65` - VM definition (needs replacement)
- `deploy/terraform/secondary.tf:1-65` - Duplicate file (remove)
- `deploy/terraform/variables.tf:9-15` - Nameserver variables (primaries, resolvers lists)
- `deploy/terraform/variables.tf:72-75` - Subnet variable (single, not two)
- `deploy/terraform/templates/user-data.tftpl:137-139` - CLAUDE hints for config generation
- `deploy/terraform/templates/kresd.conf.tftpl:1-49` - Resolver config template
- `deploy/terraform/templates/primary.conf.tftpl:1-75` - Primary authoritative template
- `deploy/terraform/templates/secondary.conf.tftpl:1-53` - Secondary authoritative template
- `secrets/params.yaml:21-26` - Nameserver definitions (updated: `primary: [cooper]`, `secondaries: [maltman, stillman]`)
- `Makefile:13-14` - Updated variable names (`primary`, `secondaries`)

## Architecture Insights

1. **Dual-IP Design**: Each VM needs two IPs on same subnet - one for resolver service (specific IP), one for authoritative service (IPAM-assigned)

2. **Certificate Strategy**: TLS/QUIC require certificates. Templates reference `dns.lab.shortrib.net.crt/key` - implies wildcard or SAN cert for all servers

3. **Zone Forwarding**: Resolvers forward internal domains to authoritative servers over TLS for privacy

4. **TSIG for Updates**: OctoDNS uses HMAC-SHA256 TSIG keys for zone updates

5. **QUIC for Zone Transfer**: Modern approach using DNS-over-QUIC for primary-to-secondary zone transfers

## Implementation Plan

1. **Update variables.tf**:
   - Rename `primaries`/`resolvers` to `primary`/`secondaries`
   - Add `management_subnet` variable (default: `management`)
   - Add `resolver_ips` list (default: 10.105.0.252-254)
   - Add `octodns_clients` list for ACL
   - Remove unused k8s variables (`kubernetes_subnet`, `workload_subnet`, `cluster_name`, etc.)

2. **Update main.tf**:
   - Add `management` subnet data source
   - Keep `infra` subnet (rename from kubernetes/workload)
   - Add locals for nameserver configuration
   - Generate TSIG key with `random_password`

3. **Convert primary.tf**:
   - Single primary nameserver VM
   - NIC1: `infra` subnet with 2 IPs (resolver + auth)
   - NIC2: `management` subnet with 1 IP
   - Cloud-init with primary-specific configs

4. **Convert secondary.tf**:
   - Secondary nameserver VMs (count based on `secondaries` list)
   - NIC1: `infra` subnet with 2 IPs (resolver + auth)
   - NIC2: `management` subnet with 1 IP
   - Cloud-init with secondary-specific configs

5. **Complete templates**:
   - Resolver config: IPv4 listeners, forward internal zones to auth servers
   - Primary auth: full IPv4 listeners, TSIG key, OctoDNS ACL, notify secondaries
   - Secondary auth: localhost:53, external TLS/QUIC, receive from primary

6. **Update cloud-init (user-data.tftpl)**:
   - Install knot-dns and knot-resolver packages
   - Write role-appropriate configs via `write_files`
   - Configure systemd services

## Open Questions

1. ~~**IPv6 Addresses**: Are IPv6 addresses available from IPAM, or should IPv6 be disabled?~~ **RESOLVED**: IPv4 only
2. **Certificate Provisioning**: How are TLS certificates deployed? (ACME, manual, etc.)
3. ~~**TSIG Key Generation**: Should Terraform generate the TSIG key or use existing?~~ **RESOLVED**: Generate in Terraform
4. ~~**OctoDNS Client IPs**: What IP addresses should be in the ACL for zone updates?~~ **RESOLVED**: Provide via params.yaml (`octodns_clients`)
5. ~~**Management Subnet Name**: Is the management subnet called `management` in Nutanix?~~ **RESOLVED**: Subnet is named `management`
