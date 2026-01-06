# Homelab Nameservers

Deploy a redundant DNS infrastructure on Nutanix AHV using Terraform. This project creates three nameservers running both recursive (Knot Resolver) and authoritative (Knot DNS) services with modern encrypted DNS support.

## Architecture

Each nameserver has **two IPs**: one for the resolver service and one for the authoritative service.

```
                              ┌─────────────────────────────────────────┐
                              │      All Resolvers Forward to All       │
                              │      Authoritative Servers over TLS     │
                              └─────────────────────────────────────────┘
                                                  │
        ┌─────────────────────────────────────────┼─────────────────────────────────────────┐
        │                                         │                                         │
        ▼                                         ▼                                         ▼
┌───────────────────────┐               ┌───────────────────────┐               ┌───────────────────────┐
│ 10.105.0.2:853 (TLS)  │               │ 10.105.0.3:853 (TLS)  │               │ 10.105.0.4:853 (TLS)  │
│ cooper auth           │               │ maltman auth          │               │ stillman auth         │
└───────────────────────┘               └───────────────────────┘               └───────────────────────┘

┌──────────────────────────────────────────────────────────────────────────────────┐
│                              cooper (primary)                                     │
│                                                                                   │
│  ┌─────────────────────────────────┐    ┌─────────────────────────────────────┐  │
│  │        Knot Resolver            │    │  Knot DNS (Primary Authoritative)   │  │
│  │                                 │    │                                     │  │
│  │  IP: 10.105.0.252               │    │  IP: 10.105.0.2                     │  │
│  │  :53  UDP/TCP                   │    │  :53  UDP/TCP                       │  │
│  │  :853 TLS                       │    │  :853 TLS/QUIC                      │  │
│  └─────────────────────────────────┘    └─────────────────────────────────────┘  │
│                                                         │                        │
└─────────────────────────────────────────────────────────┼────────────────────────┘
                                                          │
                                                          │ NOTIFY (zone changes)
                                                          │
                          ┌───────────────────────────────┴─────────────────────────────────┐
                          │                                                                 │
                          ▼                                                                 ▼
┌──────────────────────────────────────────────────┐  ┌──────────────────────────────────────────────────┐
│                maltman (secondary)                │  │               stillman (secondary)                │
│                                                   │  │                                                   │
│  ┌─────────────────────────────────┐              │  │  ┌─────────────────────────────────┐              │
│  │        Knot Resolver            │              │  │  │        Knot Resolver            │              │
│  │                                 │              │  │  │                                 │              │
│  │  IP: 10.105.0.253               │              │  │  │  IP: 10.105.0.254               │              │
│  │  :53  UDP/TCP                   │              │  │  │  :53  UDP/TCP                   │              │
│  │  :853 TLS                       │              │  │  │  :853 TLS                       │              │
│  └─────────────────────────────────┘              │  │  └─────────────────────────────────┘              │
│                                                   │  │                                                   │
│  ┌─────────────────────────────────┐              │  │  ┌─────────────────────────────────┐              │
│  │ Knot DNS (Secondary Auth)       │              │  │  │ Knot DNS (Secondary Auth)       │              │
│  │                                 │              │  │  │                                 │              │
│  │  IP: 10.105.0.3                 │              │  │  │  IP: 10.105.0.4                 │              │
│  │  127.0.0.1:53 UDP/TCP (local)   │              │  │  │  127.0.0.1:53 UDP/TCP (local)   │              │
│  │  :853 TLS/QUIC (external)       │              │  │  │  :853 TLS/QUIC (external)       │              │
│  └─────────────────────────────────┘              │  │  └─────────────────────────────────┘              │
│                                                   │  │                                                   │
└───────────────────────────────────────────────────┘  └───────────────────────────────────────────────────┘
```

### IP and MAC Address Summary

| Server | Resolver IP | Resolver MAC | Auth IP | Auth MAC |
|--------|-------------|--------------|---------|----------|
| cooper | 10.105.0.252 | 52:54:00:69:00:fc | 10.105.0.2 | 52:54:00:69:00:02 |
| maltman | 10.105.0.253 | 52:54:00:69:00:fd | 10.105.0.3 | 52:54:00:69:00:03 |
| stillman | 10.105.0.254 | 52:54:00:69:00:fe | 10.105.0.4 | 52:54:00:69:00:04 |

IPs are assigned via DHCP reservations on EdgeRouter based on MAC addresses.

### Network Configuration

Each nameserver has three NICs with MAC-based DHCP reservations on EdgeRouter:

| NIC | Subnet | MAC Pattern | Purpose |
|-----|--------|-------------|---------|
| NIC 1 | `infra` | 52:54:00:69:00:xx | Resolver service |
| NIC 2 | `infra` | 52:54:00:69:00:xx | Authoritative service |
| NIC 3 | `management` | (auto) | SSH access |

MAC addresses use OUI `52:54:00` followed by the last 3 octets of the IP address.

### Protocol Support

| Service | IP | Port 53 | Port 853 |
|---------|-----|---------|----------|
| **Resolver** (all servers) | Resolver IP | UDP, TCP | TLS |
| **Primary Auth** (cooper) | Auth IP | UDP, TCP | TLS, QUIC |
| **Secondary Auth** (maltman, stillman) | 127.0.0.1 | UDP, TCP | — |
| **Secondary Auth** (maltman, stillman) | Auth IP | — | TLS, QUIC |

**Note**: Resolvers forward internal zones to all three authoritative servers over TLS (port 853). This is why each service needs its own IP - the resolver and authoritative services can both listen on :853 without conflict.

