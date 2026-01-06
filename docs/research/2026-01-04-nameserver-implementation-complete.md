---
date: 2026-01-04T15:10:09Z
researcher: Claude
git_commit: (no commits yet)
branch: main
repository: nameservers
topic: "Completing Nameserver Terraform Implementation with Dual IPs"
tags: [research, codebase, terraform, knot-dns, knot-resolver, nutanix, ipam]
status: complete
last_updated: 2026-01-04
last_updated_by: Claude
---

# Research: Completing Nameserver Terraform Implementation

**Date**: 2026-01-04T15:10:09Z
**Researcher**: Claude
**Git Commit**: (no commits yet)
**Branch**: main
**Repository**: nameservers

## Research Question

How to complete the partial Terraform implementation to configure three nameservers with:
- Two IPs per server on the `infra` subnet (managed by Nutanix IPAM)
- Second NIC on `management` subnet (IPAM-assigned)
- Knot Resolver for recursive DNS with TLS/QUIC forwarding
- Knot DNS for authoritative service (1 primary, 2 secondaries)
- Specific resolver IPs: 10.105.0.252, 10.105.0.253, 10.105.0.254

## Summary

### Critical Finding: Nutanix Provider IP Limitation

**The Nutanix Terraform provider (v2.3.x) does NOT reliably support multiple IPs per NIC.** While the underlying API schema supports arrays, no working Terraform examples exist. The recommended approach is:

1. **Option A**: Use cloud-init to configure secondary IPs at OS level after VM creation
2. **Option B**: Use two NICs on the same subnet (not ideal but works)

### Architecture Decision

Given the provider limitation, we'll configure:
- **NIC 1**: `infra` subnet - single IP via IPAM (authoritative service IP)
- **NIC 2**: `management` subnet - single IP via IPAM (management access)
- **Secondary IP**: Configured at OS level via cloud-init (resolver IP - specific: 10.105.0.252-254)

### DNS-over-QUIC Limitation

**Knot Resolver does NOT support DNS-over-QUIC (DoQ) in stable releases** (5.x/6.x). Only Knot DNS (authoritative) has DoQ support. For resolver services, use DNS-over-TLS instead.

## Detailed Findings

### Server Architecture

| Server | Hostname | Role | Resolver IP (cloud-init) | Auth IP (IPAM) | Mgmt IP (IPAM) |
|--------|----------|------|--------------------------|----------------|----------------|
| 1 | cooper | Primary Auth + Resolver | 10.105.0.252 | Auto | Auto |
| 2 | maltman | Secondary Auth + Resolver | 10.105.0.253 | Auto | Auto |
| 3 | stillman | Secondary Auth + Resolver | 10.105.0.254 | Auto | Auto |

### Protocol Support Matrix

| Service | Server | IPv4 UDP | IPv4 TCP | IPv4 TLS | IPv4 QUIC | IPv6 UDP | IPv6 TCP | IPv6 TLS | IPv6 QUIC |
|---------|--------|----------|----------|----------|-----------|----------|----------|----------|-----------|
| Resolver | All | ✓ :53 | ✓ :53 | ✓ :853 | ✗* | ✓ :53 | ✓ :53 | ✓ :853 | ✗* |
| Auth Primary | cooper | ✓ :53 | ✓ :53 | ✓ :853 | ✓ :853 | ✓ :53 | ✓ :53 | ✓ :853 | ✓ :853 |
| Auth Secondary | maltman, stillman | ✓ 127.0.0.1:53 | ✓ 127.0.0.1:53 | ✓ :853 | ✓ :853 | ✗ | ✗ | ✓ :853 | ✓ :853 |

*Knot Resolver doesn't support DoQ yet

### Required Terraform Changes

#### 1. variables.tf Updates

```hcl
# Remove these k8s-specific variables:
# - kubernetes_subnet
# - workload_subnet
# - cluster_name
# - workers
# - controllers

# Update/Add these variables:
variable "primary" {
  type        = string
  description = "Hostname of the primary nameserver"
  default     = "cooper"
}

variable "secondaries" {
  type        = list(string)
  description = "Hostnames of secondary nameservers"
  default     = ["maltman", "stillman"]
}

variable "resolver_ips" {
  type        = list(string)
  description = "Specific IPs for resolver service"
  default     = ["10.105.0.252", "10.105.0.253", "10.105.0.254"]
}

variable "infra_subnet" {
  type        = string
  description = "Nutanix subnet for DNS services"
  default     = "infra"
}

variable "management_subnet" {
  type        = string
  description = "Nutanix subnet for management access"
  default     = "management"
}

variable "octodns_clients" {
  type        = list(string)
  description = "IP addresses allowed to perform zone updates"
  default     = []
}

variable "tsig_secret" {
  type        = string
  description = "TSIG key secret for zone updates (base64)"
  sensitive   = true
  default     = ""  # Generate with: openssl rand -base64 32
}
```

