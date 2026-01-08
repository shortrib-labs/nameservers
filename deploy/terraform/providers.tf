terraform {
  required_providers {
    nutanix = {
      source  = "nutanix/nutanix"
      version = "~> 2.3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "nutanix" {
  username     = var.nutanix_username
  password     = var.nutanix_password
  endpoint     = var.nutanix_prism_central
  port         = 9440
  insecure     = true # For self-signed certificates
  wait_timeout = 60
}
