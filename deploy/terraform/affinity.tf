# VM-VM anti-affinity for the nameservers
# Keeps the primary and secondaries on separate AHV hosts so a single host
# failure cannot take down all authoritative and recursive DNS at once.
#
# Prism Central enforces category-based anti-affinity as a soft policy: it
# spreads VMs when it can and reports non-compliance when it cannot (for
# example, fewer hosts than nameservers). Requires pc.2024.3 / AOS 7.0 or later.

resource "nutanix_category_v2" "nameservers" {
  key         = "AntiAffinity"
  value       = "nameservers"
  description = "Nameserver VMs that must not share a host"
}

resource "nutanix_vm_anti_affinity_policy_v2" "nameservers" {
  name        = "nameservers"
  description = "Spread nameserver VMs across hosts"
  categories  = [nutanix_category_v2.nameservers.id]
}