#### 2. main.tf Updates

```hcl
# Add management subnet data source
data "nutanix_subnet" "management_subnet" {
  subnet_name = var.management_subnet
}

# Rename existing subnet reference
data "nutanix_subnet" "infra_subnet" {
  subnet_name = var.infra_subnet
}

# Generate TSIG key if not provided
resource "random_password" "tsig_secret" {
  count   = var.tsig_secret == "" ? 1 : 0
  length  = 32
  special = false
}

locals {
  tsig_secret = var.tsig_secret != "" ? var.tsig_secret : base64encode(random_password.tsig_secret[0].result)

  # Build server configurations
  all_servers = concat([var.primary], var.secondaries)
  server_count = length(local.all_servers)

  # Map hostname to resolver IP
  resolver_ip_map = zipmap(local.all_servers, var.resolver_ips)
}
```

#### 3. primary.tf - Single Primary Server

```hcl
resource "random_id" "primary" {
  byte_length = 4
}

resource "random_uuid" "primary" {}

resource "nutanix_virtual_machine" "primary" {
  name        = var.primary
  description = "Primary nameserver (authoritative + resolver)"

  num_sockets          = 1
  num_vcpus_per_socket = var.cpus
  memory_size_mib      = var.memory
  cluster_uuid         = data.nutanix_cluster.cluster.id
  boot_type            = "UEFI"

  disk_list {
    data_source_reference = {
      kind = "image"
      uuid = data.nutanix_image.ubuntu_cloud_image.id
    }
    disk_size_bytes = var.disk_size * 1024 * 1024 * 1024
  }

  # NIC 1 - Infra subnet (auth IP via IPAM)
  nic_list {
    subnet_uuid = data.nutanix_subnet.infra_subnet.id
  }

  # NIC 2 - Management subnet (mgmt IP via IPAM)
  nic_list {
    subnet_uuid = data.nutanix_subnet.management_subnet.id
  }

  guest_customization_cloud_init_meta_data = base64encode(jsonencode({
    "instance-id"    = random_uuid.primary.result
    "uuid"           = random_uuid.primary.result
    "local-hostname" = var.primary
  }))

  guest_customization_cloud_init_user_data = base64encode(
    templatefile("${local.directories.templates}/user-data.tftpl", {
      ssh_authorized_keys = yamlencode(var.ssh_authorized_keys)
      users               = yamlencode(local.users)
      is_primary          = true
      hostname            = var.primary
      resolver_ip         = local.resolver_ip_map[var.primary]
      knot_config         = templatefile("${local.directories.templates}/primary.conf.tftpl", {
        primary_ip       = "0.0.0.0"  # Will be IPAM-assigned, listen on all
        primary_ipv6     = "::"
        secondaries      = var.secondaries
        secondary_ips    = [for s in var.secondaries : data.nutanix_virtual_machine.secondary[index(var.secondaries, s)].nic_list[0].ip_endpoint_list[0].ip]
        tsig_secret      = local.tsig_secret
        octodns_clients  = var.octodns_clients
      })
      kresd_config = templatefile("${local.directories.templates}/kresd.conf.tftpl", {
        resolver_ip    = local.resolver_ip_map[var.primary]
        resolver_ipv6  = ""  # Will derive from SLAAC or skip if no IPv6
        primary_ip     = "127.0.0.1"  # Forward to local authoritative
        secondary_ips  = []
      })
    })
  )

  lifecycle {
    ignore_changes = [power_state]
  }
}

data "nutanix_virtual_machine" "primary" {
  vm_id = nutanix_virtual_machine.primary.id
}
```

#### 4. secondary.tf - Secondary Servers

