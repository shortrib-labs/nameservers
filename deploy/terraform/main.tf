# Nutanix cluster reference
data "nutanix_cluster" "cluster" {
  name = var.nutanix_cluster_name
}

# Infrastructure subnet for DNS services
data "nutanix_subnet" "infra" {
  subnet_name = var.infra_subnet
}

# Management subnet for SSH access
data "nutanix_subnet" "management" {
  subnet_name = var.management_subnet
}

# Ubuntu cloud image for nameservers
data "nutanix_image" "ubuntu_cloud_image" {
  image_name = var.image_name
}

# Generate TSIG key for OctoDNS zone updates
resource "random_password" "tsig_secret" {
  length  = 32
  special = false
}

# Random suffix for unique VM names (in case of recreation)
resource "random_id" "primary" {
  byte_length = 2
}

resource "random_id" "secondary" {
  count       = length(var.secondaries)
  byte_length = 2
}

# UUIDs for cloud-init instance identification
resource "random_uuid" "primary" {}

resource "random_uuid" "secondary" {
  count = length(var.secondaries)
}

# Computed locals for template rendering
locals {
  # Base64-encoded TSIG secret for Knot DNS
  tsig_secret = base64encode(random_password.tsig_secret.result)

  # Zones served by authoritative DNS
  dns_zones = [
    "lab.shortrib.net",
    "shortrib.net",
    "shortrib.dev",
    "shortrib.app",
    "shortrib.run",
    "shortrib.io",
    "shortrib.sh",
    "shortrib.life"
  ]
}
