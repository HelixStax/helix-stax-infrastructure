output "cp_server_id" {
  description = "Hetzner server ID of the K3s control plane"
  value       = module.cp_server.server_id
}

output "cp_server_ipv4" {
  description = "Public IPv4 of the K3s control plane"
  value       = module.cp_server.server_ipv4
}

output "cp_server_ipv6" {
  description = "Public IPv6 of the K3s control plane"
  value       = module.cp_server.server_ipv6
}

output "cp_firewall_id" {
  description = "Hetzner firewall ID attached to the K3s control plane"
  value       = module.cp_firewall.firewall_id
}

output "vps_server_id" {
  description = "Hetzner server ID of the services VPS"
  value       = module.vps_server.server_id
}

output "vps_server_ipv4" {
  description = "Public IPv4 of the services VPS"
  value       = module.vps_server.server_ipv4
}

output "vps_server_ipv6" {
  description = "Public IPv6 of the services VPS"
  value       = module.vps_server.server_ipv6
}

output "vps_firewall_id" {
  description = "Hetzner firewall ID attached to the services VPS"
  value       = module.vps_firewall.firewall_id
}