```hcl
resource "random_id" "secondary" {
  count       = length(var.secondaries)
  byte_length = 4
}

resource "random_uuid" "secondary" {
  count = length(var.secondaries)
}

resource "nutanix_virtual_machine" "secondary" {
  count       = length(var.secondaries)
  name        = var.secondaries[count.index]
  description = "Secondary nameserver (authoritative + resolver)"

  num_sockets          = 1
  num_vcpus_per_socket = var.cpus
  memory_size_mib      = var.memory
  cluster_uuid         = data.nutanix_cluster.cluster.id
  boot_type            = "UEFI"

  disk_list {
    data_source_reference = {
      kind = "image"
      uuid = data.nutanix_image.ubuntu_cloud_image.id
    }
    disk_size_bytes = var.disk_size * 1024 * 1024 * 1024
  }

  # NIC 1 - Infra subnet (auth IP via IPAM)
  nic_list {
    subnet_uuid = data.nutanix_subnet.infra_subnet.id
  }

  # NIC 2 - Management subnet (mgmt IP via IPAM)
  nic_list {
    subnet_uuid = data.nutanix_subnet.management_subnet.id
  }

  guest_customization_cloud_init_meta_data = base64encode(jsonencode({
    "instance-id"    = random_uuid.secondary[count.index].result
    "uuid"           = random_uuid.secondary[count.index].result
    "local-hostname" = var.secondaries[count.index]
  }))

  guest_customization_cloud_init_user_data = base64encode(
    templatefile("${local.directories.templates}/user-data.tftpl", {
      ssh_authorized_keys = yamlencode(var.ssh_authorized_keys)
      users               = yamlencode(local.users)
      is_primary          = false
      hostname            = var.secondaries[count.index]
      resolver_ip         = local.resolver_ip_map[var.secondaries[count.index]]
      knot_config         = templatefile("${local.directories.templates}/secondary.conf.tftpl", {
        secondary_ip     = "0.0.0.0"
        secondary_ipv6   = "::"
        primary_ip       = data.nutanix_virtual_machine.primary.nic_list[0].ip_endpoint_list[0].ip
        primary_ipv6     = ""
        primary_hostname = "${var.primary}.${var.domain}"
      })
      kresd_config = templatefile("${local.directories.templates}/kresd.conf.tftpl", {
        resolver_ip    = local.resolver_ip_map[var.secondaries[count.index]]
        resolver_ipv6  = ""
        primary_ip     = "127.0.0.1"
        secondary_ips  = []
      })
    })
  )

  lifecycle {
    ignore_changes = [power_state]
  }

  depends_on = [nutanix_virtual_machine.primary]
}

data "nutanix_virtual_machine" "secondary" {
  count = length(var.secondaries)
  vm_id = nutanix_virtual_machine.secondary[count.index].id
}
```

### Template Updates

#### user-data.tftpl Additions

Add after line 136 (before `#CLAUDE:` comments):

```yaml
# Install DNS packages
packages:
- knot
- knot-resolver

# Configure secondary IP for resolver service
write_files:
# Netplan config for secondary IP on first interface
- path: /etc/netplan/60-resolver-ip.yaml
  content: |
    network:
      version: 2
      ethernets:
        ens192:
          addresses:
            - ${resolver_ip}/24
  permissions: '0644'

# Knot DNS authoritative config
- path: /etc/knot/knot.conf
  content: |
${indent(4, knot_config)}
  permissions: '0640'
  owner: knot:knot

# Knot Resolver config
- path: /etc/knot-resolver/kresd.conf
  content: |
${indent(4, kresd_config)}
  permissions: '0644'

# Add to runcmd section:
runcmd:
- netplan apply
- systemctl enable knot
- systemctl start knot
- systemctl enable kresd@1
- systemctl start kresd@1
```

#### kresd.conf.tftpl Complete

```lua
-- Knot Resolver Configuration
-- vim:syntax=lua:set ts=4 sw=4:

log_level('info')

-- Network interface configuration
-- Listen for DNS (UDP/TCP) on resolver IP
net.listen('${resolver_ip}', 53, { kind = 'dns' })
%{ if resolver_ipv6 != "" ~}
net.listen('${resolver_ipv6}', 53, { kind = 'dns' })
%{ endif ~}

-- Listen for DNS-over-TLS on resolver IP
net.listen('${resolver_ip}', 853, { kind = 'tls' })
%{ if resolver_ipv6 != "" ~}
net.listen('${resolver_ipv6}', 853, { kind = 'tls' })
%{ endif ~}

-- TLS certificate configuration
net.tls("/etc/knot-resolver/dns.lab.shortrib.net.crt", "/etc/knot-resolver/dns.lab.shortrib.net.key")

-- Disable DNSSEC for internal zones
trust_anchors.set_insecure({
    'shortrib.net.',
    'lab.shortrib.net.',
    'shortrib.dev.',
    'shortrib.app.',
    'shortrib.run.',
    'shortrib.sh.',
    'shortrib.life.'
})

-- Forward internal zones to local authoritative server over TLS
policy.add(policy.suffix(policy.TLS_FORWARD({
    {'${primary_ip}@853', hostname='dns.lab.shortrib.net', ca_file='/etc/ssl/certs/ca-certificates.crt'}
}), {
    todname('lab.shortrib.net.'),
    todname('shortrib.net.'),
    todname('shortrib.dev.'),
    todname('shortrib.app.'),
    todname('shortrib.run.'),
    todname('shortrib.sh.'),
    todname('shortrib.life.')
}))

-- Modules
modules = {
    'hints > iterate',
    'stats',
    'predict',
}

-- Cache size
cache.size = 100 * MB
```

