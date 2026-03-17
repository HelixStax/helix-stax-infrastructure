output "firewall_id" {
  description = "Hetzner firewall ID"
  value       = hcloud_firewall.this.id
}

output "firewall_name" {
  description = "Firewall name"
  value       = hcloud_firewall.this.name
}