## Requirements

### Tools

- [Terraform](https://terraform.io) >= 1.0
- [SOPS](https://github.com/mozilla/sops) for secrets management
- [yq](https://github.com/mikefarah/yq) for YAML processing
- [direnv](https://direnv.net/) for environment management
- GNU Make

### Nutanix Prerequisites

- Nutanix AHV cluster with Prism Central
- Two subnets with IPAM configured:
  - `infra` - For DNS service IPs
  - `management` - For SSH access
- Ubuntu 24.04 cloud image uploaded to Prism Central
- Prism Central user with VM creation permissions

## Quick Start

### 1. Setup

After cloning, configure git hooks:

```shell
make setup
```

This enables the pre-commit hook that prevents committing unencrypted secrets.

### 2. Configure Parameters

Copy and edit the parameters file:

```shell
cp secrets/REDACTED-params.yaml secrets/params.yaml
```

Edit `secrets/params.yaml` to configure:

```yaml
# Nameserver hostnames
nameservers:
  primary: cooper
  secondaries:
    - maltman
    - stillman
  resolver_ips:
    - 10.105.0.252
    - 10.105.0.253
    - 10.105.0.254

# Subnet configuration
subnets:
  infra:
    vlan_id: 105
    cidr: 10.105.0.0/16
    gateway: 10.105.0.1
    pool_start: 10.105.0.100
    pool_end: 10.105.0.250
  management:
    vlan_id: 100              # Your management VLAN
    cidr: 10.100.0.0/16       # Your management CIDR
    gateway: 10.100.0.1
    pool_start: 10.100.0.100
    pool_end: 10.100.0.250

# TLS certificates for DNS-over-TLS/QUIC
tls:
  cert: |
    -----BEGIN CERTIFICATE-----
    ...
    -----END CERTIFICATE-----
  key: |
    -----BEGIN PRIVATE KEY-----
    ...
    -----END PRIVATE KEY-----
  ca: |
    -----BEGIN CERTIFICATE-----
    ...
    -----END CERTIFICATE-----
```

### 3. Encrypt Secrets

```shell
make encrypt
```

### 4. Deploy

```shell
# Initialize Terraform
make init

# Preview changes
make plan

# Deploy nameservers
make servers
```

### 5. Get TSIG Key for OctoDNS

```shell
make show-tsig
```

## DNS Zones

The following zones are served by the authoritative DNS:

- `lab.shortrib.net`
- `shortrib.net`
- `shortrib.dev`
- `shortrib.app`
- `shortrib.run`
- `shortrib.io`
- `shortrib.sh`
- `shortrib.life`

## OctoDNS Integration

The primary server accepts dynamic zone updates via RFC 2136 with TSIG authentication.

Example OctoDNS provider configuration:

```yaml
providers:
  knot:
    class: octodns_ddns.DdnsProvider
    host: 10.105.0.252  # Or cooper.lab.shortrib.net
    port: 53
    key_name: octodns
    key_algorithm: hmac-sha256
    key_secret: <output from 'make show-tsig'>
```

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make setup` | Configure git hooks (run after cloning) |
| `make init` | Initialize Terraform |
| `make plan` | Preview infrastructure changes |
| `make servers` | Deploy/update nameservers |
| `make destroy` | Destroy all nameservers |
| `make encrypt` | Encrypt params.yaml with SOPS |
| `make decrypt` | Decrypt params.yaml with SOPS |
| `make show-tsig` | Display TSIG secret for OctoDNS |
| `make clean` | Remove generated tfvars file |

## File Structure

```
.
├── deploy/
│   └── terraform/
│       ├── main.tf              # Data sources, TSIG generation
│       ├── primary.tf           # Primary nameserver VM
│       ├── secondary.tf         # Secondary nameserver VMs
│       ├── variables.tf         # Input variables
│       ├── output.tf            # Output values
│       ├── providers.tf         # Provider configuration
│       └── templates/
│           ├── user-data.tftpl      # Cloud-init template
│           ├── kresd.conf.tftpl     # Knot Resolver config
│           ├── primary.conf.tftpl   # Primary Knot DNS config
│           └── secondary.conf.tftpl # Secondary Knot DNS config
├── secrets/
│   ├── params.yaml              # Configuration (SOPS encrypted)
│   └── REDACTED-params.yaml     # Template for params.yaml
├── docs/
│   └── research/                # Research documents
├── Makefile
└── README.md
```

## Secrets Management

Secrets in `params.yaml` are encrypted using SOPS with GPG. The public key is stored in `.sops.pub.asc`.

To use your own GPG key:

1. Export your public key: `gpg --export --armor YOUR_KEY_ID > .sops.pub.asc`
2. Update `.sops.yaml` with your key fingerprint
3. Re-encrypt: `make encrypt`

## Troubleshooting

### Check Knot DNS Status

```shell
ssh user@cooper sudo knotc status
ssh user@cooper sudo knotc zone-status
```

### Check Knot Resolver Status

```shell
ssh user@cooper sudo systemctl status kresd@1
```

### View Logs

```shell
ssh user@cooper sudo journalctl -u knot -f
ssh user@cooper sudo journalctl -u kresd@1 -f
```

### Test DNS Resolution

```shell
# Standard DNS
dig @10.105.0.252 lab.shortrib.net

# DNS-over-TLS
kdig @10.105.0.252 +tls lab.shortrib.net

# DNS-over-QUIC (authoritative only)
kdig @10.105.0.252 +quic lab.shortrib.net
```

## License

MIT
