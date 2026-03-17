terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
  }
}

resource "hcloud_server" "this" {
  name        = var.name
  server_type = var.server_type
  image       = var.image
  location    = var.location
  ssh_keys    = [for id in var.ssh_key_ids : tostring(id)]
  user_data   = var.user_data
  labels      = var.labels

  # firewall_ids are passed directly as known static integers
  firewall_ids = var.firewall_ids

  lifecycle {
    # Ignore changes that force recreation on already-running servers:
    # - ssh_keys: injected at creation time, cannot be changed without rebuild
    # - user_data: cloud-init runs once; changes should not trigger rebuild
    # - image: base image is immutable after creation
    ignore_changes = [
      ssh_keys,
      user_data,
      image,
    ]
  }
}
