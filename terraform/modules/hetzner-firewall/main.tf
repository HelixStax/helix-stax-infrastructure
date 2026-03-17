terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
  }
}

resource "hcloud_firewall" "this" {
  name   = var.name
  labels = var.labels

  dynamic "rule" {
    for_each = var.rules
    content {
      direction   = rule.value.direction
      protocol    = rule.value.protocol
      port        = lookup(rule.value, "port", null)
      source_ips  = lookup(rule.value, "source_ips", [])
      destination_ips = lookup(rule.value, "destination_ips", [])
      description = lookup(rule.value, "description", null)
    }
  }
}