#### primary.conf.tftpl Complete

```yaml
# Knot DNS Primary Authoritative Server Configuration

server:
  rundir: "/run/knot"
  user: knot:knot
  key-file: /etc/knot/dns.lab.shortrib.net.key
  cert-file: /etc/knot/dns.lab.shortrib.net.crt
  ca-file: /etc/knot/root_ca.crt
  automatic-acl: on

  # Listen for unencrypted DNS (UDP/TCP) on all interfaces
  listen: [ ${primary_ip}@53, ${primary_ipv6}@53, 127.0.0.1@53, ::1@53 ]

  # Listen for DNS-over-TLS
  listen-tls: [ ${primary_ip}@853, ${primary_ipv6}@853 ]

  # Listen for DNS-over-QUIC
  listen-quic: [ ${primary_ip}@853, ${primary_ipv6}@853 ]

remote:
%{ for idx, secondary in secondaries ~}
  - id: ${secondary}
    address: ${secondary_ips[idx]}@853
    quic: on
%{ endfor ~}

key:
  - id: octodns
    algorithm: hmac-sha256
    secret: ${tsig_secret}

acl:
  - id: octodns_update
    action: [transfer, update]
%{ if length(octodns_clients) > 0 ~}
    address: [ ${join(", ", octodns_clients)} ]
%{ endif ~}
    key: octodns

  - id: secondary_xfr
    action: transfer
%{ if length(secondary_ips) > 0 ~}
    address: [ ${join(", ", secondary_ips)} ]
%{ endif ~}

log:
  - target: syslog
    any: info

database:
  storage: "/var/lib/knot"

template:
  - id: default
    storage: "/var/lib/knot/zones"
    file: "%s.zone"
    serial-policy: dateserial
    journal-content: all

zone:
  - domain: lab.shortrib.net
    notify: [ ${join(", ", secondaries)} ]
    acl: [ octodns_update, secondary_xfr ]
  - domain: shortrib.net
    notify: [ ${join(", ", secondaries)} ]
    acl: [ octodns_update, secondary_xfr ]
  - domain: shortrib.dev
    notify: [ ${join(", ", secondaries)} ]
    acl: [ octodns_update, secondary_xfr ]
  - domain: shortrib.app
    notify: [ ${join(", ", secondaries)} ]
    acl: [ octodns_update, secondary_xfr ]
  - domain: shortrib.run
    notify: [ ${join(", ", secondaries)} ]
    acl: [ octodns_update, secondary_xfr ]
  - domain: shortrib.io
    notify: [ ${join(", ", secondaries)} ]
    acl: [ octodns_update, secondary_xfr ]
  - domain: shortrib.sh
    notify: [ ${join(", ", secondaries)} ]
    acl: [ octodns_update, secondary_xfr ]
  - domain: shortrib.life
    notify: [ ${join(", ", secondaries)} ]
    acl: [ octodns_update, secondary_xfr ]
```

#### secondary.conf.tftpl Complete

