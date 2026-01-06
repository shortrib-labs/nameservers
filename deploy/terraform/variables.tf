# Project configuration
variable "project_root" {
  type        = string
  description = "Root directory of the project"
}

variable "domain" {
  type        = string
  description = "Domain name for the nameservers"
}

variable "image_name" {
  type        = string
  description = "Name of the Ubuntu cloud image in Nutanix"
}

# SSH and user configuration
variable "ssh_authorized_keys" {
  type        = list(string)
  description = "SSH public keys for authorized access"
}

variable "users" {
  type        = string
  description = "JSON-encoded cloud-init users configuration"
}

# Nameserver configuration
variable "primary" {
  type        = string
  description = "Hostname of the primary nameserver"
}

variable "secondaries" {
  type        = list(string)
  description = "Hostnames of secondary nameservers"
}

variable "resolver_ips" {
  type        = list(string)
  description = "Specific IPs for resolver service (one per server)"
}

variable "auth_ips" {
  type        = list(string)
  description = "Specific IPs for authoritative DNS service (one per server)"
}

variable "resolver_macs" {
  type        = list(string)
  description = "MAC addresses for resolver NICs (for DHCP reservations)"
}

variable "auth_macs" {
  type        = list(string)
  description = "MAC addresses for authoritative NICs (for DHCP reservations)"
}

# Node sizing
variable "cpus" {
  type        = number
  description = "Number of vCPUs per nameserver"
  default     = 1
}

variable "memory" {
  type        = number
  description = "Memory in MiB per nameserver"
  default     = 1024
}

variable "disk_size" {
  type        = number
  description = "Disk size in GB per nameserver"
  default     = 40
}

# Nutanix authentication
variable "nutanix_username" {
  type        = string
  description = "Nutanix Prism Central username"
}

variable "nutanix_password" {
  type        = string
  description = "Nutanix Prism Central password"
  sensitive   = true
}

variable "nutanix_prism_central" {
  type        = string
  description = "Nutanix Prism Central endpoint (IP or FQDN)"
}

variable "nutanix_cluster_name" {
  type        = string
  description = "Nutanix cluster name for VM placement"
}

variable "nutanix_storage_container" {
  type        = string
  description = "Storage container for VM disks (optional)"
  default     = null
}

# Subnet configuration
variable "infra_subnet" {
  type = object({
    vlan_id    = number
    cidr       = string
    gateway    = string
    pool_start = string
    pool_end   = string
  })
  description = "Infrastructure subnet configuration for DNS services"
}

variable "management_subnet" {
  type = object({
    vlan_id    = number
    cidr       = string
    gateway    = string
    pool_start = string
    pool_end   = string
  })
  description = "Management subnet configuration for SSH access"
}

# OctoDNS configuration
variable "octodns_allowed_ranges" {
  type        = list(string)
  description = "IP ranges allowed to perform zone updates via OctoDNS"
  default     = []
}

# TLS certificates
variable "tls_cert" {
  type        = string
  description = "TLS certificate for DNS-over-TLS/QUIC"
  sensitive   = true
}

variable "tls_key" {
  type        = string
  description = "TLS private key for DNS-over-TLS/QUIC"
  sensitive   = true
}

variable "tls_ca" {
  type        = string
  description = "TLS CA certificate chain"
  sensitive   = true
}

# Tailscale (optional)
variable "tailscale_auth_key" {
  type        = string
  description = "Tailscale auth key for VPN access"
  sensitive   = true
  default     = ""
}

# Locals for computed values
locals {
  users = jsondecode(var.users)

  directories = {
    secrets   = "${var.project_root}/secrets"
    templates = "${path.module}/templates"
    work      = "${var.project_root}/work"
  }

  # Build list of all servers with their roles
  all_servers = concat([var.primary], var.secondaries)

  # Map hostname to resolver IP
  resolver_ip_map = zipmap(local.all_servers, var.resolver_ips)

  # Map hostname to auth IP
  auth_ip_map = zipmap(local.all_servers, var.auth_ips)

  # Map hostname to MAC addresses (for DHCP reservations on EdgeRouter)
  resolver_mac_map = zipmap(local.all_servers, var.resolver_macs)
  auth_mac_map     = zipmap(local.all_servers, var.auth_macs)

  # Map hostname to index (for secondaries)
  secondary_index_map = { for idx, name in var.secondaries : name => idx }
}
