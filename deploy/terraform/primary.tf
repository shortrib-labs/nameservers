# Primary Nameserver VM
# Runs both Knot Resolver (recursive) and Knot DNS (authoritative primary)

resource "nutanix_virtual_machine" "primary" {
  name        = "${var.primary}.${var.domain}"
  description = "Primary nameserver - authoritative DNS primary + resolver"

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
    mac_address = local.resolver_mac_map[var.primary]
  }

  # NIC 2 - Authoritative service (infra subnet)
  # MAC address for DHCP reservation on EdgeRouter
  nic_list {
    subnet_uuid = data.nutanix_subnet.infra.id
    mac_address = local.auth_mac_map[var.primary]
  }

  # NIC 3 - Management network (SSH access)
  nic_list {
    subnet_uuid = data.nutanix_subnet.management.id
    mac_address = local.management_mac_map[var.primary]
  }

  # Cloud-init configuration
  guest_customization_cloud_init_meta_data = base64encode(jsonencode({
    "instance-id"    = random_uuid.primary.result
    "uuid"           = random_uuid.primary.result
    "local-hostname" = var.primary
  }))

  guest_customization_cloud_init_user_data = base64encode(
    templatefile("${local.directories.templates}/user-data.tftpl", {
      # User configuration
      ssh_authorized_keys = var.ssh_authorized_keys
      users               = local.users

      # Server identity
      hostname   = var.primary
      domain     = var.domain
      is_primary = true

      # Network configuration (IPs assigned via DHCP from EdgeRouter)
      resolver_ip = local.resolver_ip_map[var.primary]
      auth_ip     = local.auth_ip_map[var.primary]

      # TLS certificates
      tls_cert = var.tls_cert
      tls_key  = var.tls_key
      tls_ca   = var.tls_ca

      # DNS configuration
      dns_zones = local.dns_zones

      # Knot DNS (authoritative) configuration
      knot_config = templatefile("${local.directories.templates}/primary.conf.tftpl", {
        domain           = var.domain
        auth_ip          = local.auth_ip_map[var.primary]
        secondaries      = var.secondaries
        secondary_ips    = [for s in var.secondaries : local.auth_ip_map[s]]
        tsig_secret      = local.tsig_secret
        octodns_clients  = var.octodns_allowed_ranges
        dns_zones        = local.dns_zones
      })

      # Knot Resolver configuration - forward to all auth servers
      kresd_config = templatefile("${local.directories.templates}/kresd.conf.tftpl", {
        resolver_ip  = local.resolver_ip_map[var.primary]
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

  # Wait for cloud-init to complete and restart DNS services
  connection {
    type  = "ssh"
    user  = var.ssh_user
    agent = true
    host  = local.management_ip_map[var.primary]
  }

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait",
    ]
  }

  provisioner "remote-exec" {
    inline = [
      "sudo systemctl restart knot",
      "sudo systemctl restart kresd@1",
    ]
  }
}

