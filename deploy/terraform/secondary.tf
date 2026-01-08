# Secondary Nameserver VMs
# Run both Knot Resolver (recursive) and Knot DNS (authoritative secondary)

resource "nutanix_virtual_machine" "secondary" {
  count       = length(var.secondaries)
  name        = "${var.secondaries[count.index]}.${var.domain}"
  description = "Secondary nameserver - authoritative DNS secondary + resolver"

  # CPU and memory configuration
  num_sockets          = 1
  num_vcpus_per_socket = var.cpus
  memory_size_mib      = var.memory

  # Cluster placement
  cluster_uuid = data.nutanix_cluster.cluster.id

  # Boot type - Ubuntu cloud images use UEFI
  boot_type = "UEFI"

  # Boot disk cloned from cloud image
  disk_list {
    data_source_reference = {
      kind = "image"
      uuid = data.nutanix_image.ubuntu_cloud_image.id
    }
    disk_size_bytes = var.disk_size * 1024 * 1024 * 1024
  }

  # NIC 1 - Resolver service (infra subnet)
  # MAC address for DHCP reservation on EdgeRouter
  nic_list {
    subnet_uuid = data.nutanix_subnet.infra.id
    mac_address = local.resolver_mac_map[var.secondaries[count.index]]
  }

  # NIC 2 - Authoritative service (infra subnet)
  # MAC address for DHCP reservation on EdgeRouter
  nic_list {
    subnet_uuid = data.nutanix_subnet.infra.id
    mac_address = local.auth_mac_map[var.secondaries[count.index]]
  }

  # NIC 3 - Management network (SSH access)
  nic_list {
    subnet_uuid = data.nutanix_subnet.management.id
    mac_address = local.management_mac_map[var.secondaries[count.index]]
  }

  # Cloud-init configuration
  guest_customization_cloud_init_meta_data = base64encode(jsonencode({
    "instance-id"    = random_uuid.secondary[count.index].result
    "uuid"           = random_uuid.secondary[count.index].result
    "local-hostname" = var.secondaries[count.index]
  }))

  guest_customization_cloud_init_user_data = base64encode(
    templatefile("${local.directories.templates}/user-data.tftpl", {
      # User configuration
      ssh_authorized_keys = var.ssh_authorized_keys
      users               = local.users

      # Server identity
      hostname   = var.secondaries[count.index]
      domain     = var.domain
      is_primary = false

      # Network configuration (IPs assigned via DHCP from EdgeRouter)
      resolver_ip = local.resolver_ip_map[var.secondaries[count.index]]
      auth_ip     = local.auth_ip_map[var.secondaries[count.index]]

      # TLS certificates
      tls_cert = var.tls_cert
      tls_key  = var.tls_key
      tls_ca   = var.tls_ca

      # DNS configuration
      dns_zones = local.dns_zones

      # Knot DNS (authoritative) configuration
      knot_config = templatefile("${local.directories.templates}/secondary.conf.tftpl", {
        domain           = var.domain
        auth_ip          = local.auth_ip_map[var.secondaries[count.index]]
        primary_hostname = "${var.primary}.${var.domain}"
        primary_ip       = local.auth_ip_map[var.primary]
        dns_zones        = local.dns_zones
      })

      # Knot Resolver configuration - forward to all auth servers
      kresd_config = templatefile("${local.directories.templates}/kresd.conf.tftpl", {
        resolver_ip  = local.resolver_ip_map[var.secondaries[count.index]]
        domain       = var.domain
        dns_zones    = local.dns_zones
        auth_servers = var.auth_ips
      })

      # Tailscale (optional)
      tailscale_auth_key = var.tailscale_auth_key
    })
  )

  lifecycle {
    ignore_changes = [
      # Allow Nutanix to manage power state
      power_state,
    ]
  }

  # Ensure primary is created first so we can get its IP
  depends_on = [nutanix_virtual_machine.primary]
}

