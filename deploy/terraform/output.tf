# Nameserver outputs

output "resolver_ips" {
  value       = var.resolver_ips
  description = "Resolver service IP addresses (configured via cloud-init)"
}

output "primary_nameserver" {
  value = {
    hostname    = var.primary
    resolver_ip = local.resolver_ip_map[var.primary]
    auth_ip     = local.auth_ip_map[var.primary]
  }
  description = "Primary nameserver details"
}

output "secondary_nameservers" {
  value = [
    for name in var.secondaries : {
      hostname    = name
      resolver_ip = local.resolver_ip_map[name]
      auth_ip     = local.auth_ip_map[name]
    }
  ]
  description = "Secondary nameserver details"
}

output "tsig_secret" {
  value       = local.tsig_secret
  sensitive   = true
  description = "TSIG secret for OctoDNS zone updates (base64 encoded)"
}

output "dns_zones" {
  value       = local.dns_zones
  description = "DNS zones served by authoritative servers"
}