```yaml
# Knot DNS Secondary Authoritative Server Configuration

server:
  rundir: "/run/knot"
  user: knot:knot
  key-file: /etc/knot/dns.lab.shortrib.net.key
  cert-file: /etc/knot/dns.lab.shortrib.net.crt
  ca-file: /etc/knot/root_ca.crt
  automatic-acl: on

  # Listen for unencrypted DNS only on localhost (for local resolver)
  listen: [ 127.0.0.1@53, ::1@53 ]

  # Listen for DNS-over-TLS on external interfaces
  listen-tls: [ ${secondary_ip}@853, ${secondary_ipv6}@853 ]

  # Listen for DNS-over-QUIC on external interfaces
  listen-quic: [ ${secondary_ip}@853, ${secondary_ipv6}@853 ]

remote:
  - id: primary
    address: ${primary_ip}@853
%{ if primary_ipv6 != "" ~}
    address: ${primary_ipv6}@853
%{ endif ~}
    cert-hostname: ${primary_hostname}
    quic: on

acl:
  - id: primary_notify
    address: ${primary_ip}
%{ if primary_ipv6 != "" ~}
    address: ${primary_ipv6}
%{ endif ~}
    action: notify

log:
  - target: syslog
    any: info

database:
  storage: "/var/lib/knot"

zone:
  - domain: lab.shortrib.net
    master: primary
    acl: primary_notify
  - domain: shortrib.net
    master: primary
    acl: primary_notify
  - domain: shortrib.dev
    master: primary
    acl: primary_notify
  - domain: shortrib.app
    master: primary
    acl: primary_notify
  - domain: shortrib.run
    master: primary
    acl: primary_notify
  - domain: shortrib.io
    master: primary
    acl: primary_notify
  - domain: shortrib.sh
    master: primary
    acl: primary_notify
  - domain: shortrib.life
    master: primary
    acl: primary_notify
```

## Implementation Notes

### Keeping primary.tf and secondary.tf Separate

**Recommendation: Keep them separate.** The differences are significant:

| Aspect | Primary | Secondary |
|--------|---------|-----------|
| Knot DNS listeners | Full (all interfaces, UDP/TCP/TLS/QUIC) | Localhost only for UDP/TCP, external for TLS/QUIC |
| Zone role | Master, accepts updates | Slave, receives from primary |
| TSIG key | Defined, used for OctoDNS ACL | Not needed |
| Remote config | Points to secondaries | Points to primary |
| Count | Always 1 | Variable (2 in this case) |
| Dependencies | None | Depends on primary for IP |

### IPv6 Considerations

If IPv6 is available via SLAAC on the `infra` subnet:
1. The VM will get an IPv6 address automatically
2. Templates should detect and use it
3. Alternatively, configure static IPv6 in cloud-init similar to resolver IPs

If IPv6 is not available:
1. Set `resolver_ipv6 = ""` in templates
2. Conditionals will skip IPv6 listener configuration

### Certificate Strategy

The templates reference `dns.lab.shortrib.net.crt/key`. Options:
1. **SAN Certificate**: Single cert with all server hostnames
2. **Wildcard**: `*.lab.shortrib.net`
3. **Per-Server**: Individual certs for each server

Certificates should be provisioned via cloud-init `write_files` or a separate secrets mechanism.

## Code References

| File | Lines | Description |
|------|-------|-------------|
| `deploy/terraform/main.tf` | 1-34 | Data sources, needs management subnet |
| `deploy/terraform/primary.tf` | 1-65 | k8s worker, needs full replacement |
| `deploy/terraform/secondary.tf` | 1-65 | Duplicate, needs conversion |
| `deploy/terraform/variables.tf` | 9-15 | Has primaries/resolvers, needs update |
| `deploy/terraform/variables.tf` | 72-75 | Single subnet, needs two |
| `deploy/terraform/templates/user-data.tftpl` | 137-139 | CLAUDE hints for config |
| `deploy/terraform/templates/kresd.conf.tftpl` | 1-49 | Resolver config, mostly complete |
| `deploy/terraform/templates/primary.conf.tftpl` | 1-75 | Primary auth, needs completion |
| `deploy/terraform/templates/secondary.conf.tftpl` | 1-53 | Secondary auth, needs fixes |
| `secrets/params.yaml` | 21-26 | Nameserver definitions |
| `Makefile` | 13-14 | Variable extraction |

## Open Questions

1. **Certificate Provisioning**: How are TLS certificates deployed to the servers? (ACME, manual, SOPS-encrypted?)

2. **OctoDNS Client IPs**: What IP addresses should be in the ACL for zone updates? Add to params.yaml.

3. **IPv6 Availability**: Is IPv6 configured on the `infra` subnet? This affects listener configuration.

4. **TSIG Key Management**: Should the TSIG key be generated by Terraform or provided via params.yaml?

## Sources

- [Nutanix Terraform Provider Documentation](https://registry.terraform.io/providers/nutanix/nutanix/latest/docs/resources/virtual_machine)
- [Knot DNS 3.5 Configuration](https://www.knot-dns.cz/docs/latest/html/configuration.html)
- [Knot Resolver 5.7 Documentation](https://knot-resolver.readthedocs.io/en/stable/)
- [Nutanix Provider GitHub Issues #63, #97](https://github.com/nutanix/terraform-provider-nutanix/issues)
